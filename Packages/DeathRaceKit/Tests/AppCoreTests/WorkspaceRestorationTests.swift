import SessionIPC
import Testing

@testable import AppCore

@Suite struct WorkspaceRestorationTests {
    @Test func mixedSplitAxesRatiosAndFocusSurviveNewPaneIDs() throws {
        let tree = SplitTree.split(
            .stacked, ratio: 0.3, .pane(PaneID(1)),
            .split(.sideBySide, ratio: 0.7, .pane(PaneID(2)), .pane(PaneID(3))))
        let saved = try #require(tree.saved(slots: [PaneID(1): 0, PaneID(2): 1, PaneID(3): 2]))
        let restored = try #require(SplitTree.restored(saved, panes: [0: PaneID(10), 1: PaneID(20), 2: PaneID(30)]))
        #expect(
            restored
                == .split(
                    .stacked, ratio: 0.3, .pane(PaneID(10)),
                    .split(.sideBySide, ratio: 0.7, .pane(PaneID(20)), .pane(PaneID(30)))))
        let tab = TabModel(id: TabID(1), tree: restored, activePane: PaneID(20), zoomedPane: PaneID(30))
        #expect(tab.activePane == PaneID(20))
        #expect(tab.zoomedPane == PaneID(30))
        #expect(
            SplitTree.restored(saved, panes: [0: PaneID(10), 2: PaneID(30)])
                == .split(.stacked, ratio: 0.3, .pane(PaneID(10)), .pane(PaneID(30))))
    }
}
