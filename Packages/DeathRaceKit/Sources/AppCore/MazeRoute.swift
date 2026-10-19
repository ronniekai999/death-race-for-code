import Vault

/// Where Open in Maze goes, from wherever it was asked.
///
/// Maze browses a host's files, so a local shell has none to show. Rather than an item that is
/// off there with nothing to say why, it asks which host, and with none saved it goes to New
/// Host and on to Maze once one is added.
public enum MazeRoute: Equatable, Sendable {
    /// Straight to this host's files.
    case open(HostRef)
    /// Ask which, in this order.
    case choose([HostID])
    /// No host to browse yet: New Host, then Maze on the one added.
    case addHost

    /// The pane's own host when it runs on one; otherwise the one saved host, or a choice of
    /// them with Legends first, as the sidebar lists them.
    public init(pane: HostRef?, hosts: [WRLDHost]) {
        if let pane {
            self = .open(pane)
            return
        }
        switch hosts.count {
        case 0: self = .addHost
        case 1: self = .open(.vault(hosts[0].id))
        default: self = .choose((hosts.filter(\.isLegend) + hosts.filter { !$0.isLegend }).map(\.id))
        }
    }
}
