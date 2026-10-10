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
        await eventually(within: 5) { surface.model?.mirror.generation != nil }
        _ = try #require(surface.model?.mirror.generation)
        surface.showFind(nil)
        let bar = try #require(surface.findBar)
        bar.field.stringValue = String(repeating: "🎧", count: 513)
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.field))
        #expect(bar.count.stringValue == "Search is too long")
        #expect(surface.findTask == nil)
        bar.field.stringValue = "needle"
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.field))
        await eventually(within: 5) { surface.findTask == nil }
        #expect(bar.count.stringValue == "1")
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
        await eventually(within: 5) { surface.model?.mirror.generation != nil }
        _ = try #require(surface.model?.mirror.generation)
        surface.showFind(nil)
        let bar = try #require(surface.findBar)
        bar.field.stringValue = "x"
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.field))
        await eventually(within: 5) { surface.findTask == nil }
        #expect(bar.count.stringValue == "600")
        #expect(surface.searchMatches.count == 600)
    }
}
