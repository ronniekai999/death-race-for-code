import IPCKit

/// Who may speak to the daemon, and who the app will speak to.
///
/// Both ends check, and both start from the same place: the peer must be this user. On a Mac
/// there is more to say, and it matters more here than it does for the askpass broker — see
/// `PeerCode`. Where there is no code signing, `sameUser` is the whole of what can be
/// enforced, and the documentation says that rather than implying otherwise.
public enum PeerPolicy: Sendable, Equatable {
    case sameUser
    /// This user, **and** code satisfying `requirement`.
    case code(requirement: String)

    public func accepts(_ fd: Int32) -> Bool {
        guard peerIsThisUser(fd) else { return false }
        switch self {
        case .sameUser:
            return true
        case .code(let requirement):
            #if os(macOS)
                return PeerCode.peer(fd, satisfies: requirement)
            #else
                // Never quietly true: a build asked for a check it cannot make refuses
                // everyone, rather than claiming to have checked.
                return false
            #endif
        }
    }

    /// The strongest check this machine can make on code called `identifier`.
    ///
    /// On a Mac with a real signature that is the signature itself. Ad-hoc — a `swift run`, a
    /// build with no certificate — has no team to name, so it falls back to this user, and the
    /// caller is expected to say so once in its log rather than pretend.
    public static func strongest(for identifier: String) -> PeerPolicy {
        #if os(macOS)
            if let requirement = PeerCode.requirement(identifier: identifier) {
                return .code(requirement: requirement)
            }
        #endif
        return .sameUser
    }

    /// Whether this is only the weakest check, for a caller that wants to say so.
    public var isOnlySameUser: Bool { self == .sameUser }
}
