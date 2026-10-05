import Foundation
import IPCKit
import PTYKit
import ScreenProtocol
import SessionKit
import VTCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// How a daemon is started when nothing is listening yet.
///
/// A seam, because which way is right is the one thing about Phase 7 that a Mac has to
/// answer: a daemon the app spawns inherits the app's privacy attribution, where one launchd
/// starts is its own responsible process. Swapping this is swapping a file.
public protocol DaemonLauncher: Sendable {
    /// Starts a daemon. A failure needs no error: it shows up as nothing listening, which the
    /// host already has to handle.
    func start(socketPath: String, lockPath: String)
}

/// Starts `legendsd` as a child of this process, in a session of its own so it outlives it.
///
/// Not a double fork, which this project does not do: one `posix_spawn` with `setsid`, so the
/// daemon leaves the app's process group — and keeps the app as the process macOS holds
/// responsible for it, which is the whole reason to start it this way.
public final class SpawnLauncher: DaemonLauncher {
    private let executable: String
    private let logPath: String?
    private let environment: [String: String]
    private let extra: [String]
    /// Kept only so a daemon that exits while the app runs can be reaped rather than left a
    /// zombie. The daemon usually outlives the app, in which case this never matters.
    private let child = Locked<ChildProcess?>(nil)

    public init(
        executable: String, logPath: String? = nil, environment: [String: String] = ["PATH": "/usr/bin:/bin"],
        extra: [String] = []
    ) {
        self.executable = executable
        self.logPath = logPath
        self.environment = environment
        self.extra = extra
    }

    public func start(socketPath: String, lockPath: String) {
        child.withLock { child in
            if let waiting = child, waiting.reap() != nil { child = nil }
        }
        var arguments = ["legendsd", "--socket", socketPath, "--lock", lockPath]
        if let logPath { arguments += ["--log", logPath] }
        arguments += extra
        let started = try? ChildProcess.spawn(
            executable: executable, arguments: arguments, environment: environment, workingDirectory: "/",
            newSession: true)
        // Its own standard streams are a log of its own by now, so ours are no use to it.
        started?.closeInput()
        started?.closeOutput()
        child.withLock { $0 = started }
    }
}

/// The app's end of the control connection: one question at a time, each answered before the
/// next is asked.
///
/// Synchronous on purpose. Nothing here is on the path from a keystroke to the screen — that
/// is the session's own connection — and the three things the app asks happen when a window
/// opens or closes. A thread and a correlator would buy nothing and cost the one place where
/// a reply can be dropped.
/// Unchecked, and honestly so: every mutable thing below is touched only with `gate` held,
/// and the three public calls take it for their whole length, so one question is in flight at
/// a time by construction.
final class ControlClient: @unchecked Sendable {
    private let socket: Int32
    private let gate = NSLock()
    private var reader: FrameReader
    private var assembled: [[UInt8]] = []
    private var announcements: [ControlReply] = []
    private var nextRequest: UInt32 = 1
    private var buffer = [UInt8](repeating: 0, count: 16 * 1024)

    let daemon: DaemonFacts

    init(socket: Int32, daemon: DaemonFacts, reader: FrameReader) {
        self.reader = reader
        self.socket = socket
        self.daemon = daemon
    }

    deinit {
        _ = UnixSocket.writeAll(socket, Frames.framed(ControlRequest.goodbye.encode()))
        closeDescriptor(socket)
    }

    /// Asks something that is answered, waiting at most `deadline` for it.
    func exchange(
        numbered make: (UInt32) -> ControlRequest, deadline: Int
    ) throws(SessionHostError) -> ControlReply {
        gate.lock()
        defer { gate.unlock() }
        let number = nextRequest
        nextRequest &+= 1
        try write(make(number))
        return try waitForReply(matching: number, deadline: deadline)
    }

    func list(deadline: Int) throws(SessionHostError) -> [SessionDescription] {
        gate.lock()
        defer { gate.unlock() }
        try write(.list)
        guard case .sessions(let list) = try waitForReply(matching: nil, deadline: deadline) else {
            throw .refused("the daemon answered something else")
        }
        return list
    }

    /// Says something that needs no answer.
    func tell(_ request: ControlRequest) {
        gate.lock()
        defer { gate.unlock() }
        _ = UnixSocket.writeAll(socket, Frames.framed(request.encode()))
    }

    /// Sessions whose shells ended while the app was not asking. Taking them clears them.
    func takeAnnouncements() -> [ControlReply] {
        gate.lock()
        defer { gate.unlock() }
        defer { announcements = [] }
        return announcements
    }

    private func write(_ request: ControlRequest) throws(SessionHostError) {
        guard UnixSocket.writeAll(socket, Frames.framed(request.encode())) else {
            throw .unreachable("the daemon stopped listening")
        }
    }

