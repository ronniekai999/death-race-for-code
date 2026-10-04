import AppCore
import AppKit
import ConfigKit
import Foundation
import ScreenProtocol
import SurfaceCore
import TerminalUI
import Testing
import Vault

@testable import DeathRaceApp

// In the window tests' suite, so they run one at a time with the windows they share the
// screen with.
extension WindowTests {
    private func wishingWellWindow(_ snippets: [Snippet] = []) -> (FakeConnections, PitLaneWindowController) {
        let host = TestHost()
        let connections = FakeConnections()
        for snippet in snippets { _ = connections.save(snippet) }
        host.connections = connections
        return (connections, makeWindow(host))
    }

    @Test func aSnippetFromHearMeCallingIsTypedInAndCommandReturnRunsIt() throws {
        let restart = Snippet(
            id: SnippetID(rawValue: "s1"), name: "restart caddy", text: "sudo systemctl restart caddy")
        let (_, controller) = wishingWellWindow([restart])
        defer { controller.window?.close() }
        let session = try #require(controller.activePane?.session as? FakeSession)

        controller.showHearMeCalling(nil)
        let overlay = try #require(controller.hearMeCalling)
        type("restart caddy", into: overlay)
        let selected = try #require(overlay.model.state.selected)
        #expect(selected.target == .snippet(restart.id))
        #expect(selected.alternate == "Run")
        // ↵ types it in, without Return, so it can be looked over first.
        press(#selector(NSResponder.insertNewline(_:)), in: overlay)
        #expect(controller.hearMeCalling == nil)
        #expect(session.replay.sent == Array("sudo systemctl restart caddy".utf8))

        // ⌘↵ runs it.
        controller.showHearMeCalling(nil)
        let again = try #require(controller.hearMeCalling)
        type("restart caddy", into: again)
        again.model.chooseAlternate()
        #expect(session.replay.sent.suffix(29) == Array("sudo systemctl restart caddy\r".utf8))
    }

    @Test func aSnippetGoesToEveryArmedPane() async throws {
        let host = TestHost()
        host.connections = FakeConnections()
        let (controller, left, right) = try await splitWindow(host)
        defer { controller.window?.close() }
        let leftSession = try #require(left.session as? FakeSession)
        let rightSession = try #require(right.session as? FakeSession)

        controller.typeSnippet("uptime", run: true)
        // Not armed: only the active pane, the right one.
        #expect(leftSession.replay.sent.isEmpty)
        #expect(rightSession.replay.sent == Array("uptime\r".utf8))

        controller.toggleArmed(nil)
        controller.typeSnippet("w", run: true)
        #expect(leftSession.replay.sent == Array("w\r".utf8))
        #expect(rightSession.replay.sent == Array("uptime\rw\r".utf8))
    }

    @Test func aHostsOnConnectSnippetIsTypedAsItsSessionStarts() async throws {
        let (connections, controller) = wishingWellWindow()
        defer { controller.window?.close() }
        connections.onConnect = "tmux new -A -s main"
        connections.results = [.ready(FakeConnections.session)]

        controller.open(.sshConfig(alias: "nas-999"), beside: false)
        await eventually { controller.activePane?.launch == .connection(.sshConfig(alias: "nas-999")) }
        await eventually { (controller.activePane?.session as? FakeSession)?.replay.sent.isEmpty == false }
        let session = try #require(controller.activePane?.session as? FakeSession)
        #expect(session.replay.sent == Array("tmux new -A -s main\r".utf8))
    }

    @Test func savingASelectionWaitsForOne() async throws {
        let (_, controller) = wishingWellWindow()
        defer { controller.window?.close() }
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)
        let save = NSMenuItem(
            title: "", action: #selector(PitLaneWindowController.saveSelectionToWishingWell(_:)), keyEquivalent: "")
        #expect(!controller.validateMenuItem(save))

        session.replay.feed("make test")
        pane.surface.sessionDidUpdate()
        await eventually { pane.surface.model?.mirror.allLines != nil }
        pane.surface.selectAll(nil)
        #expect(controller.validateMenuItem(save))
        #expect(await pane.surface.selectedText()?.hasPrefix("make test") == true)

        // The context menu offers it too, for the pane it was opened on.
        let menu = try #require(
            pane.surface.menu(for: try mouseEvent(.rightMouseDown, on: pane.surface, column: 0, row: 0)))
        let item = try #require(menu.items.first { $0.action == save.action })
        #expect(item.title == "Save Selection to Wishing Well…")
        #expect(item.representedObject as? Int == pane.id.rawValue)
    }
}
