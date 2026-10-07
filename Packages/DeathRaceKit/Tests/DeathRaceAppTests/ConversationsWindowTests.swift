import AppCore
import AppKit
import ConfigKit
import ScreenProtocol
import SurfaceCore
import Testing
import VTCore

@testable import DeathRaceApp
@testable import TerminalUI

// In the window tests' suite, so they run one at a time with the windows they share the screen
// with.
extension WindowTests {

    /// What a shell with the integration installed sends for one command.
    private func transcript(_ text: String, exit: Int32 = 0, milliseconds: UInt32 = 12_400) -> String {
        "\u{1B}]133;A\u{7}$ \(text)\u{1B}]133;B\u{7}\u{1B}]633;E;\(text)\u{7}\u{1B}]133;C\u{7}"
            + "\u{1B}]133;D;\(exit);dur=\(milliseconds)\u{7}"
    }

    // MARK: - What the bar says about the last command

    /// The mockup's "Fast 12.4s", which needed the shell to report a duration and so could not
    /// exist before Phase 8.
    @Test func theBarNamesTheLastCommandAndHowLongItTook() async throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)

        session.replay.feed(transcript("swift build", milliseconds: 12_400))
        pane.surface.sessionDidUpdate()
        await eventually { controller.root.statusBar.line.leading.contains { $0.text.hasPrefix("Fast") } }
        let runs = controller.root.statusBar.line.leading
        #expect(runs.contains { $0.text == "Fast 12.4s ✓" }, "\(runs.map(\.text))")
    }

    /// A failure takes the danger colour, which `docs/DESIGN.md` allows only beside a word — and
    /// the words are there.
    @Test func aFailedCommandIsSaidInDangerInTheBar() async throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)

        session.replay.feed(transcript("make test", exit: 2, milliseconds: 4))
        pane.surface.sessionDidUpdate()
        await eventually { controller.root.statusBar.line.leading.contains { $0.style == .danger } }
        let run = try #require(controller.root.statusBar.line.leading.first { $0.style == .danger })
        #expect(run.text.contains("exited with status 2"), "\(run.text)")
    }

    /// A tap on the Fast run brings that command back, which is what `Tap.lastCommand` promises.
    ///
    /// This is the arm M4b added the enum case for and left out of the switch — a hole only
    /// macOS CI could see, because `AppCore` is portable and the switch that consumes it is not.
    @Test func tappingTheFastRunScrollsBackToThatCommand() async throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)
        let surface = pane.surface

        session.replay.feed(transcript("swift build", milliseconds: 12_400) + "\r\n")
        surface.sessionDidUpdate()
        await eventually { pane.lastCommandLine != nil }
        let line = try #require(pane.lastCommandLine)

        // Pushed off the top, so coming back to it is a real move rather than a no-op.
        session.replay.feed(String(repeating: "filler\r\n", count: surface.grid.rows + 10))
        surface.sessionDidUpdate()
        let pushed = try #require(surface.model?.mirror.viewportTopLine)
        #expect(pushed > line, "the command never left the screen, so a scroll would prove nothing")

        controller.root.statusBar.onTap?(.lastCommand)
        // Drained on each turn of the loop, standing in for the display link that drains every
        // frame: the query and the scroll both happen on a task this test has to let run.
        await eventually {
            surface.sessionDidUpdate()
            return surface.model?.mirror.viewportTopLine == line
        }
        #expect(surface.model?.mirror.viewportTopLine == line, "the command's own line is not at the top")
    }

    // MARK: - Ring Ring

    /// A command you watched finish says nothing: the pane is in the tab in front of a window
    /// you can see, which is what `isWatched` answers.
    ///
    /// The window half of that answer is stubbed, and it has to be: a test process is never the
    /// active app and no window in it ever reports `.visible` — the same fact that stops any
    /// frame being presented on CI. So both of these tests say the window is in front and vary
    /// the half that is model state, which is the half under test.
    @Test func nothingIsDeliveredForACommandInThePaneYouAreLookingAt() async throws {
        let host = TestHost()
        let notifier = FakeNotifier()
        host.notifier = notifier
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        controller.isWindowInFront = { true }
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)

        session.replay.feed(transcript("sleep 600", milliseconds: 600_000))
        pane.surface.sessionDidUpdate()
        // Long enough that a notification that was coming would have been handed over.
        await eventually(within: 1) { false }
        #expect(notifier.delivered.isEmpty, "\(notifier.delivered.map(\.notice.title))")
    }

    /// And one in a tab you are not looking at does. The second tab is the one in front, so the
    /// first tab's pane is not being watched.
    @Test func aLongCommandInATabYouAreNotWatchingIsDelivered() async throws {
        let host = TestHost()
        let notifier = FakeNotifier()
        host.notifier = notifier
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        // In front, exactly as in the test above, so the only thing that differs between the
        // two is which tab the pane is in.
        controller.isWindowInFront = { true }
        let first = try #require(controller.activePane)
        let session = try #require(first.session as? FakeSession)

        controller.newTab(nil)
        await eventually { controller.model.tabs.count == 2 }
        #expect(controller.model.activeTab?.panes.contains(first.id) == false, "the first tab is still in front")

        session.replay.feed(transcript("swift build", milliseconds: 600_000))
        first.surface.sessionDidUpdate()
        await eventually { !notifier.delivered.isEmpty }
        let delivered = try #require(notifier.delivered.first)
        #expect(delivered.notice.title == "swift build")
        #expect(delivered.notice.body == "Finished in 10m 00s", "\(delivered.notice.body)")
        #expect(delivered.paneID == UInt64(clamping: first.id.rawValue), "a tap has to find the pane it was about")
    }

    /// And one you could not have seen does, even in the tab in front: the roadmap's own case
    /// is a long command finishing while Death Race is hidden.
    @Test func aLongCommandInAWindowYouCannotSeeIsDelivered() async throws {
        let host = TestHost()
        let notifier = FakeNotifier()
        host.notifier = notifier
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        controller.isWindowInFront = { false }
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)
        #expect(controller.isWatched(pane.id) == false)

        session.replay.feed(transcript("swift build", milliseconds: 600_000))
        pane.surface.sessionDidUpdate()
        await eventually { !notifier.delivered.isEmpty }
        #expect(notifier.delivered.first?.notice.title == "swift build")
    }

    // MARK: - The pill's fill

    @Test func aProgramsProgressReachesItsTabsPill() async throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)

        let tab = try #require(controller.model.tabs.first?.id)
        func pillProgress() -> TabProgress? { controller.root.titleBar.strip.pills[tab]?.state.progress }

        session.replay.feed("\u{1B}]9;4;1;72\u{7}")
        pane.surface.sessionDidUpdate()
        await eventually { pillProgress() != nil }
        #expect(pillProgress()?.fraction == 0.72)
        #expect(pillProgress()?.failed == false)

        // Cleared means forget it, not nought: a bar at zero reads as stuck.
        session.replay.feed("\u{1B}]9;4;0\u{7}")
        pane.surface.sessionDidUpdate()
        await eventually { pillProgress() == nil }
        #expect(pillProgress() == nil)
    }

    // MARK: - Selecting a command

    /// A click on the rail selects the whole block: the command and its output, and nothing of
    /// the next one.
    @Test func aClickOnTheRailSelectsTheCommandAndItsOutput() async throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)
        let surface = pane.surface

        session.replay.feed(transcript("make") + "\r\nfirst\r\nsecond\r\n" + transcript("ls", milliseconds: 5))
        surface.sessionDidUpdate()
        await eventually { surface.model?.mirror.generation != nil }

        // Where the rail is drawn, on the first block's own line.
        #expect(surface.isOnRail(x: surface.grid.left), "the rail is not where the hit test looks")
        #expect(!surface.isOnRail(x: surface.grid.left + 40), "the whole left margin is not a rail")
        let line = try #require(surface.model?.mirror.viewportTopLine)
        surface.onRailClick?(line)

        await eventually { surface.selectionRange != nil }
        let range = try #require(surface.selectionRange)
        let text = try #require(await surface.selectedText())
        #expect(text.contains("make"), "\(text)")
        #expect(text.contains("first") && text.contains("second"), "\(text)")
        #expect(!text.contains("ls"), "it took the next command too: \(text)")
        #expect(range.start.line == line)
    }

    /// With Conversations off there is no rail, so nothing to click on.
    @Test func thereIsNoRailToClickWithConversationsOff() throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let pane = try #require(controller.activePane)
        #expect(pane.surface.isOnRail(x: pane.surface.grid.left))
        var off = Config()
        off.conversations = false
        controller.apply(off)
        #expect(!pane.surface.isOnRail(x: pane.surface.grid.left))
    }
}
