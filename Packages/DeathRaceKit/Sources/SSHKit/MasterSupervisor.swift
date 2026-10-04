import Foundation
import PTYKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// One host's ssh master as the app runs it: the app's own child, in a session of its own,
/// with no terminal. Panes and tunnels reach the host through its control socket.
///
/// It is connected when ssh prints the ready marker. OpenSSH runs `LocalCommand` right after
/// the control socket starts listening, so nothing polls; a connect to the socket confirms
/// it. It has ended when the process exits, and what it last wrote on stderr says why.
///
/// A thread per master waits on its output and its exit, and nothing else: an idle master
/// costs no wakeups.
public final class MasterSupervisor: Sendable {
    public enum Ending: Equatable, Sendable {
        /// The app ended it: its last pane or tunnel went, or the app quit.
        case closed
        /// It ended without being asked, or never connected: why, from ssh's last words.
        case failed(ConnectionFailure)
    }

    public enum State: Equatable, Sendable {
        case connecting
        case ready
        case ended(Ending)
    }

    public enum Failure: Error, Equatable {
        /// A master already listens on the control socket: one a crash left behind.
        /// `cleanUpLeftovers` ends it.
        case alreadyRunning(String)
        case spawn(errno: Int32)
    }

    public let alias: String
    public let controlPath: String
    private let arguments: [String]
    private let environment: [String: String]
    private let marker: String
    private let onChange: @Sendable (State) -> Void
    private let shared = Locked(Shared())

    /// How long ssh has after SIGTERM before SIGKILL.
    static let termGrace = 2_000
    /// Output kept while looking for the marker; ssh prints nothing else there.
    static let outputKept = 64 * 1024

    struct Waiter {
        var until: @Sendable (State) -> Bool
        var continuation: CheckedContinuation<State, Never>
    }

    struct Shared {
        var state = State.connecting
        var started = false
        var pid: Int32?
        /// Set, under this lock, before the child is reaped: no signal goes out after that,
        /// when its pid may belong to someone else.
        var reaped = false
        /// How the app asked it to end.
        var asked: Ending?
        var log = MasterLog()
        var waiters: [Waiter] = []
    }

    /// `environment` is exactly what ssh gets: the askpass variables included.
    public init(
        alias: String, config: String, controlPath: String, environment: [String: String],
        onChange: @escaping @Sendable (State) -> Void = { _ in }
    ) {
        self.alias = alias
        self.controlPath = controlPath
        self.environment = environment
        self.onChange = onChange
        marker = "deathrace-ready-" + String(AskpassWire.makeToken().prefix(16))
        arguments = SSHCommand.master(alias: alias, config: config, readyMarker: marker)
    }

    public var state: State { shared.withLock { $0.state } }
    public var pid: Int32? { shared.withLock { $0.pid } }
    /// What ssh has written on stderr so far.
    public var log: MasterLog { shared.withLock { $0.log } }

    // MARK: - Starting and ending

    /// Starts ssh and the thread that watches it, once, and returns ssh's pid for the askpass
    /// broker. The control socket's folder is made (0700) if it's missing, and a socket left
    /// there with nothing listening is removed: ssh fails on either.
    @discardableResult
    public func start() throws(Failure) -> Int32 {
        if UnixSocket.accepts(controlPath) { throw .alreadyRunning(controlPath) }
        unlink(controlPath)
        let folder = (controlPath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: folder) {
            try? FileManager.default.createDirectory(
                atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let child: ChildProcess
        do {
            child = try ChildProcess.spawn(executable: arguments[0], arguments: arguments, environment: environment)
        } catch PTYError.spawnFailed(let code) {
            throw .spawn(errno: code)
        } catch {
            throw .spawn(errno: EINVAL)
        }
        // -N: ssh never reads its input.
        child.closeInput()
        let pid = child.pid
        let (first, asked) = shared.withLock { shared -> (Bool, Ending?) in
            defer { shared.started = true }
            shared.pid = pid
            return (!shared.started, shared.asked)
        }
        precondition(first, "A master is started once")
        let handoff = Handoff(child)
        let thread = Thread { [self] in watch(handoff.value) }
        thread.name = "Death Race: ssh master for \(alias)"
        thread.start()
        // Ended before it had a process to signal (a Cancel while it was being made).
        if let asked { end(asked) }
        return pid
    }

    /// Ends the master: SIGTERM to its process group, ProxyJump hops included, and SIGKILL
    /// if it's still there after `termGrace`. `ending` is what the state will say.
    public func end(_ ending: Ending = .closed) {
        let signalled = shared.withLock { shared -> Bool in
            if case .ended = shared.state { return false }
            if shared.asked == nil { shared.asked = ending }
            guard let pid = shared.pid, !shared.reaped else { return false }
            _ = kill(-pid, SIGTERM)
            return true
        }
        guard signalled else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Self.termGrace)) { [self] in
            shared.withLock { shared in
                guard let pid = shared.pid, !shared.reaped else { return }
                _ = kill(-pid, SIGKILL)
            }
        }
    }

    // MARK: - Waiting

    /// The state once it's connected or has ended.
    public func settled() async -> State {
        await state { $0 != .connecting }
    }

    /// How it ended, once it has.
    public func ending() async -> Ending {
        let ended = await state {
            if case .ended = $0 { return true }
            return false
        }
        guard case .ended(let ending) = ended else { return .closed }
        return ending
    }

    private func state(where condition: @escaping @Sendable (State) -> Bool) async -> State {
        await withCheckedContinuation { continuation in
            let now = shared.withLock { shared -> State? in
                if condition(shared.state) { return shared.state }
                shared.waiters.append(Waiter(until: condition, continuation: continuation))
                return nil
            }
            if let now { continuation.resume(returning: now) }
        }
    }

