import Testing

@testable import AppCore

/// The words on a command's badge, and when there are none.
@Suite struct FastLabelTests {

    // MARK: - When there is nothing to say

    /// Most commands. A badge over every `ls` is noise, and twenty of them are twenty layers.
    @Test func aQuickCommandThatWorkedGetsNoWords() {
        #expect(FastLabel.words(milliseconds: 8, exitCode: 0) == nil)
        #expect(FastLabel.words(milliseconds: 999, exitCode: 0) == nil)
    }

    /// The boundary, said once so it cannot drift: the threshold itself is slow enough.
    @Test func theThresholdIsInclusive() {
        #expect(FastLabel.words(milliseconds: 1_000, exitCode: 0) == "Fast 1.0s ✓")
        #expect(FastLabel.words(milliseconds: 2_000, exitCode: 0, thresholdMilliseconds: 2_500) == nil)
        #expect(FastLabel.words(milliseconds: 2_500, exitCode: 0, thresholdMilliseconds: 2_500) == "Fast 2.5s ✓")
    }

    /// A shell with no integration says nothing about either, so there is nothing to show.
    @Test func aCommandTheShellSaidNothingAboutGetsNoWords() {
        #expect(FastLabel.words(milliseconds: nil, exitCode: nil) == nil)
    }

    // MARK: - When there is

    /// However fast it was: a failure is the thing you most need to see, and the ✗ is what
    /// `docs/DESIGN.md` asks to accompany the danger color.
    @Test func aFailureIsAlwaysWorthSayingHoweverFastItWas() {
        #expect(FastLabel.words(milliseconds: 4, exitCode: 1) == "Fast 4ms · exited with status 1 ✗")
        #expect(FastLabel.words(milliseconds: nil, exitCode: 2) == "Exited with status 2 ✗")
    }

    @Test func aSlowCommandSaysHowLongItTook() {
        #expect(FastLabel.words(milliseconds: 12_350, exitCode: 0) == "Fast 12.4s ✓")
    }

    /// The form `docs/NAMING.md` commits to, middle dot and all.
    @Test func beatingYourBestSaysByHowMuch() {
        #expect(
            FastLabel.words(milliseconds: 12_400, exitCode: 0, bestMilliseconds: 15_500)
                == "Fast 12.4s · 3.1s faster than your best ✓")
    }

    /// And losing to it says nothing: "4.0s slower than your best" is a thing nobody asked to
    /// be told.
    @Test func losingToYourBestSaysNothingAboutIt() {
        #expect(FastLabel.words(milliseconds: 20_000, exitCode: 0, bestMilliseconds: 15_500) == "Fast 20.0s ✓")
    }

    // MARK: - A personal best

    @Test func onlyAFasterSuccessIsAPersonalBest() {
        #expect(FastLabel.isPersonalBest(milliseconds: 100, exitCode: 0, bestMilliseconds: 200))
        #expect(!FastLabel.isPersonalBest(milliseconds: 300, exitCode: 0, bestMilliseconds: 200))
        // A command that failed quickly did not set a record.
        #expect(!FastLabel.isPersonalBest(milliseconds: 100, exitCode: 1, bestMilliseconds: 200))
        // Nor did the first run of one: there was nothing to beat.
        #expect(!FastLabel.isPersonalBest(milliseconds: 100, exitCode: 0, bestMilliseconds: nil))
    }

    // MARK: - The number, with its unit

    /// Every number gets a unit, and as much precision as is worth reading: nobody reads the
    /// tenths on a four-minute build.
    @Test func aDurationIsAsShortAsItCanBe() {
        #expect(FastLabel.duration(0) == "0ms")
        #expect(FastLabel.duration(999) == "999ms")
        #expect(FastLabel.duration(1_000) == "1.0s")
        #expect(FastLabel.duration(12_350) == "12.4s")
        #expect(FastLabel.duration(59_949) == "59.9s")
        #expect(FastLabel.duration(60_000) == "1m 00s")
        #expect(FastLabel.duration(64_000) == "1m 04s")
        #expect(FastLabel.duration(723_000) == "12m 03s")
        #expect(FastLabel.duration(3_600_000) == "1h 00m")
        #expect(FastLabel.duration(7_500_000) == "2h 05m")
    }

    /// Rounding at the boundaries, where an off-by-one shows as "0.10s" or "1m 60s".
    @Test func aDurationRoundsWithoutSpillingOver() {
        #expect(FastLabel.duration(59_950) == "60.0s")
        #expect(FastLabel.duration(119_500) == "2m 00s")
        #expect(!FastLabel.duration(1_000).contains("0.10"))
    }
}
