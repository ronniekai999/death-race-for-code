import Vault

/// Where Open in Maze goes, from wherever it was asked.
///
/// Maze browses a host's files, so a local shell has none to show. Rather than an item that is
/// off there with nothing to say why, it asks which host, and with none it goes to New Host and
/// on to Maze once one is added.
public enum MazeRoute: Equatable, Sendable {
    /// Straight to this host's files.
    case open(HostRef)
    /// Ask which, in this order.
    case choose([HostRef])
    /// No host to browse yet: New Host, then Maze on the one added.
    case addHost

    /// The pane's own host when it runs on one; otherwise the one host there is, or a choice of
    /// them in Hear Me Calling's order: Legends, the rest of WRLD, then the `~/.ssh/config`
    /// names WRLD doesn't hold, which Maze opens as readily as a saved host.
    public init(pane: HostRef?, hosts: [WRLDHost], aliases: [String]) {
        if let pane {
            self = .open(pane)
            return
        }
        let held = Set(hosts.compactMap(\.sshConfigAlias))
        let saved = (hosts.filter(\.isLegend) + hosts.filter { !$0.isLegend }).map { HostRef.vault($0.id) }
        var seen = held
        let named = aliases.filter { seen.insert($0).inserted }.map { HostRef.sshConfig(alias: $0) }
        let all = saved + named
        switch all.count {
        case 0: self = .addHost
        case 1: self = .open(all[0])
        default: self = .choose(all)
        }
    }
}
