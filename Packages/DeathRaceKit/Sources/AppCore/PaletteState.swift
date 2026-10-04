/// What Hear Me Calling shows: the query, the kind ⇥ narrowed it to, what matches, and which
/// match is highlighted. A value: the window keeps one, and the tests drive it.
public struct PaletteState: Sendable, Equatable {
    public private(set) var items: [PaletteItem]
    /// Ids of earlier picks, most recent first.
    public private(set) var recent: [String]
    public private(set) var query = ""
    /// One kind, or everything.
    public private(set) var kind: PaletteItem.Kind?
    public private(set) var results: [PaletteSearch.Result] = []
    /// The highlighted result.
    public private(set) var selection = 0

    public init(items: [PaletteItem], recent: [String] = []) {
        self.items = items
        self.recent = recent
        refresh()
    }

    public var selected: PaletteItem? {
        results.indices.contains(selection) ? results[selection].item : nil
    }

    /// The theme to show on the window while its row is highlighted.
    public var previewTheme: String? {
        if case .theme(let id) = selected?.target { return id }
        return nil
    }

    /// What ⇥ steps through: everything, then each kind there is something of.
    public var kinds: [PaletteItem.Kind?] {
        [nil] + PaletteItem.Kind.allCases.filter { kind in items.contains { $0.kind == kind } }
    }

    /// A new query highlights its best match.
    public mutating func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        refresh()
    }

    /// ⇥ and ⇧⇥.
    public mutating func cycleKind(forward: Bool = true) {
        let kinds = kinds
        let index = kinds.firstIndex(of: kind) ?? 0
        kind = kinds[(index + (forward ? 1 : kinds.count - 1)) % kinds.count]
        refresh()
    }

    /// ↑ and ↓ go round from one end to the other; page keys stop at the ends.
    public mutating func move(by offset: Int) {
        guard !results.isEmpty else { return }
        let target = selection + offset
        if abs(offset) == 1 {
            selection = (target + results.count) % results.count
        } else {
            selection = min(max(target, 0), results.count - 1)
        }
    }

    public mutating func select(_ index: Int) {
        if results.indices.contains(index) { selection = index }
    }

    private mutating func refresh() {
        results = PaletteSearch.search(query, in: items, kind: kind, recent: recent)
        selection = 0
    }

    /// `recent` with `id` first, each id once, at most `limit` of them.
    public static func remembering(_ id: String, in recent: [String], limit: Int = 20) -> [String] {
        Array(([id] + recent.filter { $0 != id }).prefix(limit))
    }
}
