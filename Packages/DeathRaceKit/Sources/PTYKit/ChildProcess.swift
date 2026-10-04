import CPTY

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A program run without a terminal, on pipes: an ssh master, `ssh-keygen`, `sc_auth`.
///
/// Owned by one thread at a time, like `PseudoTerminal`, so it is deliberately not
/// `Sendable`. Spawned in a session of its own by default, so signals reach its whole
/// process group: an ssh master's ProxyJump hops end with it.
public final class ChildProcess {
    public let pid: pid_t
    /// True when the child leads a session of its own, and signals go to its process group.
    public let isSessionLeader: Bool
    /// The write end of the child's input; -1 once closed.
    public private(set) var inputFD: Int32
    /// The read ends of the child's output and errors; -1 once closed.
    public private(set) var outputFD: Int32
    public private(set) var errorFD: Int32
    private var reaped: ExitStatus?

    private init(pid: pid_t, isSessionLeader: Bool, input: Int32, output: Int32, errors: Int32) {
        self.pid = pid
        self.isSessionLeader = isSessionLeader
        inputFD = input
        outputFD = output
        errorFD = errors
    }

    /// Starts `executable` with `arguments` (argv[0] included) and exactly `environment`.
    public static func spawn(
        executable: String, arguments: [String], environment: [String: String],
        workingDirectory: String? = nil, newSession: Bool = true
    ) throws -> ChildProcess {
        let argv = CStringArray(arguments)
        let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" }.sorted())
        defer {
            argv.deallocate()
            envp.deallocate()
        }
        var child: pid_t = 0
        var input: Int32 = -1
        var output: Int32 = -1
        var errors: Int32 = -1
        let session: Int32 = newSession ? 1 : 0
        let status: Int32 = executable.withCString { path in
            if let workingDirectory {
                return workingDirectory.withCString { cwd in
                    cpty_spawn_pipes(path, argv.pointer, envp.pointer, cwd, session, &child, &input, &output, &errors)
                }
            }
            return cpty_spawn_pipes(path, argv.pointer, envp.pointer, nil, session, &child, &input, &output, &errors)
        }
        guard status == 0 else { throw PTYError.spawnFailed(errno: errno) }
        return ChildProcess(pid: child, isSessionLeader: newSession, input: input, output: output, errors: errors)
    }

    /// Writes all of `bytes` to the child's input, waiting while the pipe is full. False if
    /// the child stopped reading (it exited, or closed its input).
    @discardableResult
    public func writeInput(_ bytes: [UInt8]) -> Bool {
        guard inputFD >= 0 else { return false }
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                cpty_write_no_sigpipe(inputFD, buffer.baseAddress! + offset, buffer.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                var descriptor = pollfd(fd: inputFD, events: Int16(POLLOUT), revents: 0)
                _ = poll(&descriptor, 1, 1_000)
            } else {
                return false
            }
        }
        return true
    }

    /// Closes the child's input, so it reads end of file.
    public func closeInput() {
        guard inputFD >= 0 else { return }
        _ = close(inputFD)
        inputFD = -1
    }

    /// Stops reading the child's output and errors.
    public func closeOutput() {
        if outputFD >= 0 { _ = close(outputFD) }
        if errorFD >= 0 { _ = close(errorFD) }
        outputFD = -1
        errorFD = -1
    }

    /// Sends `signal` to the child's process group (or to the child alone, outside a session
    /// of its own). Never after it is reaped: its ids may belong to someone else by then.
    public func signal(_ signal: Int32) {
        guard reaped == nil else { return }
        _ = kill(isSessionLeader ? -pid : pid, signal)
    }

    /// Collects the exit status if the child has exited; never blocks.
    public func reap() -> ExitStatus? {
        if let reaped { return reaped }
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return nil }
        reaped = ExitStatus(waitStatus: status)
        return reaped
    }

    /// Waits up to `timeoutMilliseconds` for the child to exit; nil if it is still running.
    public func waitForExit(timeoutMilliseconds: Int) -> ExitStatus? {
        let deadline = PseudoTerminal.monotonicMilliseconds() + timeoutMilliseconds
        while true {
            if let status = reap() { return status }
            if PseudoTerminal.monotonicMilliseconds() >= deadline { return nil }
            var pause = timespec(tv_sec: 0, tv_nsec: 2_000_000)
            nanosleep(&pause, nil)
        }
    }

    /// A descriptor that becomes readable when the child exits (a kqueue on macOS, a pidfd
    /// on Linux), for `poll`; nil where neither exists. The caller closes it.
    public func makeExitWatch() -> Int32? {
        let fd = cpty_exit_watch(pid)
        return fd >= 0 ? fd : nil
    }

    deinit {
        closeInput()
        closeOutput()
    }
}

/// What a program run to the end printed, and how it ended.
public struct ChildResult: Sendable, Equatable {
    /// Nil only if the program outlived even SIGKILL's grace, which should not happen.
    public var status: ExitStatus?
    public var output: [UInt8]
    public var errors: [UInt8]
    /// The program ran past its time and was ended.
    public var timedOut: Bool

    public init(status: ExitStatus?, output: [UInt8], errors: [UInt8], timedOut: Bool) {
        self.status = status
        self.output = output
        self.errors = errors
        self.timedOut = timedOut
    }

    public var outputText: String { String(decoding: output, as: UTF8.self) }
    public var errorText: String { String(decoding: errors, as: UTF8.self) }
    public var succeeded: Bool { status == .exited(code: 0) && !timedOut }
}

