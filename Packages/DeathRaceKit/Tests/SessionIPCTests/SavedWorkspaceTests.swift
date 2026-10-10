import Testing

@testable import SessionIPC

@Suite struct SavedWorkspaceTests {
    @Test func layoutAndGeometryRoundTripAndTruncationFails() {
        let workspace = SavedWorkspace(
            tree: .split(stacked: true, ratio: 0.3, .pane(0), .pane(1)),
            activeSlot: 1, zoomedSlot: 0, selectedTab: true, focusedWindow: true,
            frame: SavedWindowFrame(x: -1200, y: 100, width: 1000, height: 800))
        let placement = SessionPlacement(window: 2, tab: 1, slot: 0, title: "shell", workspace: workspace)
        let bytes = placement.encode()
        #expect(SessionPlacement.decode(bytes) == placement)
        for length in 0..<bytes.count { #expect(SessionPlacement.decode(Array(bytes.prefix(length))) == nil) }
    }

    @Test func duplicateSlotsInvalidRatiosAndUnknownFocusAreRefused() {
        #expect(!SavedWorkspace(tree: .split(stacked: false, ratio: .nan, .pane(0), .pane(1)), activeSlot: 0).isValid)
        #expect(!SavedWorkspace(tree: .split(stacked: false, ratio: 0.5, .pane(0), .pane(0)), activeSlot: 0).isValid)
        #expect(!SavedWorkspace(tree: .pane(0), activeSlot: 1).isValid)
        #expect(
            !SavedWorkspace(tree: .pane(0), activeSlot: 0, frame: .init(x: .infinity, y: 0, width: 100, height: 100))
                .isValid)
    }
}
