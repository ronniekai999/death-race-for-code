#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Wakes a thread blocked in `poll`: the app writes a byte, the session thread drains the
/// pipe. Both ends are non-blocking and close-on-exec; a full pipe already means "awake".
final class WakePipe: Sendable {
    let readFD: Int32
    let writeFD: Int32

    init() throws(SessionError) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw .wakePipe(errno: errno) }
        for fd in fds {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        readFD = fds[0]
        writeFD = fds[1]
    }

    func signal() {
        var byte: UInt8 = 1
        _ = write(writeFD, &byte, 1)
    }

    func drain() {
        var buffer = [UInt8](repeating: 0, count: 64)
        while read(readFD, &buffer, buffer.count) > 0 {}
    }

    deinit {
        close(readFD)
        close(writeFD)
    }
}
