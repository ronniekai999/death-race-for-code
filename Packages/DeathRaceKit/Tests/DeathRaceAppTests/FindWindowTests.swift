import AppKit
import Testing

@testable import DeathRaceApp
@testable import TerminalUI

extension WindowTests {
    @Test func findRejectsLongInputAndRecoversWhenItIsShortened() async throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)
        session.replay.feed("needle")
        pane.surface.sessionDidUpdate()
        let surface = pane.surface
        surface.searchText = String(repeating: "🎧", count: 513)
        surface.showFind(nil)
        #expect(surface.findBar?.count.stringValue == "Search is too long")
        #expect(surface.findTask == nil)
        surface.searchText = "needle"
        surface.refreshFind()
        await eventually { surface.findTask == nil }
        #expect(surface.findBar?.count.stringValue == "1")
        #expect(surface.searchMatches.count == 1)
    }

    @Test func findCountsAllPagesWithoutClaimingMoreMatchesRemain() async throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)
        session.replay.feed(String(repeating: "x", count: 600))
        pane.surface.sessionDidUpdate()
        let surface = pane.surface
        surface.searchText = "x"
        surface.showFind(nil)
        await eventually { surface.findTask == nil }
        #expect(surface.findBar?.count.stringValue == "600")
        #expect(surface.searchMatches.count == 600)
    }
}
