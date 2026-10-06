import CPTY

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Who is at the other end of a Unix socket.
public protocol PeerInspector: Sendable {
    func credentials(of fd: Int32) -> (pid: Int32, uid: UInt32)?
    func parent(of pid: Int32) -> Int32?
}

public struct SystemPeerInspector: PeerInspector {
    public init() {}

    public func credentials(of fd: Int32) -> (pid: Int32, uid: UInt32)? {
        var pid: pid_t = 0
        var uid: uid_t = 0
        guard cpty_peer_credentials(fd, &pid, &uid) == 0 else { return nil }
        return (Int32(pid), UInt32(uid))
    }

    public func parent(of pid: Int32) -> Int32? {
        let parent = cpty_parent_pid(pid_t(pid))
        return parent > 0 ? Int32(parent) : nil
    }
}

/// Whether the peer on `fd` is this user. The weakest check worth making, and the only one
/// Linux can make: on a machine with code signing, something stronger belongs on top.
public func peerIsThisUser(_ fd: Int32, _ peers: some PeerInspector = SystemPeerInspector()) -> Bool {
    peers.credentials(of: fd)?.uid == UInt32(getuid())
}
