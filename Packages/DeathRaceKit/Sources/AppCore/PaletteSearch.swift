import ConfigKit
import Foundation
import Vault

/// One thing Hear Me Calling finds: an action, a tab or pane, a host, a theme, or a settings
/// page.
public struct PaletteItem: Sendable, Equatable, Identifiable {
    /// What ⇥ cycles through.
    public enum Kind: String, CaseIterable, Sendable {
        case action = "Actions"
        case place = "Tabs and panes"
        case host = "Hosts"
        case theme = "Themes"
        case settings = "Settings"
    }

    /// What choosing it does.
    public enum Target: Sendable, Equatable {
        case action(ActionID)
        case pane(TabID, PaneID)
        /// ↵ opens it in a new tab, ⌘↵ beside the current pane.
        case host(HostRef)
        case theme(String)
        case settings(SettingsCatalog.Page)
    }

    public var target: Target
    public var kind: Kind
    public var title: String
    /// Dimmer, after the title: where a pane is, what a theme is.
    public var detail: String?
    /// The shortcut, as macOS writes it ("⇧⌘D").
    public var shortcut: String?
    /// Other words that find it.
    public var keywords: [String]
    /// What ⌘↵ does with it, for the footer; nil when ⌘↵ does nothing.
    public var alternate: String?

    public var id: String {
        switch target {
        case .action(let action): "action.\(action.rawValue)"
        case .pane(let tab, let pane): "pane.\(tab.rawValue).\(pane.rawValue)"
        case .host(.vault(let host)): "host.\(host.rawValue)"
        case .host(.sshConfig(let alias)): "host.alias.\(alias)"
        case .theme(let theme): "theme.\(theme)"
        case .settings(let page): "settings.\(page.rawValue)"
        }
    }

    public init(
        _ target: Target, kind: Kind, title: String, detail: String? = nil, shortcut: String? = nil,
        keywords: [String] = [], alternate: String? = nil
    ) {
        self.target = target
        self.kind = kind
        self.title = title
        self.detail = detail
        self.shortcut = shortcut
        self.keywords = keywords
        self.alternate = alternate
    }
}

/// How Hear Me Calling ranks what it finds.
public enum PaletteSearch {
    public struct Result: Sendable, Equatable, Identifiable {
        public var item: PaletteItem
        /// The title's matched characters, as character offsets, for highlighting.
        public var ranges: [Range<Int>]

        public var id: String { item.id }
    }

    /// A match in the keywords or the detail ranks below any match in a title.
    static let keywordPenalty = 40

