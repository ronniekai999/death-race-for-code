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
}