    /// Reads until the reply to `number` arrives — or, for a listing, the first reply that is
    /// not an announcement. Anything unasked for is kept rather than thrown away.
    private func waitForReply(matching number: UInt32?, deadline: Int) throws(SessionHostError) -> ControlReply {
        let until = UnixSocket.monotonicMilliseconds() + deadline
        while true {
            guard let payload = try nextFrame(until: until) else {
                throw .unreachable("the daemon did not answer in time")
            }
            guard let reply = try? ControlReply.decode(payload) else {
                throw .refused("the daemon said something unreadable")
            }
            switch reply {
            case .sessionEnded:
                announcements.append(reply)
            case .ready(let answered, _, _), .failed(let answered, _, _):
                if number == nil || answered == number { return reply }
            case .sessions:
                if number == nil { return reply }
            }
        }
    }

    private func nextFrame(until: Int) throws(SessionHostError) -> [UInt8]? {
        while true {
            if !assembled.isEmpty { return assembled.removeFirst() }
            if let early = reader.next() { return early }
            let left = until - UnixSocket.monotonicMilliseconds()
            guard left > 0 else { return nil }
            guard UnixSocket.wait(socket, forWriting: false, timeoutMilliseconds: Int32(clamping: left)).readable
            else { return nil }
            let count = buffer.withUnsafeMutableBytes { recv(socket, $0.baseAddress, $0.count, 0) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw .unreachable("the connection to the daemon broke")
            }
            guard count > 0 else { throw .unreachable("the daemon closed the connection") }
            assembled += reader.append(Array(buffer[0..<count]))
            if reader.isBroken { throw .refused("the daemon sent a frame larger than allowed") }
        }
    }
}

/// Sessions from `legendsd`: they outlive this process.
///
/// Connecting, starting and taking up all block on a deadline rather than being `async`. A
/// pane already spawns its shell on the main actor, a round trip to a socket on this machine
/// costs the same order, and making them async would turn restoring a window into a state
/// machine for nothing anyone would see. Past the deadline they throw, and the app runs its
/// sessions in process instead.
public final class DaemonHost: SessionHost {
    public struct Paths: Sendable {
        public var socket: String
        public var lock: String

        public init(socket: String, lock: String) {
            self.socket = socket
            self.lock = lock
        }
    }

    private let paths: Paths
    private let launcher: any DaemonLauncher
    private let deadline: Int
    private let control: ControlClient

    public var sessionsSurviveQuit: Bool { true }

    /// What the daemon said about itself, for a log or an honest sentence on screen.
    public var daemon: DaemonFacts { control.daemon }

    /// Connects, starting a daemon if nothing is listening. Throws when there is no daemon to
    /// talk to, or none this build can talk to — in both cases the app should fall back to
    /// running sessions in process, and say so.
    public init(
        paths: Paths, launcher: any DaemonLauncher, deadlineMilliseconds: Int = 2_000
    ) throws(SessionHostError) {
        self.paths = paths
        self.launcher = launcher
        deadline = deadlineMilliseconds
        var greeting = try Self.greet(
            paths: paths, launcher: launcher, role: .control, deadline: deadlineMilliseconds)
        control = ControlClient(
            socket: greeting.socket, daemon: greeting.daemon, reader: greeting.reader)
    }

    // MARK: - Connecting

    /// A connected socket that has already shaken hands, starting a daemon if there is none.
    private static func greet(
        paths: Paths, launcher: (any DaemonLauncher)?, role: Role, deadline: Int
    ) throws(SessionHostError) -> (socket: Int32, daemon: DaemonFacts, reader: FrameReader) {
        let until = UnixSocket.monotonicMilliseconds() + deadline
        var asked = false
        while true {
            if let socket = UnixSocket.connect(to: paths.socket) {
                // Before a word is sent: a socket another account planted under our path gets
                // nothing. The daemon checks us in the same way from its side.
                guard peerIsThisUser(socket) else {
                    closeDescriptor(socket)
                    throw .refused("something that is not yours is listening at \(paths.socket)")
                }
                var reader = FrameReader(limit: SessionWire.largestSessionFrame)
                do {
                    let daemon = try shakeHands(socket, role: role, deadline: until, into: &reader)
                    return (socket, daemon, reader)
                } catch {
                    closeDescriptor(socket)
                    throw error
                }
            }
            guard let launcher, !asked else {
                throw .unreachable("nothing is listening at \(paths.socket)")
            }
            launcher.start(socketPath: paths.socket, lockPath: paths.lock)
            asked = true
            while UnixSocket.monotonicMilliseconds() < until {
                if UnixSocket.accepts(paths.socket) { break }
                usleep(20_000)
            }
            guard UnixSocket.monotonicMilliseconds() < until else {
                throw .unreachable("the session daemon did not start")
            }
        }
    }

