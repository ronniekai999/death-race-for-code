import Foundation
import Vault

/// The WRLD sidebar (⌃⌘S) apart from its view: Legends, WRLD's groups and the hosts in
/// none, Wishing Well and Come & Go, as on the Main board, and what searching leaves.
public struct SidebarModel: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            /// A click opens a session on it in a new tab; ⌘-click beside the active pane.
            case host(HostRef)
            /// A click shows or hides its hosts.
            case group(GroupID, expanded: Bool)
            /// A click types it in, after its fields when it has any.
            case snippet(SnippetID)
            /// A click turns it on or off.
            case tunnel(TunnelID)
        }

        public var kind: Kind
        public var title: String
        /// Dimmer, at the end: "18 ms", "offline", a group's count.
        public var meta: String?
        /// A host's dot, or a tunnel's: `.connected` while it's open.
        public var dot: HostStatus.Dot?
        /// A snippet's fields, as chips after its name.
        public var fields: [String]
        /// A host shown inside its group.
        public var isIndented: Bool
        /// What VoiceOver says.
        public var accessibilityLabel: String

        public var id: String {
            switch kind {
            case .host(.vault(let id)): "host.\(id.rawValue)" + (isIndented ? ".in-group" : "")
            case .host(.sshConfig(let alias)): "host.alias.\(alias)"
            case .group(let id, _): "group.\(id.rawValue)"
            case .snippet(let id): "snippet.\(id.rawValue)"
            case .tunnel(let id): "tunnel.\(id.rawValue)"
            }
        }
    }

    public struct Section: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable {
            case legends = "Legends"
            case wrld = "WRLD"
            case wishingWell = "Wishing Well"
            case comeAndGo = "Come & Go"
        }

        public var kind: Kind
        /// All it holds, searched or not, as the board's eyebrows count.
        public var count: Int
        public var rows: [Row]

        public var title: String { kind.rawValue }
        public var id: Kind { kind }
    }

    /// What the sidebar is drawn from.
    public struct Inputs: Sendable {
        public var vault: Vault
        public var state: WRLDState
        /// Hosts with a connection open, by `WRLDState.key(for:)`.
        public var connected: Set<String>
        public var openTunnels: Set<TunnelID>
        public var expandedGroups: Set<GroupID>
        public var query: String
        public var now: Date
        public var calendar: Calendar

        public init(
            vault: Vault, state: WRLDState = WRLDState(), connected: Set<String> = [], openTunnels: Set<TunnelID> = [],
            expandedGroups: Set<GroupID> = [], query: String = "", now: Date = Date(), calendar: Calendar = .current
        ) {
            self.vault = vault
            self.state = state
            self.connected = connected
            self.openTunnels = openTunnels
            self.expandedGroups = expandedGroups
            self.query = query
            self.now = now
            self.calendar = calendar
        }
    }

    public var sections: [Section]

    /// Searching: every match shows, out of its group, and empty sections go.
    public var isSearching: Bool

    public init(_ inputs: Inputs) {
        let vault = inputs.vault
        let query = inputs.query.lowercased().split(whereSeparator: \.isWhitespace)
        let searching = !query.isEmpty
        isSearching = searching
        func found(_ fields: [String]) -> Bool {
            let text = fields.joined(separator: " ").lowercased()
            return query.allSatisfy { text.contains($0) }
        }
        func hostRow(_ host: WRLDHost, indented: Bool = false) -> Row {
            let ref = HostRef.vault(host.id)
            let status = HostStatus(
                facts: inputs.state.facts(ref), isConnected: inputs.connected.contains(WRLDState.key(for: ref)),
                now: inputs.now, calendar: inputs.calendar)
            let said = [host.name, status.dot == .connected ? "connected" : status.meta].compactMap { $0 }
            return Row(
                kind: .host(ref), title: host.name, meta: status.meta, dot: status.dot, fields: [],
                isIndented: indented, accessibilityLabel: said.joined(separator: ", "))
        }
        let hosts = vault.hosts.filter { WRLDBoard.matches($0, query: inputs.query, vault: vault) }

        var sections: [Section] = []
        let legends = hosts.filter(\.isLegend)
        sections.append(
            Section(kind: .legends, count: vault.hosts.filter(\.isLegend).count, rows: legends.map { hostRow($0) }))

        var wrld: [Row] = []
        if searching {
            wrld = hosts.filter { !$0.isLegend }.map { hostRow($0) }
        } else {
            for group in vault.groups {
                let members = vault.hosts.filter { $0.groupID == group.id }
                let expanded = inputs.expandedGroups.contains(group.id)
                wrld.append(
                    Row(
                        kind: .group(group.id, expanded: expanded), title: group.name, meta: String(members.count),
                        dot: nil, fields: [], isIndented: false,
                        accessibilityLabel: "\(group.name), \(WRLDBoard.counted(members.count, "host"))"))
                if expanded { wrld += members.map { hostRow($0, indented: true) } }
            }
            let loose = vault.hosts.filter { host in !host.isLegend && host.groupID.flatMap(vault.group) == nil }
            wrld += loose.map { hostRow($0) }
        }
        sections.append(Section(kind: .wrld, count: vault.hosts.count, rows: wrld))

        let snippets = vault.snippets.filter { found([$0.name, $0.text]) }
        sections.append(
            Section(
                kind: .wishingWell, count: vault.snippets.count,
                rows: snippets.map { snippet in
                    let fields = snippet.template.placeholders.map(\.name)
                    return Row(
                        kind: .snippet(snippet.id), title: snippet.name, meta: nil, dot: nil, fields: fields,
                        isIndented: false,
                        accessibilityLabel: fields.isEmpty
                            ? snippet.name : "\(snippet.name), asks for \(fields.joined(separator: ", "))")
                }))

        let tunnels = vault.hosts.flatMap { host in
            host.tunnels.filter { found([host.name, $0.spec.summary(host: host.name)]) }.map { (host, $0) }
        }
        sections.append(
            Section(
                kind: .comeAndGo, count: WRLDBoard.tunnelCount(vault),
                rows: tunnels.map { host, tunnel in
                    let open = inputs.openTunnels.contains(tunnel.id)
                    return Row(
                        kind: .tunnel(tunnel.id), title: Self.shortName(tunnel.spec), meta: nil,
                        dot: open ? .connected : .unknown, fields: [], isIndented: false,
                        accessibilityLabel: tunnel.spec.summary(host: host.name) + (open ? ", open" : ", off"))
                }))

        // Legends, Wishing Well and Come & Go show once they have something; WRLD always
        // does, to say how to add a host. Searching shows only what it found.
        self.sections = sections.filter { section in
            if searching { return !section.rows.isEmpty }
            return section.kind == .wrld || section.count > 0
        }
    }

    /// A tunnel in a few characters: "5432 → db", "SOCKS 1080", "remote 8080 → localhost".
    public static func shortName(_ spec: TunnelSpec) -> String {
        switch spec.kind {
        case .local: "\(spec.listenText) → \(spec.target?.host ?? "?")"
        case .remote: "remote \(spec.listenText) → \(spec.target?.host ?? "?")"
        case .dynamic: "SOCKS \(spec.listenText)"
        }
    }

    /// What the sidebar says when WRLD has no hosts.
    public static let emptyHint = "Add a host to WRLD to connect with one click."
}
