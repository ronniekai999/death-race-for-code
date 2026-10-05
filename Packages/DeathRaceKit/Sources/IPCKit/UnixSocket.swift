import CPTY

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Unix-domain stream sockets: the askpass broker's, a master's control socket, and the
/// session daemon's.
public enum UnixSocket {
    public enum Failure: Error, Equatable {
        case pathTooLong(String)
        case system(String, errno: Int32)
    }

    public static func make() throws(Failure) -> Int32 {
        #if canImport(Darwin)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
            let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw .system("socket", errno: errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        #if canImport(Darwin)
            var on: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        return fd
    }

    /// Runs `body` with `path` as a `sockaddr_un`.
    public static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws(Failure)
        -> T
    {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity else { throw .pathTooLong(path) }
        address.sun_family = sa_family_t(AF_UNIX)
        #if canImport(Darwin)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// A connected socket to `path`, or nil if nothing listens there.
    public static func connect(to path: String) -> Int32? {
        guard let fd = try? make() else { return nil }
        let result = (try? withAddress(path) { address, length in systemConnect(fd, address, length) }) ?? -1
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Whether something accepts connections at `path`: a master's control socket is ready,
    /// or a daemon is already listening.
    ///
    /// It connects and hangs up, so it leaves a connection in the listener's backlog that the
    /// listener will accept and find already closed. Anything that both asks this and accepts
    /// has to expect one of those.
    public static func accepts(_ path: String) -> Bool {
        guard let fd = connect(to: path) else { return false }
        close(fd)
        return true
    }

    /// A listening socket at `path`, readable and writable by this user only. A stale socket
    /// left there by a crash is replaced.
    ///
    /// It replaces the socket **unconditionally**, so anything that must be the only listener
    /// at a path has to hold a `ProcessLock` before it calls this: two processes racing here
    /// would both bind, and the second would leave the first listening on a socket no name
    /// points at any more.
    public static func listen(at path: String) throws(Failure) -> Int32 {
        let fd = try make()
        unlink(path)
        let bound = try withAddress(path) { address, length in bind(fd, address, length) }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw .system("bind", errno: code)
        }
        chmod(path, 0o600)
        guard systemListen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw .system("listen", errno: code)
        }
        return fd
    }

    /// Writes all of `bytes`; false if the other end went away.
    public static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes {
                cpty_write_no_sigpipe(fd, $0.baseAddress! + offset, $0.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    /// Reads one framed payload no larger than `limit`, waiting at most
    /// `timeoutMilliseconds` in all (nil: no limit). Nil on timeout, end of file, or a frame
    /// too large.
    ///
    /// This waits, so it belongs to a handshake and not to a data path; a connection that
    /// carries frames both ways at once wants `FrameReader` and `FrameWriter` around its own
    /// `poll` instead.
    public static func readFrame(_ fd: Int32, limit: Int, timeoutMilliseconds: Int?) -> [UInt8]? {
        var reader = FrameReader(limit: limit)
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let deadline = timeoutMilliseconds.map { monotonicMilliseconds() + $0 }
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = deadline.map { Int32(max($0 - monotonicMilliseconds(), 0)) } ?? -1
            if let deadline, monotonicMilliseconds() >= deadline { return nil }
            let ready = poll(&descriptor, 1, wait)
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if ready == 0 { return nil }
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            let frames = reader.append(Array(buffer[0..<count]))
            if reader.isBroken { return nil }
            if let first = frames.first { return first }
        }
    }

    public static func monotonicMilliseconds() -> Int {
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC, &now)
        return Int(now.tv_sec) * 1_000 + Int(now.tv_nsec) / 1_000_000
    }
}

private func systemConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    connect(fd, address, length)
}

private func systemListen(_ fd: Int32, _ backlog: Int32) -> Int32 {
    listen(fd, backlog)
}