    /// `items` that match `query`, best first; ties go to the more recently chosen (`recent`
    /// holds ids, most recent first), then to the order given. An empty query lists the
    /// recent ones first, then the rest in order. `kind` keeps only that kind.
    public static func search(
        _ query: String, in items: [PaletteItem], kind: PaletteItem.Kind? = nil, recent: [String] = []
    ) -> [Result] {
        let pool = items.enumerated().filter { kind == nil || $0.element.kind == kind }
        let recency = Dictionary(recent.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        func rank(_ id: String) -> Int { recency[id] ?? Int.max }

        guard query.contains(where: { !$0.isWhitespace }) else {
            return pool.sorted { a, b in
                let (ra, rb) = (rank(a.element.id), rank(b.element.id))
                return ra != rb ? ra < rb : a.offset < b.offset
            }.map { Result(item: $0.element, ranges: []) }
        }
        var scored: [(result: Result, score: Int, offset: Int)] = []
        for (offset, item) in pool {
            if let match = FuzzyMatcher.match(query, in: item.title) {
                scored.append((Result(item: item, ranges: match.ranges), match.score, offset))
                continue
            }
            let others = item.keywords + [item.detail].compactMap { $0 }
            if others.contains(where: { wordsStart(query, in: $0) || starts(query, $0) }) {
                scored.append((Result(item: item, ranges: []), -keywordPenalty, offset))
            }
        }
        return scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let (ra, rb) = (rank(a.result.id), rank(b.result.id))
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map { $0.result }
    }

    /// Whether `text` starts with all of `query`: "10.0.4" finds a host at 10.0.4.21, whose
    /// words would split at the dots.
    static func starts(_ query: String, _ text: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        return !trimmed.isEmpty && text.lowercased().hasPrefix(trimmed)
    }

    /// Whether every word of `query` starts a word of `text`: "dark" finds a dark theme and
    /// "font" the page with Font on it. Letters scattered through a long keyword do not
    /// count, as they would in a title.
    static func wordsStart(_ query: String, in text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        return query.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { part in
            words.contains { $0.hasPrefix(part) }
        }
    }

    // MARK: - What there is to find

    /// Every action the menus have, but those that need what the palette takes (Copy, Paste).
    public static var actions: [PaletteItem] {
        ActionCatalog.all.filter(\.inPalette).map { action in
            PaletteItem(
                .action(action.id), kind: .action, title: action.paletteTitle, detail: action.group.rawValue,
                shortcut: action.shortcut?.description, keywords: action.keywords)
        }
    }

    /// WRLD's hosts, Legends first, then the names in `~/.ssh/config` WRLD doesn't hold.
    /// Found by their address, user, group and tags too.
    public static func hosts(vault: Vault, aliases: [String]) -> [PaletteItem] {
        let held = Set(
            vault.hosts.compactMap { host -> String? in
                if case .sshConfig(let alias) = host.source { return alias }
                return nil
            })
        let ordered = vault.hosts.filter(\.isLegend) + vault.hosts.filter { !$0.isLegend }
        let saved = ordered.map { host in
            let group = host.groupID.flatMap { id in vault.groups.first { $0.id == id }?.name }
            var keywords = host.tags + [group].compactMap { $0 } + ["ssh", "connect"]
            let detail: String
            switch host.source {
            case .wrld(let connection):
                let place = (connection.user.map { $0 + "@" } ?? "") + connection.address
                keywords += [connection.address, connection.user].compactMap { $0 }
                detail = host.isLegend ? "Legend · " + place : place
            case .sshConfig:
                detail = host.isLegend ? "Legend · ~/.ssh/config" : "~/.ssh/config"
            }
            return PaletteItem(
                .host(.vault(host.id)), kind: .host, title: host.name, detail: detail, keywords: keywords,
                alternate: "Open Beside")
        }
        var seen = held
        let found = aliases.filter { seen.insert($0).inserted }.map { alias in
            PaletteItem(
                .host(.sshConfig(alias: alias)), kind: .host, title: alias, detail: "~/.ssh/config",
                keywords: ["ssh", "connect"], alternate: "Open Beside")
        }
        return saved + found
    }

    /// The themes; the one in use says so.
    public static func themes(current: String?) -> [PaletteItem] {
        ThemeCatalog.all.map { theme in
            PaletteItem(
                .theme(theme.id), kind: .theme, title: theme.name,
                detail: theme.id == current ? "Current theme" : theme.isLight ? "Light theme" : "Dark theme",
                keywords: ["theme", theme.isLight ? "light" : "dark", theme.id])
        }
    }

    /// The Settings window's pages, found by the settings on them too ("font" finds
    /// Appearance).
    public static var settingsPages: [PaletteItem] {
        SettingsCatalog.Page.allCases.map { page in
            let labels = SettingsCatalog.groups(on: page).flatMap(\.settings).map(\.label)
            return PaletteItem(
                .settings(page), kind: .settings, title: "\(page.rawValue) settings", detail: "Settings",
                keywords: ["settings", "preferences"] + labels)
        }
    }

    /// A pane, for "Tabs and panes": its tab's label, where the tab is ("Tab 2"), and found
    /// by its folder too.
    public static func pane(
        _ pane: PaneID, in tab: TabID, title: String, directory: String?, place: String, shortcut: String?
    ) -> PaletteItem {
        PaletteItem(
            .pane(tab, pane), kind: .place, title: title, detail: place, shortcut: shortcut,
            keywords: ["tab", "pane"] + [directory].compactMap { $0 })
    }

    /// The ⌘ key that shows the tab at `index` of `count`: ⌘1 to ⌘8, and ⌘9 for the last.
    public static func tabShortcut(index: Int, count: Int) -> String? {
        if index == count - 1, index >= 8 { return "⌘9" }
        return index < 8 ? "⌘\(index + 1)" : nil
    }
}
