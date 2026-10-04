/// The changes WRLD's window and sidebar make, as plain values: each keeps the vault's
/// references whole, so a removed host leaves no host jumping through it and a removed
/// snippet leaves no host running it on connect.
extension Vault {
    // MARK: - Hosts

    /// The hosts that reach `host` as their jump host: what removing it would change.
    public func hosts(jumpingThrough host: HostID) -> [WRLDHost] {
        hosts.filter { $0.connection?.jumpHostID == host }
    }

    /// The hosts `host` may jump through: WRLD's own, less itself and any that would come
    /// back to it (a host that jumps through it, however many hops on).
    public func jumpChoices(for host: HostID?) -> [WRLDHost] {
        hosts.filter { candidate in
            guard candidate.connection != nil, candidate.id != host else { return false }
            guard let host else { return true }
            var seen: Set<HostID> = []
            var next = candidate.connection?.jumpHostID
            while let hop = next, seen.insert(hop).inserted {
                if hop == host { return false }
                next = self.host(hop)?.connection?.jumpHostID
            }
            return true
        }
    }

    /// `host` in place of the one with its id; nothing when there's none.
    public mutating func update(_ host: WRLDHost) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index] = host
    }

    /// Takes `host` out. Hosts that jumped through it connect directly from then on (the
    /// window names them before asking).
    public mutating func removeHost(_ id: HostID) {
        hosts.removeAll { $0.id == id }
        for index in hosts.indices {
            guard case .wrld(var connection) = hosts[index].source, connection.jumpHostID == id else { continue }
            connection.jumpHostID = nil
            hosts[index].source = .wrld(connection)
        }
    }

    /// Pins `host` to Legends, or takes it off.
    public mutating func setLegend(_ id: HostID, _ isLegend: Bool) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].isLegend = isLegend
    }

    /// Adds a host for each `~/.ssh/config` name WRLD doesn't hold yet.
    public mutating func importAliases(_ aliases: [String]) {
        var held = Set(hosts.compactMap(\.sshConfigAlias))
        for alias in aliases where held.insert(alias).inserted {
            hosts.append(WRLDHost(name: alias, source: .sshConfig(alias: alias)))
        }
    }

    // MARK: - Groups

    /// A new group named `name`, or the one that's already called that (ignoring case).
    @discardableResult
    public mutating func addGroup(named name: String) -> GroupID {
        let trimmed = name.trimmingSpaces
        if let existing = groups.first(where: { $0.name.lowercased() == trimmed.lowercased() }) { return existing.id }
        let group = Group(name: trimmed)
        groups.append(group)
        return group.id
    }

    public mutating func renameGroup(_ id: GroupID, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }), !name.trimmingSpaces.isEmpty else { return }
        groups[index].name = name.trimmingSpaces
    }

    /// Takes the group out; its hosts stay, in no group.
    public mutating func removeGroup(_ id: GroupID) {
        groups.removeAll { $0.id == id }
        for index in hosts.indices where hosts[index].groupID == id { hosts[index].groupID = nil }
    }

    /// Puts `host` in `group`, or in none.
    public mutating func move(_ host: HostID, to group: GroupID?) {
        guard let index = hosts.firstIndex(where: { $0.id == host }),
            group.map({ id in groups.contains { $0.id == id } }) ?? true
        else { return }
        hosts[index].groupID = group
    }

    // MARK: - Come & Go

    /// Why a tunnel can't be added as it is.
    public enum TunnelProblem: Error, Equatable, Sendable {
        case spec(TunnelSpec.Problem)
        /// Another tunnel already listens there, on this Mac (or on the same server, for a
        /// remote one); the two couldn't be open at once.
        case clash(with: String)

        public var sentence: String {
            switch self {
            case .spec(.port(let port)): "\(port) isn't a port: ports go from 1 to 65535."
            case .spec(.host(let host)): "“\(host)” isn't a host name or address ssh takes."
            case .spec(.missingTarget): "Say where it forwards to, as host:port."
            case .clash(let other): "\(other) listens there already."
            }
        }
    }

    /// The tunnel that listens where `spec` would: on this Mac for local and dynamic ones,
    /// on the same server for remote ones.
    public func tunnel(listeningLike spec: TunnelSpec, on host: HostID, except: TunnelID? = nil) -> (WRLDHost, Tunnel)?
    {
        for other in hosts {
            for tunnel in other.tunnels where tunnel.id != except && tunnel.spec.listenPort == spec.listenPort {
                let otherOnThisMac = tunnel.spec.kind != .remote
                let onThisMac = spec.kind != .remote
                guard otherOnThisMac == onThisMac else { continue }
                if !onThisMac && other.id != host { continue }
                return (other, tunnel)
            }
        }
        return nil
    }

    /// Adds `tunnel` to `host`, after checking it.
    public mutating func addTunnel(_ tunnel: Tunnel, to host: HostID) throws(TunnelProblem) {
        if let problem = tunnel.spec.problems.first { throw .spec(problem) }
        if let (other, existing) = self.tunnel(listeningLike: tunnel.spec, on: host) {
            throw .clash(with: existing.spec.summary(host: other.name))
        }
        guard let index = hosts.firstIndex(where: { $0.id == host }) else { return }
        hosts[index].tunnels.append(tunnel)
    }

    public mutating func removeTunnel(_ id: TunnelID) {
        for index in hosts.indices { hosts[index].tunnels.removeAll { $0.id == id } }
    }

    public mutating func setOpensWithConnection(_ id: TunnelID, _ opens: Bool) {
        for index in hosts.indices {
            guard let tunnel = hosts[index].tunnels.firstIndex(where: { $0.id == id }) else { continue }
            hosts[index].tunnels[tunnel].opensWithConnection = opens
        }
    }

    /// The host a tunnel belongs to.
    public func host(holding tunnel: TunnelID) -> WRLDHost? {
        hosts.first { $0.tunnels.contains { $0.id == tunnel } }
    }

    // MARK: - Wishing Well

    /// Adds `snippet`, or changes the one with its id.
    public mutating func save(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
    }

    /// The hosts that type `snippet` when they connect.
    public func hosts(runningOnConnect snippet: SnippetID) -> [WRLDHost] {
        hosts.filter { $0.onConnectSnippetID == snippet }
    }

    /// Takes the snippet out, and off every host that ran it on connect.
    public mutating func removeSnippet(_ id: SnippetID) {
        snippets.removeAll { $0.id == id }
        for index in hosts.indices where hosts[index].onConnectSnippetID == id {
            hosts[index].onConnectSnippetID = nil
        }
    }
}
