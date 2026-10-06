import AppKit
import ConfigKit
import SessionKit
import Testing

@testable import DeathRaceApp

/// Legends Never Die, at the one place it is easiest to get wrong.
///
/// `PaneController.shutDown(leaving:)` is the only thing that decides whether a shell is hung
/// up or left running, and both of its answers matter: get the first wrong and someone's build
/// dies when they close a tab, get the second wrong and a shell they meant to be rid of runs on
/// after they quit. `FakeSession` tells the two apart by recording `close` and `detach`
/// separately, so neither path has to wait for a Mac to find out.
extension WindowTests {

    /// Closing is not quitting: a shell the daemon would happily keep is still ended, because
    /// the person shut the pane.
    @Test func closingAPaneEndsItsShellEvenWhenTheDaemonWouldKeepIt() throws {
        let controller = makeWindow(TestHost())
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)
        session.survives = true
        #expect(pane.survivesQuit)

        pane.shutDown()

        #expect(session.closed)
        #expect(!session.detached)
    }

    /// Quitting with a session the daemon is holding: stop watching, leave the shell running.
    /// This is the whole of the feature.
    @Test func quittingLeavesAKeptShellRunning() throws {
        let controller = makeWindow(TestHost())
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)
        session.survives = true

        pane.shutDown(leaving: true)

        #expect(session.detached)
        #expect(!session.closed)
    }

    /// Quitting with a session nothing is holding — the daemon was unavailable, or the setting
    /// is off — ends it, exactly as every phase before this one did.
    @Test func quittingEndsAShellNothingIsHolding() throws {
        let controller = makeWindow(TestHost())
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)
        #expect(!pane.survivesQuit)

        pane.shutDown(leaving: true)

        #expect(session.closed)
    }
}
