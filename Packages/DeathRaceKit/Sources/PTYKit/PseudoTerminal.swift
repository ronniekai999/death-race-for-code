import CPTY

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The size of a terminal in cells, plus the pixel size programs can ask for (CSI 14 t).
public struct TerminalSize: Sendable, Hashable {
    public var rows: UInt16
    public var columns: UInt16
    public var pixelWidth: UInt16
    public var pixelHeight: UInt16

    public init(rows: UInt16, columns: UInt16, pixelWidth: UInt16 = 0, pixelHeight: UInt16 = 0) {
        self.rows = rows
        self.columns = columns
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum PTYError: Error, Equatable, Sendable {
    case spawnFailed(errno: Int32)
    case resizeFailed(errno: Int32)
}

/// How a child process ended.
public enum ExitStatus: Sendable, Equatable {
    case exited(code: Int32)
    case signaled(signal: Int32)

    init(waitStatus status: Int32) {
        // The WIFEXITED / WEXITSTATUS macros are not visible to Swift.
        let signal = status & 0x7f
        self = signal == 0 ? .exited(code: (status >> 8) & 0xff) : .signaled(signal: signal)
    }
}

/// A child process attached to a pseudo-terminal.
///
/// Owned by exactly one thread (a session's IO thread), so it is deliberately not
/// `Sendable`. The master descriptor is non-blocking: callers wait with `poll` and read
/// until `.wouldBlock`, because a Darwin PTY hands back only about 1 KiB per `read`.
public final class PseudoTerminal {
    public enum ReadResult: Equatable {
        case bytes(Int)
        case wouldBlock
        case closed
    }

    public enum WriteResult: Equatable {
        case wrote(Int)
        case wouldBlock
        case closed
    }

    public let masterFD: Int32
    public let pid: pid_t
    private var isClosed = false
    private var reaped: ExitStatus?

    private init(masterFD: Int32, pid: pid_t) {
        self.masterFD = masterFD
        self.pid = pid
    }

    /// Starts `executable` on a new terminal of `size`.
    ///
    /// `arguments` includes argv[0]; pass `"-zsh"` style names for a login shell.
    public static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String? = nil,
        size: TerminalSize
    ) throws -> PseudoTerminal {
        let argv = CStringArray(arguments)
        let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" }.sorted())
        defer {
            argv.deallocate()
            envp.deallocate()
        }

        var master: Int32 = -1
        var child: pid_t = 0
        let status: Int32 = executable.withCString { path in
            if let workingDirectory {
                return workingDirectory.withCString { cwd in
                    cpty_spawn(
                        path, argv.pointer, envp.pointer, cwd,
                        size.rows, size.columns, size.pixelWidth, size.pixelHeight,
                        &master, &child)
                }
            }
            return cpty_spawn(
                path, argv.pointer, envp.pointer, nil,
                size.rows, size.columns, size.pixelWidth, size.pixelHeight,
                &master, &child)
        }
        guard status == 0 else { throw PTYError.spawnFailed(errno: errno) }
        return PseudoTerminal(masterFD: master, pid: child)
    }

    /// Reads what the child wrote. Retries on EINTR; EIO means every slave descriptor is
    /// gone (Linux), and 0 means end of file (macOS): both are `.closed`.
    public func read(into buffer: UnsafeMutableRawBufferPointer) -> ReadResult {
        guard !isClosed, let base = buffer.baseAddress, buffer.count > 0 else { return .closed }
        while true {
            let n = systemRead(masterFD, base, buffer.count)
            if n > 0 { return .bytes(n) }
            if n == 0 { return .closed }
            switch errno {
            case EINTR: continue
            case EAGAIN, EWOULDBLOCK: return .wouldBlock
            default: return .closed
            }
        }
    }

    /// Writes input for the child. A full kernel buffer returns `.wouldBlock` or a short
    /// count; the caller keeps the rest and waits for POLLOUT rather than spinning.
    public func write(_ bytes: UnsafeRawBufferPointer) -> WriteResult {
        guard !isClosed, let base = bytes.baseAddress else { return .closed }
        guard bytes.count > 0 else { return .wrote(0) }
        while true {
            let n = systemWrite(masterFD, base, bytes.count)
            if n >= 0 { return .wrote(n) }
            switch errno {
            case EINTR: continue
            case EAGAIN, EWOULDBLOCK: return .wouldBlock
            default: return .closed
            }
        }
    }

    /// Writes every byte, waiting for the terminal to drain when it is full. For tests and
    /// the smoke test; the session thread uses `write(_:)` with its own backpressure.
    @discardableResult
    public func writeAll(_ string: String, timeoutMilliseconds: Int32 = 2_000) -> Bool {
        var bytes = Array(string.utf8)
        while !bytes.isEmpty {
            let result = bytes.withUnsafeBytes { write($0) }
            switch result {
            case .wrote(let n): bytes.removeFirst(n)
            case .wouldBlock:
                if !poll(events: Int16(POLLOUT), timeoutMilliseconds: timeoutMilliseconds) { return false }
            case .closed: return false
            }
        }
        return true
    }

    /// Waits until the descriptor is ready for `events`, or the timeout passes.
    public func poll(events: Int16 = Int16(POLLIN), timeoutMilliseconds: Int32) -> Bool {
        var fds = pollfd(fd: masterFD, events: events, revents: 0)
        while true {
            let n = systemPoll(&fds, 1, timeoutMilliseconds)
            if n >= 0 { return n > 0 }
            if errno != EINTR { return false }
        }
    }

    public func resize(_ size: TerminalSize) throws {
        if cpty_set_size(masterFD, size.rows, size.columns, size.pixelWidth, size.pixelHeight) != 0 {
            throw PTYError.resizeFailed(errno: errno)
        }
    }

    /// The size the terminal reports to programs (TIOCGWINSZ).
    public var reportedSize: (rows: UInt16, columns: UInt16)? {
        var rows: UInt16 = 0
        var columns: UInt16 = 0
        return cpty_get_size(masterFD, &rows, &columns) == 0 ? (rows, columns) : nil
    }

    /// True while the program on the terminal reads a line with echo off: a password prompt
    /// (sudo, ssh, getpass). A shell's line editor also turns echo off, at every prompt, but
    /// reads in raw mode, so it does not count. Drives Secure Keyboard Entry; checked after
    /// each read batch, never polled.
    public var isReadingPassword: Bool {
        cpty_password_mode(masterFD) == 1
    }

    /// A descriptor that becomes readable when the child exits, to wait on with `poll`
    /// next to the master (a kqueue on macOS, a pidfd on Linux); nil where neither exists.
    /// The caller closes it. Exit shows up here even while a background job keeps the
    /// terminal open, which end of file on the master would miss.
    public func makeExitWatch() -> Int32? {
        let fd = cpty_exit_watch(pid)
        return fd >= 0 ? fd : nil
    }

    /// Sends `signal` to the child's process group. Never after the child is reaped: its
    /// process group id may belong to someone else by then.
    public func signal(_ signal: Int32) {
        guard reaped == nil else { return }
        _ = kill(-pid, signal)
    }

    /// Collects the child's exit status if it has exited; never blocks.
    public func reap() -> ExitStatus? {
        if let reaped { return reaped }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        guard result == pid else { return nil }
        reaped = ExitStatus(waitStatus: status)
        return reaped
    }

    /// Waits up to `timeoutMilliseconds` for the child to exit; nil if it is still running.
    ///
    /// A child with output nobody has read may be unable to finish exiting on macOS (see
    /// `hangUp`), so this never waits without a limit.
    public func waitForExit(timeoutMilliseconds: Int) -> ExitStatus? {
        let deadline = Self.monotonicMilliseconds() + timeoutMilliseconds
        while true {
            if let status = reap() { return status }
            if Self.monotonicMilliseconds() >= deadline { return nil }
            var pause = timespec(tv_sec: 0, tv_nsec: 2_000_000)
            nanosleep(&pause, nil)
        }
    }

    /// Ends the session the way closing a window does: the master closes, so the child sees
    /// the line drop, its process group gets SIGHUP, and the exit status is collected. A
    /// child still running after `graceMilliseconds` is killed.
    ///
    /// The master must close before waiting. On macOS the last close of a terminal's slave
    /// side waits for unread output to drain while the master is open (`ttywait`), so a
    /// shell that printed a prompt nobody read cannot finish exiting until the master
    /// either reads it or goes away. Waiting first deadlocks; Linux does not drain on close,
    /// which hides the bug there.
    @discardableResult
    public func hangUp(graceMilliseconds: Int = 2_000) -> ExitStatus? {
        close()
        signal(SIGHUP)
        if let status = waitForExit(timeoutMilliseconds: graceMilliseconds) { return status }
        signal(SIGKILL)
        return waitForExit(timeoutMilliseconds: graceMilliseconds)
    }

    /// Milliseconds on the monotonic clock, for deadlines.
    public static func monotonicMilliseconds() -> Int {
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC, &now)
        return Int(now.tv_sec) * 1_000 + Int(now.tv_nsec) / 1_000_000
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        _ = systemClose(masterFD)
    }

    deinit {
        close()
    }
}

// The free functions shadowed by the methods above.
private func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    read(fd, buffer, count)
}

private func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    write(fd, buffer, count)
}

private func systemPoll(_ fds: UnsafeMutablePointer<pollfd>, _ count: Int, _ timeout: Int32) -> Int32 {
    poll(fds, nfds_t(count), timeout)
}

private func systemClose(_ fd: Int32) -> Int32 {
    close(fd)
}
