#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Wakes a thread blocked in `poll`: something writes a byte, the thread drains the pipe.
/// Both ends are non-blocking and close-on-exec; a full pipe already means "awake".
///
/// A session's thread waits on one, and so does every thread in the daemon, which is why it
/// sits here beside `Locked` rather than in either.
public final class WakePipe: Sendable {
    public let readFD: Int32
    public let writeFD: Int32

    public init() throws(PTYError) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw .pipeFailed(errno: errno) }
        for fd in fds {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        readFD = fds[0]
        writeFD = fds[1]
    }

    public func signal() {
        var byte: UInt8 = 1
        _ = write(writeFD, &byte, 1)
    }

    public func drain() {
        var buffer = [UInt8](repeating: 0, count: 64)
        while read(readFD, &buffer, buffer.count) > 0 {}
    }

    deinit {
        close(readFD)
        close(writeFD)
    }
}
