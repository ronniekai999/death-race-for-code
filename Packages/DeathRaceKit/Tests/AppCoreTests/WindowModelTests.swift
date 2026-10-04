import Testing

@testable import AppCore

@Suite struct WindowModelTests {
    let rect = LayoutRect(x: 0, y: 0, width: 1000, height: 600)

    /// Tabs 1…n, each with pane 1…n.
    func window(tabs: Int) -> WindowModel {
        var model = WindowModel(tab: TabModel(id: TabID(1), pane: PaneID(1)))
        for n in 2...max(tabs, 2) where n <= tabs { model.newTab(TabID(n), pane: PaneID(n)) }
        return model
    }

    @Test func newTabsOpenAfterTheActiveOne() {
        var model = window(tabs: 3)
        model.selectTab(TabID(1))
        model.newTab(TabID(9), pane: PaneID(9))
        #expect(model.tabs.map(\.id.rawValue) == [1, 9, 2, 3])
        #expect(model.activeTabID == TabID(9))
        #expect(model.activePane == PaneID(9))
    }

    @Test func numberKeysSelectTabsAndNineTheLast() {
        var model = window(tabs: 5)
        do { let result = model.selectTab(number: 2); #expect(result) }
        #expect(model.activeTabID == TabID(2))
        do { let result = model.selectTab(number: 9); #expect(result) }
        #expect(model.activeTabID == TabID(5))
        do { let result = model.selectTab(number: 7); #expect(!result) }
        #expect(model.activeTabID == TabID(5))
        do { let result = model.selectTab(number: 0); #expect(!result) }
    }

    @Test func nextAndPreviousWrapAround() {
        var model = window(tabs: 3)
        model.selectNextTab()
        #expect(model.activeTabID == TabID(1))
        model.selectPreviousTab()
        #expect(model.activeTabID == TabID(3))
    }

    @Test func closingATabSelectsTheOneToItsRight() {
        var model = window(tabs: 3)
        model.selectTab(TabID(2))
        model.removeTab(TabID(2))
        #expect(model.activeTabID == TabID(3))
        model.removeTab(TabID(3))
        #expect(model.activeTabID == TabID(1))
        model.removeTab(TabID(1))
        #expect(model.activeTabID == nil)
    }

    @Test func movingATabKeepsItActive() {
        var model = window(tabs: 3)
        model.moveTab(from: 2, to: 0)
        #expect(model.tabs.map(\.id.rawValue) == [3, 1, 2])
        #expect(model.activeTabID == TabID(3))
    }

    @Test func closingPanesThenTabsThenTheWindow() {
        var model = WindowModel(tab: TabModel(id: TabID(1), pane: PaneID(1)))
        model.split(.sideBySide, newPane: PaneID(2))
        model.split(.stacked, newPane: PaneID(3))
        #expect(model.activePane == PaneID(3))
        model.activate(PaneID(1))
        model.activate(PaneID(3))
        // Closing 3 hands the keys to the pane active before it, 1, not to its neighbor 2.
        do { let result = model.closePane(PaneID(3)); #expect(result == .pane) }
        #expect(model.activePane == PaneID(1))
        do { let result = model.closePane(PaneID(1)); #expect(result == .pane) }
        #expect(model.activePane == PaneID(2))
        model.newTab(TabID(2), pane: PaneID(4))
        do { let result = model.closePane(PaneID(4)); #expect(result == .tab) }
        #expect(model.activeTabID == TabID(1))
        do { let result = model.closePane(PaneID(2)); #expect(result == .window) }
        #expect(model.tabs.isEmpty)
        do { let result = model.closePane(PaneID(2)); #expect(result == nil) }
    }

    @Test func arrowsMoveTheKeysToTheNeighbor() {
        var model = WindowModel(tab: TabModel(id: TabID(1), pane: PaneID(1)))
        model.split(.sideBySide, newPane: PaneID(2))
        do { let result = model.focusNeighbor(.left, in: rect, gap: 12); #expect(result) }
        #expect(model.activePane == PaneID(1))
        do { let result = model.focusNeighbor(.left, in: rect, gap: 12); #expect(!result) }
        do { let result = model.focusNeighbor(.right, in: rect, gap: 12); #expect(result) }
        #expect(model.activePane == PaneID(2))
    }

    @Test func panesByNumberAndInTurn() {
        var model = WindowModel(tab: TabModel(id: TabID(1), pane: PaneID(1)))
        model.split(.sideBySide, newPane: PaneID(2))
        model.split(.stacked, newPane: PaneID(3))
        do { let result = model.focusPane(number: 1); #expect(result) }
        #expect(model.activePane == PaneID(1))
        do { let result = model.focusPane(number: 9); #expect(result) }
        #expect(model.activePane == PaneID(3))
        do { let result = model.focusPane(number: 4); #expect(!result) }
        model.focusNextPane()
        #expect(model.activePane == PaneID(1))
        model.focusPreviousPane()
        #expect(model.activePane == PaneID(3))
    }

    @Test func zoomShowsOnePaneAndFollowsFocus() {
        var model = WindowModel(tab: TabModel(id: TabID(1), pane: PaneID(1)))
        model.toggleZoom()
        #expect(model.activeTab?.zoomedPane == nil)  // one pane: nothing to zoom
        model.split(.sideBySide, newPane: PaneID(2))
        model.toggleZoom()
        #expect(model.activeTab?.visiblePanes == [PaneID(2)])
        // Arrows don't reach hidden panes; ⌘] does, and the zoom follows.
        do { let result = model.focusNeighbor(.left, in: rect, gap: 12); #expect(!result) }
        model.focusNextPane()
        #expect(model.activeTab?.visiblePanes == [PaneID(1)])
        // Splitting or closing the zoomed pane shows them all again.
        model.split(.stacked, newPane: PaneID(3))
        #expect(model.activeTab?.zoomedPane == nil)
        model.toggleZoom()
        model.closePane(PaneID(3))
        #expect(model.activeTab?.zoomedPane == nil)
    }

    @Test func aTabMovesBetweenWindowsWhole() {
        var first = window(tabs: 2)
        first.selectTab(TabID(1))
        first.split(.sideBySide, newPane: PaneID(7))
        let moving = first.removeTab(TabID(1))!
        var second = WindowModel()
        second.insert(moving)
        #expect(second.activeTab == moving)
        #expect(second.activePane == PaneID(7))
        #expect(first.tabs.map(\.id) == [TabID(2)])
    }

    @Test func aTreeFromElsewhereMustHoldTheSamePanes() {
        var model = WindowModel(tab: TabModel(id: TabID(1), pane: PaneID(1)))
        model.split(.sideBySide, newPane: PaneID(2))
        let wider = model.activeTab!.tree.movingDivider(
            at: [], to: 700, in: rect, gap: 12, minimum: (width: 100, height: 60))
        model.setTree(wider, of: TabID(1))
        #expect(model.activeTab?.tree == wider)
        model.setTree(.pane(PaneID(1)), of: TabID(1))
        #expect(model.activeTab?.tree == wider)
    }
}