    private func transition(to new: State) {
        let woken = shared.withLock { shared -> [Waiter]? in
            if case .ended = shared.state { return nil }
            guard shared.state != new else { return nil }
            shared.state = new
            let woken = shared.waiters.filter { $0.until(new) }
            shared.waiters.removeAll { $0.until(new) }
            return woken
        }
        guard let woken else { return }
        // The owner's bookkeeping first (saving a password once connected, say), so anything
        // awaiting this state finds it done.
        onChange(new)
        for waiter in woken { waiter.continuation.resume(returning: new) }
    }

    // MARK: - Watching

    private func watch(_ child: ChildProcess) {
        let exitWatch = child.makeExitWatch()
        defer { if let exitWatch { close(exitWatch) } }
        var output: [UInt8] = []
        var sawMarker = false
        var outputOpen = true
        var errorsOpen = true
        var status: ExitStatus?

        func took(_ bytes: [UInt8], from fd: Int32) {
            if fd == child.errorFD {
                shared.withLock { $0.log.append(String(decoding: bytes, as: UTF8.self)) }
                return
            }
            guard !sawMarker else { return }
            output += bytes
            if output.count > Self.outputKept { output.removeFirst(output.count - Self.outputKept) }
            guard String(decoding: output, as: UTF8.self).contains(marker) else { return }
            sawMarker = true
            output = []
            if UnixSocket.accepts(controlPath) {
                shared.withLock { $0.log.connected() }
                transition(to: .ready)
            } else {
                // Connected, but without its control socket nothing can use it.
                end(.failed(.other("Its control socket at \(controlPath) didn't open.")))
            }
        }

        while status == nil {
            var descriptors: [pollfd] = []
            if outputOpen { descriptors.append(pollfd(fd: child.outputFD, events: Int16(POLLIN), revents: 0)) }
            if errorsOpen { descriptors.append(pollfd(fd: child.errorFD, events: Int16(POLLIN), revents: 0)) }
            if let exitWatch { descriptors.append(pollfd(fd: exitWatch, events: Int16(POLLIN), revents: 0)) }
            // Without an exit watch (no pidfd), look every 100 ms.
            let ready = poll(&descriptors, nfds_t(descriptors.count), exitWatch == nil ? 100 : -1)
            if ready < 0, errno != EINTR { break }
            for descriptor in descriptors where descriptor.revents != 0 && descriptor.fd != exitWatch {
                if let bytes = readAvailable(descriptor.fd) {
                    took(bytes, from: descriptor.fd)
                } else if descriptor.fd == child.outputFD {
                    outputOpen = false
                } else {
                    errorsOpen = false
                }
            }
            status = shared.withLock { shared -> ExitStatus? in
                guard let status = child.reap() else { return nil }
                shared.reaped = true
                return status
            }
        }
        if status == nil {
            // poll failed outright: wait the hard way.
            shared.withLock { $0.reaped = true }
            status = child.waitForExit(timeoutMilliseconds: Int.max / 2)
        }

        // What it wrote just before it went, still in the pipes. Jump hops can hold them
        // open, so this takes only what is already there.
        for fd in [child.outputFD, child.errorFD] where fd >= 0 {
            while hasInput(fd), let bytes = readAvailable(fd) { took(bytes, from: fd) }
        }
        child.closeOutput()

        // A socket left behind would make the next master for this host run without one.
        if !UnixSocket.accepts(controlPath) { unlink(controlPath) }
        let ending = shared.withLock { shared -> Ending in
            shared.log.finish()
            if let asked = shared.asked { return asked }
            return .failed(shared.log.failure ?? Self.failure(for: status))
        }
        transition(to: .ended(ending))
    }

    /// What an exit with nothing on stderr means.
    static func failure(for status: ExitStatus?) -> ConnectionFailure {
        switch status {
        case .exited(code: 0): .closedByRemote
        case .exited(let code): .other("ssh exited with status \(code).")
        case .signaled(let signal): .other("ssh was ended by signal \(signal).")
        case nil: .other("ssh ended.")
        }
    }

    // MARK: - Leftovers

    /// Ends masters a crash left running, and removes sockets nothing listens on, among the
    /// control sockets in `folder` (`WRLDPaths.controlFolder`). Only names `WRLDPaths` makes
    /// are touched. Returns how many masters it ended.
    public static func cleanUpLeftovers(
        in folder: String, runner: any ProcessRunner, environment: [String: String]
    ) async -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return 0 }
        var ended = 0
        for name in names where name.count == 16 && name.allSatisfy(\.isHexDigit) {
            let path = folder + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { continue }
            if UnixSocket.accepts(path) {
                let exit = Command(
                    SSHCommand.control(.exit, socket: path), environment: environment, timeoutMilliseconds: 5_000)
                if let result = try? await runner.run(exit), result.succeeded { ended += 1 }
            } else {
                unlink(path)
            }
        }
        return ended
    }
}

/// Hands a value that isn't `Sendable` to the one thread that will own it from then on.
struct Handoff<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) { self.value = value }
}

/// Whether `fd` has something to read (or its end) right now.
func hasInput(_ fd: Int32) -> Bool {
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    return poll(&descriptor, 1, 0) > 0
}

/// One read of what `fd` has; nil at end of file or on an error.
func readAvailable(_ fd: Int32) -> [UInt8]? {
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { return nil }
        return Array(buffer[0..<count])
    }
}
