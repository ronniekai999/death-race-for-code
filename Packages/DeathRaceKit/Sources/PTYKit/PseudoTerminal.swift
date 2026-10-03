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

    /// True while the program on the terminal has turned echo off, which is how password
    /// prompts look. Drives Secure Keyboard Entry; checked after each read batch, never polled.
    public var isEchoDisabled: Bool {
        cpty_echo_disabled(masterFD) == 1
    }

    /// Sends `signal` to the child's process group, which is how a terminal hangs up.
    public func signal(_ signal: Int32) {
        _ = kill(-pid, signal)
    }

    /// Collects the child's exit status. Non-blocking by default; returns nil while it runs.
    public func reap(wait: Bool = false) -> ExitStatus? {
        if let reaped { return reaped }
        var status: Int32 = 0
        let result = waitpid(pid, &status, wait ? 0 : WNOHANG)
        guard result == pid else { return nil }
        reaped = ExitStatus(waitStatus: status)
        return reaped
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

/// A NULL-terminated array of C strings that outlives a `withCString` scope.
private struct CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: count + 1)
        for (index, string) in strings.enumerated() {
            pointer[index] = strdup(string)
        }
        pointer[count] = nil
    }

    func deallocate() {
        for index in 0..<count { free(pointer[index]) }
        pointer.deallocate()
    }
}
