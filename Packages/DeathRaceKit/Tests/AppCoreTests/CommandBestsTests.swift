import Testing

@testable import AppCore

/// The best time each command has taken, so "faster than your best" has something true behind
/// it.
@Suite struct CommandBestsTests {

    @Test func theFirstRunOfACommandSetsNoRecord() {
        var bests = CommandBests()
        #expect(bests.record(command: "swift build", milliseconds: 12_000) == nil)
        #expect(bests.best(for: "swift build") == 12_000)
    }

    @Test func aFasterRunBeatsTheOneBeforeItAndSaysWhatItBeat() {
        var bests = CommandBests()
        bests.record(command: "swift build", milliseconds: 12_000)
        // What it beat, so the words can say by how much.
        #expect(bests.record(command: "swift build", milliseconds: 9_000) == 12_000)
        #expect(bests.best(for: "swift build") == 9_000)
    }

    @Test func aSlowerRunChangesNothing() {
        var bests = CommandBests()
        bests.record(command: "swift build", milliseconds: 9_000)
        #expect(bests.record(command: "swift build", milliseconds: 20_000) == nil)
        #expect(bests.best(for: "swift build") == 9_000)
    }

    @Test func commandsAreTheirOwn() {
        var bests = CommandBests()
        bests.record(command: "make", milliseconds: 1_000)
        bests.record(command: "make test", milliseconds: 5_000)
        #expect(bests.best(for: "make") == 1_000)
        #expect(bests.best(for: "make test") == 5_000)
        #expect(bests.best(for: "make lint") == nil)
    }

    @Test func anEmptyCommandIsNotWorthRemembering() {
        var bests = CommandBests()
        #expect(bests.record(command: "", milliseconds: 10) == nil)
        #expect(bests.count == 0)
    }

    /// A session that runs for days types a lot of different lines, and every one of them would
    /// otherwise be held for ever.
    @Test func theOldestIsForgottenOnceTheLimitIsReached() {
        var bests = CommandBests(limit: 3)
        for index in 0..<3 { bests.record(command: "c\(index)", milliseconds: 100) }
        #expect(bests.count == 3)
        bests.record(command: "c3", milliseconds: 100)
        #expect(bests.count == 3)
        #expect(bests.best(for: "c0") == nil, "the one not run in longest")
        #expect(bests.best(for: "c3") == 100)
    }

    /// Running a command again moves it to the back of the queue, so the thing you use most is
    /// not the thing that gets dropped.
    @Test func runningACommandAgainKeepsItFromBeingForgotten() {
        var bests = CommandBests(limit: 3)
        for index in 0..<3 { bests.record(command: "c\(index)", milliseconds: 100) }
        bests.record(command: "c0", milliseconds: 90)
        bests.record(command: "c3", milliseconds: 100)
        #expect(bests.best(for: "c0") == 90, "used most recently, so still there")
        #expect(bests.best(for: "c1") == nil, "the one not run in longest")
    }

    // MARK: - What a badge compares against

    /// The record holder is measured against the best before it, because by the time its badge
    /// is drawn the run has already been recorded and `best` is its own time.
    @Test func theRecordHolderIsMeasuredAgainstWhatItBeat() {
        var bests = CommandBests()
        bests.record(command: "swift build", milliseconds: 15_500)
        bests.record(command: "swift build", milliseconds: 12_400)
        #expect(bests.best(for: "swift build") == 12_400)
        #expect(bests.bestToBeat(for: "swift build", milliseconds: 12_400) == 15_500)
        // Which is what makes the clause reachable at all: the old lookup compared 12_400 with
        // itself, so "faster than your best" and the 999 flash could never fire.
        #expect(bests.best(for: "swift build") == 12_400)
    }

    /// A run that did not win is measured against the record, which it cannot beat, so the
    /// words stay quiet rather than claiming something.
    @Test func aSlowerRunIsMeasuredAgainstTheRecordAndSaysNothing() {
        var bests = CommandBests()
        bests.record(command: "make", milliseconds: 1_000)
        bests.record(command: "make", milliseconds: 4_000)
        #expect(bests.bestToBeat(for: "make", milliseconds: 4_000) == 1_000)
        #expect(bests.bestToBeat(for: "make", milliseconds: 4_000)! < 4_000, "so no clause is said")
    }

    @Test func aFirstRunHasNothingToBeMeasuredAgainst() {
        var bests = CommandBests()
        bests.record(command: "make", milliseconds: 1_000)
        #expect(bests.bestToBeat(for: "make", milliseconds: 1_000) == nil)
        #expect(bests.bestToBeat(for: "never run", milliseconds: 1_000) == nil)
        #expect(bests.bestToBeat(for: "make", milliseconds: nil) == nil, "a shell that reports no duration")
    }

    /// What the record it beat was is forgotten along with the command itself.
    @Test func whatACappedCommandBeatGoesWithIt() {
        var bests = CommandBests(limit: 2)
        bests.record(command: "a", milliseconds: 100)
        bests.record(command: "a", milliseconds: 90)
        #expect(bests.bestToBeat(for: "a", milliseconds: 90) == 100)
        bests.record(command: "b", milliseconds: 100)
        bests.record(command: "c", milliseconds: 100)
        #expect(bests.best(for: "a") == nil)
        #expect(bests.bestToBeat(for: "a", milliseconds: 90) == nil)
    }

    // MARK: - What "nothing changed" means

    /// At the cap a new command evicts an old one, so the count does not move. Counting
    /// commands to decide whether the file needs writing therefore stopped writing it the
    /// moment the cap was reached — and the value is what has to be compared.
    @Test func atTheCapTheValueChangesWhileTheCountDoesNot() {
        var bests = CommandBests(limit: 3)
        for index in 0..<3 { bests.record(command: "c\(index)", milliseconds: 100) }
        let before = bests
        bests.record(command: "new", milliseconds: 100)
        #expect(bests.count == before.count, "which is why counting was the wrong question")
        #expect(bests != before, "and why asking the value is the right one")
    }

    /// Even a run that sets no record moves the least-recently-run order, which is the order
    /// the file's eviction depends on, so that is a change worth writing too.
    @Test func aSlowerRunStillMovesTheOrder() {
        var bests = CommandBests(limit: 3)
        for index in 0..<3 { bests.record(command: "c\(index)", milliseconds: 100) }
        let before = bests
        bests.record(command: "c0", milliseconds: 500)
        #expect(bests.best(for: "c0") == 100, "no record was set")
        #expect(bests != before, "but c0 is no longer the one to drop next")
    }
}
