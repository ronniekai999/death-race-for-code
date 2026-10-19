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

    // More matches than Find keeps: it keeps the newest, starts at the very last, and Return
    // and ⌘G go back from there rather than round to the oldest.
    @Test func findKeepsTheNewestMatchesAndStepsBackFromThem() async throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)
        session.replay.feed(String(repeating: "x", count: 1_100))
        pane.surface.sessionDidUpdate()
        let surface = pane.surface
        await eventually(within: 5) { surface.model?.mirror.generation != nil }
        let columns = try #require(surface.model?.mirror.columns)
        surface.showFind(nil)
        let bar = try #require(surface.findBar)
        bar.field.stringValue = "x"
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.field))
        await eventually(within: 5) { surface.findTask == nil }
        #expect(bar.count.stringValue == "1100 (newest 1000)")
        #expect(surface.searchMatches.count == 1_000)
        // The 101st x is the oldest kept; the last x is selected.
        let first = try #require(surface.searchMatches.first?.start)
        let last = try #require(surface.searchMatches.last?.start)
        #expect(Int(last.line - first.line) * columns + last.column - first.column == 999)
        #expect(first.column == 100 % columns)
        #expect(surface.searchIndex == 999)

        _ = bar.control(bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(surface.searchIndex == 998)
        surface.findNext(nil)
        #expect(surface.searchIndex == 997)
        surface.findPrevious(nil)
        #expect(surface.searchIndex == 998)
    }
}
