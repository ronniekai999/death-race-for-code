import Testing

@testable import AppCore

/// Whether a finished command is worth interrupting you for. A notification is cheap to send
/// and expensive to get wrong, so the rules are a table rather than a judgement made once.
@Suite("Ring Ring") struct RingRingTests {

    private func finished(
        _ command: String = "swift build", milliseconds: UInt32? = 60_000, exitCode: Int32? = 0,
        watched: Bool = false, programNotified: Bool = false
    ) -> RingRing.Finished {
        RingRing.Finished(
            command: command, milliseconds: milliseconds, exitCode: exitCode, wasWatched: watched,
            programNotified: programNotified)
    }

    private let threshold: UInt32 = 30

    // MARK: - When it stays quiet

    /// The roadmap's own wording: it does not fire for a command you watched finish.
    @Test func aCommandYouWatchedFinishSaysNothing() {
        #expect(RingRing.notice(for: finished(watched: true), thresholdSeconds: threshold) == nil)
        // Even a failure, because you saw it fail.
        #expect(
            RingRing.notice(for: finished(exitCode: 1, watched: true), thresholdSeconds: threshold) == nil)
    }

    /// A program that sent its own `OSC 9` has said more than we could.
    @Test func aProgramThatNotifiedItselfIsNotSecondGuessed() {
        #expect(RingRing.notice(for: finished(programNotified: true), thresholdSeconds: threshold) == nil)
    }

    @Test func aQuickCommandSaysNothing() {
        #expect(RingRing.notice(for: finished(milliseconds: 2_000), thresholdSeconds: threshold) == nil)
    }

    /// macOS's `/bin/bash` is 3.2 and has no `$EPOCHREALTIME`, so it reports no duration. That
    /// is a documented limit, and the honest response is to say nothing rather than guess.
    @Test func withoutADurationItDoesNotGuess() {
        #expect(RingRing.notice(for: finished(milliseconds: nil), thresholdSeconds: threshold) == nil)
        // Not even a failure, because "it failed, eventually" is not worth a banner.
        #expect(
            RingRing.notice(for: finished(milliseconds: nil, exitCode: 1), thresholdSeconds: threshold) == nil)
    }

    /// A banner sits on screen where anyone nearby can read it. The leading space that keeps a
    /// command out of the shell's history keeps it off the screen too.
    @Test func aCommandHiddenFromHistoryIsNeverPutOnScreen() {
        let secret = finished(" curl -H 'Authorization: Bearer hunter2' example.com", milliseconds: 90_000)
        #expect(RingRing.notice(for: secret, thresholdSeconds: threshold) == nil)
        // And not through the failure path either.
        let failed = finished(" ssh prod", milliseconds: 1, exitCode: 255)
        #expect(RingRing.notice(for: failed, thresholdSeconds: threshold) == nil)
    }

    // MARK: - When it speaks

    @Test func aLongCommandIsNamedWithHowLongItTook() throws {
        let notice = try #require(RingRing.notice(for: finished(milliseconds: 95_400), thresholdSeconds: threshold))
        #expect(notice.title == "swift build")
        #expect(notice.body == "Finished in 1m 35s", "\(notice.body)")
    }

    /// A failure is the thing you most need to know about, however quick it was — the same rule
    /// the badge follows.
    @Test func aFailureIsToldHoweverQuickItWas() throws {
        let notice = try #require(
            RingRing.notice(for: finished("make test", milliseconds: 4, exitCode: 2), thresholdSeconds: threshold))
        #expect(notice.title == "make test")
        #expect(notice.body == "Exited with status 2 after 4ms", "\(notice.body)")
    }

    /// Exactly at the threshold counts, so the boundary is not a place where nothing happens.
    @Test func theThresholdItselfCounts() {
        #expect(RingRing.notice(for: finished(milliseconds: 30_000), thresholdSeconds: 30) != nil)
        #expect(RingRing.notice(for: finished(milliseconds: 29_999), thresholdSeconds: 30) == nil)
    }

    /// A threshold big enough to overflow the multiply must not wrap into "notify always".
    @Test func anAbsurdThresholdDoesNotWrapIntoNotifyingAlways() {
        #expect(RingRing.notice(for: finished(milliseconds: 1_000), thresholdSeconds: .max) == nil)
    }

    @Test func aCommandWithNoTextIsStillNameable() throws {
        let notice = try #require(RingRing.notice(for: finished("", milliseconds: 60_000), thresholdSeconds: threshold))
        #expect(notice.title == "A command")
    }

    // MARK: - The seam

    /// `@MainActor` because `Notifier` is: delivery happens where `PaneController` decides it,
    /// and making the seam say so is what gets the real conformer past Swift 6's isolation
    /// checking — which this test target now type-checks on Linux rather than only on macOS.
    @MainActor
    @Test func theFakeRecordsWhatItWasAskedToDeliver() {
        let notifier = FakeNotifier()
        #expect(!notifier.askedForAuthorization)
        notifier.requestAuthorization()
        #expect(notifier.askedForAuthorization)
        notifier.deliver(RingRing.Notice(title: "t", body: "b"), paneID: 7)
        #expect(notifier.delivered.count == 1)
        #expect(notifier.delivered.first?.paneID == 7)
    }
}
