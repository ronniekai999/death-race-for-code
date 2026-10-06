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
    /// **It throws away anything else that arrived with it.** One `recv` can bring several
    /// frames, and the reader that buffered them goes when this returns — so use it only
    /// where nothing can follow the frame being waited for. Where something can, keep a
    /// `FrameReader` and pass it to the overload below, which is the same call without the
    /// hole: a handshake reply and the first screen can land in the same read, and losing the
    /// screen means a session that never draws.
    ///
    /// This waits, so it belongs to a handshake and not to a data path; a connection that
    /// carries frames both ways at once wants `FrameReader` and `FrameWriter` around its own
    /// `poll` instead.
    public static func readFrame(_ fd: Int32, limit: Int, timeoutMilliseconds: Int?) -> [UInt8]? {
        var throwaway = FrameReader(limit: limit)
        return readFrame(fd, timeoutMilliseconds: timeoutMilliseconds, into: &throwaway)
    }

    /// The same, keeping what came with the frame in `reader`, for a caller that goes on
    /// reading the same socket — or hands `reader` to whatever does.
    public static func readFrame(
        _ fd: Int32, timeoutMilliseconds: Int?, into reader: inout FrameReader
    ) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let deadline = timeoutMilliseconds.map { monotonicMilliseconds() + $0 }
        // Something may already be assembled from an earlier call that read ahead.
        if let waiting = reader.next() { return waiting }
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
            var frames = reader.append(Array(buffer[0..<count]))
            if reader.isBroken { return nil }
            if !frames.isEmpty {
                let first = frames.removeFirst()
                // Whatever else came in the same read belongs to whoever reads next.
                reader.keep(frames)
                return first
            }
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

/// `close` under a name of its own, for a type with a `close()` method of its own — where
/// the bare call would mean the method.
public func closeDescriptor(_ fd: Int32) {
    close(fd)
}

extension UnixSocket {
    /// Makes `fd` non-blocking. A connection that carries frames both ways needs this: a
    /// blocking write into a full socket would stop whatever thread owns it, which for a
    /// session is the one thing that must not happen because of a slow client.
    public static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    /// Whether `fd` is readable, writable, or both, waiting at most `timeoutMilliseconds`
    /// (negative: for ever). Hung up counts as readable, so the caller finds the end of file.
    public static func wait(
        _ fd: Int32, forWriting: Bool, timeoutMilliseconds: Int32
    ) -> (readable: Bool, writable: Bool) {
        let ready = wait(fd, forWriting: forWriting, wake: -1, timeoutMilliseconds: timeoutMilliseconds)
        return (ready.readable, ready.writable)
    }

    /// The same, waiting on a wake pipe as well.
    ///
    /// A loop that owns a socket almost always has something else to be told about — a screen
    /// to hand over, an answer that finished on another thread, a message queued for it — and
    /// waiting on the socket alone means none of that moves until the far end happens to say
    /// something. Pass `wake` as -1 for a loop that genuinely has only the socket.
    public static func wait(
        _ fd: Int32, forWriting: Bool, wake: Int32, timeoutMilliseconds: Int32
    ) -> (readable: Bool, writable: Bool, woken: Bool) {
        wait(fd, forReading: true, forWriting: forWriting, wake: wake, timeoutMilliseconds: timeoutMilliseconds)
    }

    /// The same, for a loop that must stop watching for readability.
    ///
    /// A loop that is holding something it could not pass on, and so will not read its socket
    /// this pass, has to stop asking about readability too: the bytes are still there, `poll`
    /// would return at once every time, and the loop would spin a core instead of waiting.
    /// Leaving them unread is what makes the kernel hold the other end up.
    public static func wait(
        _ fd: Int32, forReading: Bool, forWriting: Bool, wake: Int32, timeoutMilliseconds: Int32
    ) -> (readable: Bool, writable: Bool, woken: Bool) {
        var events = Int16(0)
        if forReading { events |= Int16(POLLIN) }
        if forWriting { events |= Int16(POLLOUT) }
        var watched = [pollfd(fd: fd, events: events, revents: 0)]
        if wake >= 0 { watched.append(pollfd(fd: wake, events: Int16(POLLIN), revents: 0)) }
        guard poll(&watched, nfds_t(watched.count), timeoutMilliseconds) > 0 else {
            return (false, false, false)
        }
        let trouble = Int16(POLLHUP | POLLERR | POLLNVAL)
        let hangUp = watched[0].revents & trouble != 0
        return (
            watched[0].revents & Int16(POLLIN) != 0 || hangUp,
            watched[0].revents & Int16(POLLOUT) != 0,
            watched.count > 1 && watched[1].revents & Int16(POLLIN) != 0
        )
    }
}
