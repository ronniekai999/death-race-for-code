import Foundation
import Vault

/// The WRLD window apart from its views: the list down its side with counts, the host
/// cards a choice shows under their headings, searching, the summary in the title row,
/// and the offer to add the hosts `~/.ssh/config` names.
public enum WRLDBoard {
    /// What the list down the side can show.
    public enum Place: Hashable, Sendable {
        case allHosts, legends
        case group(GroupID)
        case keys, wishingWell, comeAndGo, knownHosts
    }

    public struct ListRow: Equatable, Sendable, Identifiable {
        public var place: Place
        public var title: String
        public var count: Int
        /// The SF Symbol before it.
        public var symbol: String

        public var id: Place { place }
    }

    /// All hosts, Legends and each group, with how many hosts each holds.
    public static func hostRows(vault: Vault) -> [ListRow] {
        [
            ListRow(place: .allHosts, title: "All hosts", count: vault.hosts.count, symbol: "circle.grid.2x2"),
            ListRow(place: .legends, title: "Legends", count: vault.hosts.filter(\.isLegend).count, symbol: "star"),
        ]
            + vault.groups.map { group in
                ListRow(
                    place: .group(group.id), title: group.name,
                    count: vault.hosts.filter { $0.groupID == group.id }.count, symbol: "folder")
            }
    }

    /// The vault's own pages: Keys, Wishing Well, Come & Go and Known hosts.
    public static func vaultRows(vault: Vault, knownHosts: Int) -> [ListRow] {
        [
            ListRow(place: .keys, title: "Keys", count: vault.keys.count, symbol: "key"),
            ListRow(place: .wishingWell, title: "Wishing Well", count: vault.snippets.count, symbol: "chevron.right.2"),
            ListRow(place: .comeAndGo, title: "Come & Go", count: tunnelCount(vault), symbol: "arrow.left.arrow.right"),
            ListRow(place: .knownHosts, title: "Known hosts", count: knownHosts, symbol: "checkmark.shield"),
        ]
    }

    /// Cards under a heading.
    public struct CardSection: Equatable, Sendable, Identifiable {
        public var title: String
        public var hosts: [WRLDHost]

        public var id: String { title }
    }

    /// The cards `place` shows that match `query`: for all hosts, Legends first, then each
    /// group without the Legends already shown, then the hosts in none. Empty headings are
    /// left out; the vault's own pages have no cards.
    public static func cards(for place: Place, vault: Vault, query: String = "") -> [CardSection] {
        let shown = vault.hosts.filter { matches($0, query: query, vault: vault) }
        let sections: [CardSection]
        switch place {
        case .allHosts:
            sections =
                [CardSection(title: "Legends", hosts: shown.filter(\.isLegend))]
                + vault.groups.map { group in
                    CardSection(title: group.name, hosts: shown.filter { $0.groupID == group.id && !$0.isLegend })
                }
                + [
                    CardSection(
                        title: vault.groups.isEmpty && !shown.contains(where: \.isLegend) ? "Hosts" : "Other hosts",
                        hosts: shown.filter { host in
                            !host.isLegend && (host.groupID.flatMap(vault.group) == nil)
                        })
                ]
        case .legends:
            sections = [CardSection(title: "Legends", hosts: shown.filter(\.isLegend))]
        case .group(let id):
            sections = [
                CardSection(title: vault.group(id)?.name ?? "Group", hosts: shown.filter { $0.groupID == id })
            ]
        case .keys, .wishingWell, .comeAndGo, .knownHosts:
            sections = []
        }
        return sections.filter { !$0.hosts.isEmpty }
    }

    /// Whether `host` is found by `query`: in its name, address, user, `~/.ssh/config`
    /// name, tags or group, ignoring case.
    public static func matches(_ host: WRLDHost, query: String, vault: Vault) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        var fields = [host.name] + host.tags
        if let connection = host.connection { fields += [connection.address, connection.user].compactMap { $0 } }
        if let alias = host.sshConfigAlias { fields.append(alias) }
        if let group = host.groupID.flatMap(vault.group) { fields.append(group.name) }
        let text = fields.joined(separator: " ").lowercased()
        return words.allSatisfy { text.contains($0) }
    }

    /// The title row's "11 hosts · 3 keys · 2 tunnels".
    public static func summary(vault: Vault) -> String {
        var parts = [counted(vault.hosts.count, "host")]
        if !vault.keys.isEmpty { parts.append(counted(vault.keys.count, "key")) }
        let tunnels = tunnelCount(vault)
        if tunnels > 0 { parts.append(counted(tunnels, "tunnel")) }
        return parts.joined(separator: " · ")
    }

    static func tunnelCount(_ vault: Vault) -> Int { vault.hosts.reduce(0) { $0 + $1.tunnels.count } }

    static func counted(_ count: Int, _ noun: String) -> String { count == 1 ? "1 \(noun)" : "\(count) \(noun)s" }

    // MARK: - Hosts from ~/.ssh/config

    /// The names in `~/.ssh/config` WRLD doesn't hold and wasn't asked to leave be.
    public static func importable(aliases: [String], vault: Vault, dismissed: [String]) -> [String] {
        let held = Set(vault.hosts.compactMap(\.sshConfigAlias))
        var seen = held.union(dismissed)
        return aliases.filter { seen.insert($0).inserted }
    }

    /// The banner's title: "Found 12 hosts in ~/.ssh/config".
    public static func importTitle(count: Int) -> String {
        "Found \(counted(count, "host")) in ~/.ssh/config"
    }

    /// What "Add to WRLD" saves: a host for each name, which your config goes on
    /// describing; nothing in the file changes.
    public static func imported(_ aliases: [String]) -> [WRLDHost] {
        aliases.map { WRLDHost(name: $0, source: .sshConfig(alias: $0)) }
    }
}
