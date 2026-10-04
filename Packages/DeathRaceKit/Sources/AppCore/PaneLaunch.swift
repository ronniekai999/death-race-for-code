import Vault

/// What a pane runs: your shell, or a session on a saved host.
public enum PaneLaunch: Equatable, Sendable {
    /// The login shell, or the settings file's `command`.
    case shell
    /// A session through the host's master: no new login once the master is up.
    case connection(HostRef)
    /// A plain ssh with its own login, for when the master can't be used.
    case plainSSH(HostRef)

    /// The host it connects to, if any.
    public var host: HostRef? {
        switch self {
        case .shell: nil
        case .connection(let host), .plainSSH(let host): host
        }
    }

    /// What a split from this pane runs: the same host, through the same master, so it
    /// opens at once. A split from a plain ssh shares its host too, but not a login.
    public var forSplit: PaneLaunch {
        switch self {
        case .shell: .shell
        case .connection(let host), .plainSSH(let host): .connection(host)
        }
    }
}
