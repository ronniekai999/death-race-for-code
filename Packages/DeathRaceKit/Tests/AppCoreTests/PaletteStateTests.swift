import Testing
import Vault

@testable import AppCore

struct PaletteStateTests {
    let items =
        PaletteSearch.actions + PaletteSearch.themes(current: "legends-never-die") + PaletteSearch.settingsPages

    @Test func aQueryHighlightsItsBestMatch() {
        var state = PaletteState(items: items)
        state.move(by: 3)
        state.setQuery("split right")
        #expect(state.selection == 0)
        #expect(state.selected?.title == "Split pane right")
    }

    @Test func tabStepsThroughTheKindsThereAre() {
        var state = PaletteState(items: items)
        // No panes among these items, so "Tabs and panes" is skipped.
        #expect(state.kinds == [nil, .action, .theme, .settings])
        state.cycleKind()
        #expect(state.kind == .action)
        #expect(state.results.allSatisfy { $0.item.kind == .action })
        state.cycleKind()
        state.cycleKind()
        #expect(state.kind == .settings)
        state.cycleKind()
        #expect(state.kind == nil)
        state.cycleKind(forward: false)
        #expect(state.kind == .settings)
    }

    @Test func arrowsGoRoundAndPagesStop() {
        var state = PaletteState(items: items)
        state.cycleKind()
        state.cycleKind()
        #expect(state.results.count == 8)
        state.move(by: -1)
        #expect(state.selection == 7)
        state.move(by: 1)
        #expect(state.selection == 0)
        state.move(by: 8)
        #expect(state.selection == 7)
        state.move(by: -8)
        #expect(state.selection == 0)
    }

    @Test func aHighlightedThemeIsPreviewed() {
        var state = PaletteState(items: items)
        // "righteous" names only the theme; "lucid" now also matches the Lucid Dreams action.
        state.setQuery("righteous")
        #expect(state.previewTheme == "righteous")
        state.setQuery("new tab")
        #expect(state.previewTheme == nil)
    }

    @Test func nothingMatchesNothingIsSelected() {
        var state = PaletteState(items: items)
        state.setQuery("zzzzqqq")
        #expect(state.results.isEmpty)
        #expect(state.selected == nil)
        state.move(by: 1)
        #expect(state.selection == 0)
    }

    /// Typed as Termius's field takes it, it is the first row, above anything it happens to
    /// match, and ↵ connects to it.
    @Test func anSshCommandIsQuickConnectFirst() throws {
        var state = PaletteState(items: items)
        state.setQuery("ssh wrldjump@127.0.0.1 -p 2222")
        let row = try #require(state.selected)
        #expect(row.id == "quick-connect")
        #expect(row.title == "Connect to wrldjump@127.0.0.1:2222")
        #expect(row.kind == .host)
        #expect(row.alternate == "Open Beside")
        guard case .quickConnect(.success(let draft)) = row.target else {
            Issue.record("\(row.target) isn't a quick connect")
            return
        }
        #expect(try draft.host().connection == Connection(address: "127.0.0.1", user: "wrldjump", port: 2222))
        #expect(state.results.filter { $0.id == "quick-connect" }.count == 1)

        // Narrowed to another kind, it isn't offered.
        state.cycleKind()
        #expect(state.kind == .action)
        #expect(!state.results.contains { $0.id == "quick-connect" })
    }

    /// What quick connect can't take is the row's title, and the row has nothing for ⌘↵.
    @Test func aQuickConnectItCantTakeSaysWhy() throws {
        var state = PaletteState(items: items)
        state.setQuery("ssh -L 8080:localhost:80 db")
        let row = try #require(state.selected)
        #expect(row.id == "quick-connect")
        #expect(row.title == QuickConnect.Problem.option("-L").sentence)
        #expect(row.alternate == nil)
        #expect(row.target == .quickConnect(.failure(.option("-L"))))
        // A search that isn't an ssh command has no such row.
        state.setQuery("split right")
        #expect(!state.results.contains { $0.id == "quick-connect" })
    }

    @Test func recentPicksComeFirstOnceEach() {
        var recent = PaletteState.remembering("theme.righteous", in: [])
        recent = PaletteState.remembering("action.newTab", in: recent)
        recent = PaletteState.remembering("theme.righteous", in: recent)
        #expect(recent == ["theme.righteous", "action.newTab"])
        #expect(PaletteState.remembering("x", in: (0..<30).map(String.init), limit: 20).count == 20)
        let state = PaletteState(items: items, recent: recent)
        #expect(state.selected?.id == "theme.righteous")
    }
}