    private static func shakeHands(
        _ socket: Int32, role: Role, deadline until: Int, into reader: inout FrameReader
    ) throws(SessionHostError) -> DaemonFacts {
        guard
            UnixSocket.writeAll(
                socket, Frames.framed(Preamble.hello(speaks: SessionWire.versions, role: role).encode()))
        else { throw .unreachable("the daemon would not listen") }
        let left = max(until - UnixSocket.monotonicMilliseconds(), 1)
        guard
            let payload = UnixSocket.readFrame(socket, timeoutMilliseconds: left, into: &reader),
            let preamble = try? Preamble.decode(payload)
        else { throw .unreachable("the daemon did not say hello back") }
        switch preamble {
        case .welcome(_, _, let daemon):
            // One version pins one screen format; a mismatch here means the two were built
            // from different trees and the version numbers were not kept honest.
            guard daemon.deltaFormat == DeltaCodec.formatVersion else {
                throw .incompatible(
                    ours: SessionWire.versions, theirs: SessionWire.versions, build: daemon.build)
            }
            return daemon
        case .incompatible(let theirs, let build):
            throw .incompatible(ours: SessionWire.versions, theirs: theirs, build: build)
        case .hello:
            throw .refused("the daemon answered with a hello of its own")
        }
    }

    // MARK: - What a host does

    public func existing() throws(SessionHostError) -> [SessionDescription] {
        try control.list(deadline: deadline)
    }

    public func start(
        _ launch: ShellLaunch, configuration: Terminal.Configuration, metadata: [UInt8],
        onUpdate: @escaping @Sendable () -> Void
    ) throws(SessionHostError) -> any ShellSession {
        let reply = try control.exchange(
            numbered: { .spawn(request: $0, launch: launch, configuration: configuration, metadata: metadata) },
            deadline: deadline)
        // A session it has just started holds nothing, so there is nothing to catch up on.
        return try watch(reply, wantsSnapshot: false, onUpdate: onUpdate)
    }

    public func adopt(
        _ id: SessionID, onUpdate: @escaping @Sendable () -> Void
    ) throws(SessionHostError) -> any ShellSession {
        let reply = try control.exchange(numbered: { .adopt(request: $0, id: id) }, deadline: deadline)
        // Taking one up, the screen is whatever happened while nobody was watching.
        return try watch(reply, wantsSnapshot: true, onUpdate: onUpdate)
    }

    public func setMetadata(_ metadata: [UInt8], for id: SessionID) {
        control.tell(.setMetadata(id: id, metadata: metadata))
    }

    public func end(_ id: SessionID) {
        control.tell(.end(id: id))
    }

    /// Tells a daemon this build cannot talk to to finish what it is holding and start
    /// nothing more. It is never killed: its sessions are what the feature exists to keep.
    public func askToHandOver() {
        control.tell(.handOver)
    }

    /// Sessions whose shells ended while nothing was watching them.
    public func endingsSinceLastAsked() -> [(id: SessionID, status: Session.Status)] {
        control.takeAnnouncements().compactMap { reply in
            guard case .sessionEnded(let id, let status) = reply else { return nil }
            return (id, status)
        }
    }

    /// Opens a session's own connection and attaches to it.
    private func watch(
        _ reply: ControlReply, wantsSnapshot: Bool, onUpdate: @escaping @Sendable () -> Void
    ) throws(SessionHostError) -> any ShellSession {
        switch reply {
        case .failed(_, let reason, let detail):
            throw Self.failure(reason, detail)
        case .ready(_, let id, let token):
            // No launcher: a daemon that answered a moment ago and is gone now is a failure,
            // not a reason to start a second one underneath the first.
            var greeting = try Self.greet(paths: paths, launcher: nil, role: .session, deadline: deadline)
            guard
                UnixSocket.writeAll(
                    greeting.socket,
                    Frames.framed(
                        StreamRequest.attach(id: id, token: token, wantsSnapshot: wantsSnapshot).encode()))
            else {
                closeDescriptor(greeting.socket)
                throw .unreachable("the daemon would not take the session's connection")
            }
            guard
                let payload = UnixSocket.readFrame(
                    greeting.socket, timeoutMilliseconds: deadline, into: &greeting.reader),
                let answer = try? StreamReply.decode(payload)
            else {
                closeDescriptor(greeting.socket)
                throw .unreachable("the daemon did not answer the session's connection")
            }
            guard case .attached = answer else {
                closeDescriptor(greeting.socket)
                if case .refused(let reason) = answer { throw Self.failure(reason, "") }
                throw .refused("the daemon answered a session's connection with something else")
            }
            guard let wake = try? WakePipe() else {
                closeDescriptor(greeting.socket)
                throw .unreachable("this process is out of descriptors")
            }
            return RemoteSession(
                id: id, socket: greeting.socket, wake: wake, reader: greeting.reader, onUpdate: onUpdate)
        case .sessions, .sessionEnded:
            throw .refused("the daemon answered something else")
        }
    }

    private static func failure(_ reason: Refusal, _ detail: String) -> SessionHostError {
        switch reason {
        case .atCapacity: .atCapacity(limit: 0)
        case .unknownSession: .unknownSession(SessionID(0))
        case .alreadyAttached: .alreadyAttached(SessionID(0))
        case .shellWouldNotStart: .start(detail.isEmpty ? "the shell would not start" : detail)
        case .handingOver: .refused(detail.isEmpty ? "that daemon is finishing" : detail)
        case .malformed: .refused(detail.isEmpty ? "the daemon did not understand" : detail)
        }
    }
}
