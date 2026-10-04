import ConfigKit

/// One thing Hear Me Calling finds: an action, a tab or pane, a theme, or a settings page.
public struct PaletteItem: Sendable, Equatable, Identifiable {
    /// What ⇥ cycles through.
    public enum Kind: String, CaseIterable, Sendable {
        case action = "Actions"
        case place = "Tabs and panes"
        case theme = "Themes"
        case settings = "Settings"
    }

    /// What choosing it does.
    public enum Target: Sendable, Equatable {
        case action(ActionID)
        case pane(TabID, PaneID)
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

    public var id: String {
        switch target {
        case .action(let action): "action.\(action.rawValue)"
        case .pane(let tab, let pane): "pane.\(tab.rawValue).\(pane.rawValue)"
        case .theme(let theme): "theme.\(theme)"
        case .settings(let page): "settings.\(page.rawValue)"
        }
    }

    public init(
        _ target: Target, kind: Kind, title: String, detail: String? = nil, shortcut: String? = nil,
        keywords: [String] = []
    ) {
        self.target = target
        self.kind = kind
        self.title = title
        self.detail = detail
        self.shortcut = shortcut
        self.keywords = keywords
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
            if others.contains(where: { wordsStart(query, in: $0) }) {
                scored.append((Result(item: item, ranges: []), -keywordPenalty, offset))
            }
        }
        return scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let (ra, rb) = (rank(a.result.id), rank(b.result.id))
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map { $0.result }
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

    /// A pane, for "Tabs and panes": its program and where it is.
    public static func pane(
        _ pane: PaneID, in tab: TabID, title: String, directory: String?, tabNumber: Int
    ) -> PaletteItem {
        PaletteItem(
            .pane(tab, pane), kind: .place, title: title, detail: directory,
            shortcut: tabNumber <= 9 ? "⌘\(tabNumber)" : nil, keywords: ["tab", "pane"])
    }
}