extension ChildProcess {
    /// Runs a program to the end. `input` is written and then closed; output and errors are
    /// collected, up to `outputLimit` bytes each (the rest is read and dropped, so the
    /// program never blocks on a full pipe). A program still running after
    /// `timeoutMilliseconds` has its process group ended, SIGTERM then SIGKILL.
    ///
    /// Blocks the calling thread: run it off the main thread. A grandchild that keeps the
    /// pipes open after the program exits is not waited for longer than a moment.
    public static func run(
        executable: String, arguments: [String], environment: [String: String],
        workingDirectory: String? = nil, input: [UInt8] = [], timeoutMilliseconds: Int = 10_000,
        outputLimit: Int = 4 << 20
    ) throws -> ChildResult {
        let child = try spawn(
            executable: executable, arguments: arguments, environment: environment,
            workingDirectory: workingDirectory)
        for fd in [child.outputFD, child.errorFD] { setNonBlocking(fd) }
        var pending = ArraySlice(input)
        if pending.isEmpty { child.closeInput() } else { setNonBlocking(child.inputFD) }
        let exitWatch = child.makeExitWatch()
        defer { if let exitWatch { _ = close(exitWatch) } }

        enum Role { case output, errors, input, exit }
        var output: [UInt8] = []
        var errors: [UInt8] = []
        var exitedAt: Int?
        var timedOut = false
        let deadline = PseudoTerminal.monotonicMilliseconds() + timeoutMilliseconds
        // How long output still counts once the program itself has exited.
        let afterExit = 200

        while child.outputFD >= 0 || child.errorFD >= 0 {
            let now = PseudoTerminal.monotonicMilliseconds()
            if now >= deadline {
                timedOut = true
                break
            }
            if let exitedAt, now - exitedAt >= afterExit { break }
            var descriptors: [pollfd] = []
            var roles: [Role] = []
            if child.outputFD >= 0 {
                descriptors.append(pollfd(fd: child.outputFD, events: Int16(POLLIN), revents: 0))
                roles.append(.output)
            }
            if child.errorFD >= 0 {
                descriptors.append(pollfd(fd: child.errorFD, events: Int16(POLLIN), revents: 0))
                roles.append(.errors)
            }
            if !pending.isEmpty, child.inputFD >= 0 {
                descriptors.append(pollfd(fd: child.inputFD, events: Int16(POLLOUT), revents: 0))
                roles.append(.input)
            }
            if exitedAt == nil, let exitWatch {
                descriptors.append(pollfd(fd: exitWatch, events: Int16(POLLIN), revents: 0))
                roles.append(.exit)
            }
            var wait = min(deadline - now, 1_000)
            if let exitedAt { wait = min(wait, afterExit - (now - exitedAt)) }
            let ready = poll(&descriptors, nfds_t(descriptors.count), Int32(max(wait, 1)))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            for (index, descriptor) in descriptors.enumerated() where descriptor.revents != 0 {
                switch roles[index] {
                case .output:
                    if !drain(child.outputFD, into: &output, limit: outputLimit) { child.closeOutputPipe() }
                case .errors:
                    if !drain(child.errorFD, into: &errors, limit: outputLimit) { child.closeErrorPipe() }
                case .input:
                    let written = pending.withUnsafeBytes {
                        cpty_write_no_sigpipe(child.inputFD, $0.baseAddress, $0.count)
                    }
                    if written > 0 {
                        pending = pending.dropFirst(written)
                    } else if written < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                        pending = []
                    }
                    if pending.isEmpty { child.closeInput() }
                case .exit:
                    exitedAt = PseudoTerminal.monotonicMilliseconds()
                }
            }
        }
        child.closeInput()

        var status: ExitStatus?
        if !timedOut {
            let left = max(deadline - PseudoTerminal.monotonicMilliseconds(), 0)
            status = child.waitForExit(timeoutMilliseconds: left)
            timedOut = status == nil
        }
        if status == nil {
            child.signal(SIGTERM)
            status = child.waitForExit(timeoutMilliseconds: 1_000)
            if status == nil {
                child.signal(SIGKILL)
                status = child.waitForExit(timeoutMilliseconds: 1_000)
            }
        }
        child.closeOutput()
        return ChildResult(status: status, output: output, errors: errors, timedOut: timedOut)
    }

    private func closeOutputPipe() {
        guard outputFD >= 0 else { return }
        _ = close(outputFD)
        outputFD = -1
    }

    private func closeErrorPipe() {
        guard errorFD >= 0 else { return }
        _ = close(errorFD)
        errorFD = -1
    }
}

private func setNonBlocking(_ fd: Int32) {
    guard fd >= 0 else { return }
    let flags = fcntl(fd, F_GETFL)
    if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
}

/// Reads everything `fd` has now. False at end of file or on an error other than "try
/// again". Bytes past `limit` are read and dropped.
private func drain(_ fd: Int32, into bytes: inout [UInt8], limit: Int) -> Bool {
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count > 0 {
            let room = max(limit - bytes.count, 0)
            if room > 0 { bytes.append(contentsOf: buffer[0..<min(count, room)]) }
            continue
        }
        if count == 0 { return false }
        switch errno {
        case EINTR: continue
        case EAGAIN, EWOULDBLOCK: return true
        default: return false
        }
    }
}
