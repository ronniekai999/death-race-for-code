import AppCore
import AppKit
import ConfigKit
import Foundation
import SurfaceCore
import Testing

@testable import DeathRaceApp
@testable import TerminalUI

// In the window tests' suite, so they run one at a time with the windows they share the
// screen with.
extension WindowTests {
    /// A key press as AppKit hands it to the view.
    func keyDown(_ characters: String, keyCode: UInt16, in surface: TerminalSurfaceView) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: surface.window?.windowNumber ?? 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    /// A window with one tab split in two, its panes left to right.
    func splitWindow(_ host: TestHost) async throws -> (PitLaneWindowController, PaneController, PaneController) {
        let controller = makeWindow(host)
        controller.splitRight(nil)
        await eventually { controller.panes.count == 2 }
        let panes = try #require(controller.model.activeTab?.panes)
        try #require(panes.count == 2)
        return (controller, try #require(controller.panes[panes[0]]), try #require(controller.panes[panes[1]]))
    }

    @Test func armedTypingReachesEveryPaneInItsProgramsOwnModes() async throws {
        let host = TestHost()
        let (controller, left, right) = try await splitWindow(host)
        defer { controller.window?.close() }
        let leftSession = try #require(left.session as? FakeSession)
        let rightSession = try #require(right.session as? FakeSession)
        // The right pane's program asked for application cursor keys and marked pastes, as
        // vim does.
        rightSession.replay.feed("\u{1B}[?1h\u{1B}[?2004h")
        right.surface.sessionDidUpdate()
        await eventually { right.surface.model?.mirror.modes.applicationCursorKeys == true }

        // Not armed: typing stays where it's typed.
        left.surface.keyDown(with: try keyDown("\u{F700}", keyCode: 0x7E, in: left.surface))
        #expect(leftSession.replay.sent == Array("\u{1B}[A".utf8))
        #expect(rightSession.replay.sent.isEmpty)

        controller.toggleArmed(nil)
        #expect(controller.model.activeTab?.isArmed == true)
        left.surface.keyDown(with: try keyDown("\u{F700}", keyCode: 0x7E, in: left.surface))
        #expect(leftSession.replay.sent == Array("\u{1B}[A\u{1B}[A".utf8))
        #expect(rightSession.replay.sent == Array("\u{1B}OA".utf8))

        // A paste goes to both, marked only where the program asked.
        left.surface.paste(text: "make deploy")
        #expect(leftSession.replay.sent.suffix(11) == Array("make deploy".utf8))
        #expect(rightSession.replay.sent.suffix(23) == Array("\u{1B}[200~make deploy\u{1B}[201~".utf8))

        // The chrome says so: the banner over the panes, the pill, the status bar.
        let card = try #require(left.surface.superview as? PaneCardView)
        let area = try #require(card.superview as? PaneAreaView)
        #expect(area.subviews.contains { $0 is ArmedBannerView })
        area.layoutSubtreeIfNeeded()
        #expect(card.frame.minY >= Chrome.paneMargin + ArmedBannerView.height + Chrome.paneGap)
        #expect(card.isArmed)
        #expect(card.header.armed == .receiving)
        #expect(controller.root.statusBar.line.leading.first?.text == "Armed and Dangerous · 2 panes")
        let pill = try #require(controller.model.activeTabID.flatMap { controller.root.titleBar.strip.pills[$0] })
        #expect(pill.state.armed)
        #expect(pill.state.title.hasSuffix(" × 2"))

        // Left out, the right pane hears nothing more, and with one pane left armed the tab
        // disarms.
        let rightCard = try #require(right.surface.superview as? PaneCardView)
        rightCard.onToggleArmed?()
        #expect(controller.model.activeTab?.isArmed == false)
        let sent = rightSession.replay.sent
        left.surface.keyDown(with: try keyDown("\u{F700}", keyCode: 0x7E, in: left.surface))
        #expect(rightSession.replay.sent == sent)
        #expect(!area.subviews.contains { $0 is ArmedBannerView })
        area.layoutSubtreeIfNeeded()
        #expect(card.frame.minY == Chrome.paneMargin)
    }

    @Test func stopAndClosingDisarm() async throws {
        let host = TestHost()
        let (controller, left, right) = try await splitWindow(host)
        defer { controller.window?.close() }
        controller.toggleArmed(nil)
        let area = try #require(left.surface.superview?.superview as? PaneAreaView)
        let banner = try #require(area.subviews.first { $0 is ArmedBannerView } as? ArmedBannerView)
        banner.onStop?()
        #expect(controller.model.activeTab?.isArmed == false)
        #expect(controller.root.statusBar.line.leading.first?.style != .warning)

        controller.toggleArmed(nil)
        #expect(controller.model.activeTab?.isArmed == true)
        controller.focus(pane: right.id)
        controller.closePane(nil)
        await eventually { controller.panes.count == 1 }
        #expect(controller.model.activeTab?.isArmed == false)
        // A tab of one pane can't be armed.
        let item = NSMenuItem(title: "", action: #selector(PitLaneWindowController.toggleArmed(_:)), keyEquivalent: "")
        #expect(!controller.validateMenuItem(item))
    }
}
