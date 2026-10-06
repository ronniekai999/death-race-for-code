#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// One holder at a time, for as long as the process lives.
///
/// `UnixSocket.listen` replaces whatever is at its path, so two processes starting at once
/// would both bind and the second would leave the first listening on a socket nothing points
/// at — a daemon still holding live sessions that nobody can reach again. Taking this first
/// settles which one listens, and the loser can exit before it touches the socket.
///
/// The lock is an `flock` on a file of its own, so the kernel releases it however the process
/// ends, crash included. The file is left behind; it is the lock on it that matters, not its
/// existence, which is why finding one says nothing about whether a daemon is running.
public final class ProcessLock: @unchecked Sendable {
    public let path: String
    private var fd: Int32

    private init(path: String, fd: Int32) {
        self.path = path
        self.fd = fd
    }

    /// Takes the lock at `path`, or nil if another process holds it — or if the file could
    /// not be opened at all, which a caller that must not proceed should treat the same way.
    public static func take(at path: String) -> ProcessLock? {
        // `O_NOFOLLOW`, and then a look at what was actually opened. The folder this sits in
        // keeps other users out and does nothing about another process of this one, and a
        // symlink planted here would otherwise have this process create a file wherever it
        // pointed — carrying whatever privacy attribution this process has, which may be more
        // than whoever planted it could get for themselves.
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            close(fd)
            return nil
        }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            close(fd)
            return nil
        }
        return ProcessLock(path: path, fd: fd)
    }

    /// Gives up the lock. Safe to call twice; `deinit` calls it.
    public func release() {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit {
        release()
    }
}
