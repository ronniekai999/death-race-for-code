import Testing

@testable import AppCore

@Suite struct PaletteSearchTests {
    let items =
        PaletteSearch.actions + PaletteSearch.themes(current: "legends-never-die") + PaletteSearch.settingsPages

    func titles(_ query: String, kind: PaletteItem.Kind? = nil, recent: [String] = []) -> [String] {
        PaletteSearch.search(query, in: items, kind: kind, recent: recent).map(\.item.title)
    }

    @Test func wordStartsWin() {
        #expect(titles("tab").first == "New tab")
        #expect(titles("split r").first == "Split pane right")
        #expect(titles("zzzz").isEmpty)
    }

    @Test func copyAndPasteAreNotListed() {
        let actions = PaletteSearch.actions.map(\.target)
        #expect(!actions.contains(.action(.copy)))
        #expect(!actions.contains(.action(.paste)))
        #expect(!actions.contains(.action(.hearMeCalling)))
        #expect(actions.contains(.action(.splitRight)))
    }

    @Test func titlesOutrankKeywords() {
        // "light" is only a keyword of Righteous, so it comes after any title match.
        let found = PaletteSearch.search("light", in: items)
        #expect(found.contains { $0.item.title == "Righteous" })
        let righteous = found.first { $0.item.title == "Righteous" }
        #expect(righteous?.ranges == [])
    }

    @Test func keywordsMatchWordStartsOnly() {
        #expect(PaletteSearch.wordsStart("font", in: "Font"))
        #expect(PaletteSearch.wordsStart("cur sha", in: "Cursor shape"))
        #expect(!PaletteSearch.wordsStart("font", in: "before closing programs that run"))
    }

    @Test func settingsPagesAreFoundByTheirSettings() {
        #expect(titles("font", kind: .settings) == ["Appearance settings"])
        #expect(titles("bell", kind: .settings) == ["Terminal settings"])
    }

    @Test func recentPicksLeadAndBreakTies() {
        let recent = ["theme.righteous", "action.newWindow"]
        let empty = titles("", recent: recent)
        #expect(Array(empty.prefix(2)) == ["Righteous", "New window"])
        // "new" scores New tab and New window alike; the recent one goes first.
        let new = titles("new", kind: .action, recent: ["action.newWindow"])
        #expect(new.first == "New window")
    }

    @Test func kindsFilter() {
        #expect(titles("", kind: .theme).count == 8)
        #expect(titles("", kind: .theme).first == "Legends Never Die")
        let current = PaletteSearch.themes(current: "lucid-dreams").first { $0.title == "Lucid Dreams" }
        #expect(current?.detail == "Current theme")
    }

    @Test func panesShowWhereTheyAre() {
        let pane = PaletteSearch.pane(PaneID(4), in: TabID(2), title: "vim", directory: "~/code", tabNumber: 3)
        #expect(pane.id == "pane.2.4")
        #expect(pane.shortcut == "⌘3")
        #expect(PaletteSearch.search("code", in: [pane]).map(\.item.title) == ["vim"])
    }
}
