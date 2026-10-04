import Testing

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
        state.setQuery("lucid")
        #expect(state.previewTheme == "lucid-dreams")
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
