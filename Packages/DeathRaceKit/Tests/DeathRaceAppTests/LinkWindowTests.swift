import AppKit
import ConfigKit
import Foundation
import SurfaceCore
import TerminalUI
import Testing

@testable import DeathRaceApp

// In the window tests' suite, so they run one at a time with the windows they share the
// screen with.
extension WindowTests {
    /// A mouse event at the middle of a cell of `surface`.
    func mouseEvent(
        _ type: NSEvent.EventType, on surface: TerminalSurfaceView, column: Int, row: Int, command: Bool = false
    ) throws -> NSEvent {
        let rect = CellGeometry(cell: surface.cell, layout: surface.grid).rect(column: column, row: row)
        let point = surface.convert(NSPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2), to: nil)
        return try #require(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: command ? [.command] : [], timestamp: 0,
                windowNumber: surface.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1))
    }

    @Test func aCommandClickFollowsALinkAndTheMenuOffersIt() async throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)
        let surface = pane.surface
        // What the app would open, recorded instead: no test opens a browser.
        var opened: [LinkHit] = []
        surface.onOpenLink = { opened.append($0) }
        #expect(surface.frameRatePolicy == FrameRatePolicy(followsLowPowerMode: true, capsOutput: true))

        session.replay.feed("ab\u{1B}]8;;https://wrld.example/999\u{1B}\\link\u{1B}]8;;\u{1B}\\ see https://b.example")
        surface.sessionDidUpdate()
        await eventually(within: 5) { surface.model?.mirror.link(column: 2, row: 0) != nil }

        surface.mouseDown(with: try mouseEvent(.leftMouseDown, on: surface, column: 3, row: 0, command: true))
        surface.mouseUp(with: try mouseEvent(.leftMouseUp, on: surface, column: 4, row: 0, command: true))
        #expect(opened.map(\.uri) == ["https://wrld.example/999"])
        #expect(opened.first?.text == "link")
        #expect(opened.first?.isExplicit == true)

        // A URL in the text works the same way.
        surface.mouseDown(with: try mouseEvent(.leftMouseDown, on: surface, column: 14, row: 0, command: true))
        surface.mouseUp(with: try mouseEvent(.leftMouseUp, on: surface, column: 14, row: 0, command: true))
        #expect(opened.last?.uri == "https://b.example")

        // Let go somewhere else, and nothing is followed.
        surface.mouseDown(with: try mouseEvent(.leftMouseDown, on: surface, column: 3, row: 0, command: true))
        surface.mouseUp(with: try mouseEvent(.leftMouseUp, on: surface, column: 0, row: 0, command: true))
        #expect(opened.count == 2)

        // The context menu over a link offers it; over plain text it does not.
        let menu = try #require(surface.menu(for: try mouseEvent(.rightMouseDown, on: surface, column: 3, row: 0)))
        #expect(Array(menu.items.map(\.title).prefix(2)) == ["Open Link", "Copy Link"])
        let open = try #require(menu.items.first)
        NSApp.sendAction(try #require(open.action), to: open.target, from: open)
        #expect(opened.count == 3)
        let plain = try #require(surface.menu(for: try mouseEvent(.rightMouseDown, on: surface, column: 0, row: 0)))
        #expect(!plain.items.contains { $0.title == "Open Link" })
    }
}
