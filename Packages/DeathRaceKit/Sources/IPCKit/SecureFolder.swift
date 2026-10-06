#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Opens `folder` without following a symlink and checks this user owns it and nobody else
/// can write it, then tightens it to 0700. A folder someone else controls — a planted
/// symlink, a shared or misconfigured home — could otherwise let another user put a socket
/// where they receive what was meant for ours.
///
/// `what` names the folder in the error, so a failure says which one it was about.
public func secureFolder(_ folder: String, what: String) throws(UnixSocket.Failure) {
    let fd = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw .system("open \(what)", errno: errno) }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw .system("stat \(what)", errno: errno) }
    guard info.st_uid == getuid() else {
        throw .system("\(what) is owned by another user", errno: EPERM)
    }
    _ = fchmod(fd, 0o700)
    guard fstat(fd, &info) == 0, info.st_mode & 0o077 == 0 else {
        throw .system("\(what) is open to other users", errno: EPERM)
    }
}
