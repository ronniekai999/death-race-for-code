import Testing

@testable import VTCore

/// The one question the app cannot answer for itself: where is the block around this line.
///
/// Driven by feeding a real shell's bytes, not by building rows, because what is being tested is
/// that marks found their way onto the rows and survived into scrollback — which is the whole
/// reason the engine is asked rather than the mirror.
@Suite("Prompt spans") struct PromptSpanTests {

    /// What a shell with the integration installed sends for one command.
    private static func command(_ text: String, exit: Int32 = 0, milliseconds: UInt32 = 1_500) -> String {
        "\u{1B}]133;A\u{7}$ \(text)\u{1B}]133;B\u{7}\u{1B}]633;E;\(text)\u{7}\u{1B}]133;C\u{7}"
            + "\u{1B}]133;D;\(exit);dur=\(milliseconds)\u{7}"
    }

    private func terminal(columns: Int = 20, rows: Int = 4, scrollback: Int = 1 << 20) -> Terminal {
        Terminal(Terminal.Configuration(columns: columns, rows: rows, scrollbackLimitBytes: scrollback))
    }

    private func feed(_ terminal: Terminal, _ text: String) {
        terminal.feed(Array(text.utf8))
    }

    // MARK: - Nothing to find

    /// No integration installed is the common case, and it must not be mistaken for a block.
    @Test func aScreenWithNoMarksHasNoSpan() {
        let screen = terminal()
        feed(screen, "just some output\r\nand more")
        #expect(screen.promptSpan(at: 0) == nil)
        #expect(screen.promptSpan(at: 1) == nil)
    }

    /// A full-screen program draws its own screen; the marks on it are whatever it printed.
    @Test func thereIsNoSpanOnTheAlternateScreen() {
        let screen = terminal()
        feed(screen, Self.command("ls"))
        #expect(screen.promptSpan(at: 0) != nil)
        feed(screen, "\u{1B}[?1049h\u{1B}]133;A\u{7}vim")
        #expect(screen.isAlternateScreen)
        #expect(screen.promptSpan(at: 0) == nil)
        // And it comes back when the program leaves.
        feed(screen, "\u{1B}[?1049l")
        #expect(screen.promptSpan(at: 0) != nil)
    }

    // MARK: - One command, and its neighbours

    @Test func aCommandsSpanCarriesItsRecord() {
        let screen = terminal()
        feed(screen, Self.command("swift build", exit: 0, milliseconds: 12_400))
        let span = try! #require(screen.promptSpan(at: 0))
        #expect(span.lines.lowerBound == 0)
        #expect(span.command?.text == "swift build")
        #expect(span.command?.durationMilliseconds == 12_400)
        #expect(span.previousPrompt == nil, "nothing above it")
        #expect(span.nextPrompt == nil, "nothing below it")
    }

    /// The block being typed in runs to the last line the screen has, not to the cursor: output
    /// below the prompt is part of it.
    @Test func theNewestBlockRunsToTheEndOfTheScreen() {
        let screen = terminal(rows: 4)
        feed(screen, Self.command("ls") + "\r\n\u{1B}]133;A\u{7}$ ")
        let span = try! #require(screen.promptSpan(at: 1))
        #expect(span.lines == 1...3, "the prompt's line to the bottom of the screen")
        #expect(span.previousPrompt == 0)
        #expect(span.nextPrompt == nil)
    }

    /// Asked from anywhere inside a block, the answer is that block — which is what makes a
    /// click in the middle of one select the whole thing.
    @Test func anyLineInABlockFindsTheSameSpan() {
        let screen = terminal(rows: 4)
        feed(screen, Self.command("make") + "\r\nfirst\r\nsecond")
        let fromPrompt = try! #require(screen.promptSpan(at: 0))
        let fromOutput = try! #require(screen.promptSpan(at: 2))
        #expect(fromPrompt == fromOutput)
        #expect(fromPrompt.command?.text == "make")
    }

    /// The three prompts a ⌘↑ walk needs: where it is, where it came from, where it goes.
    @Test func theSpanNamesThePromptsEitherSide() {
        let screen = terminal(rows: 6)
        feed(screen, Self.command("one") + "\r\n" + Self.command("two") + "\r\n" + Self.command("three"))
        let middle = try! #require(screen.promptSpan(at: 1))
        #expect(middle.command?.text == "two")
        #expect(middle.previousPrompt == 0)
        #expect(middle.nextPrompt == 2)
    }

    // MARK: - Into history, which is the point

    /// The case the app cannot answer and the engine can: a prompt that has scrolled out of the
    /// viewport entirely. A four-row screen with six commands keeps the first two in scrollback.
    @Test func aPromptOnlyInScrollbackIsStillFound() {
        let screen = terminal(rows: 4)
        for index in 0..<6 {
            feed(screen, Self.command("c\(index)"))
            if index < 5 { feed(screen, "\r\n") }
        }
        #expect(screen.scrollbackCount == 2, "six lines through a four-row screen")
        // Line 0 is off the top of the active area now, and its mark went to scrollback with it.
        let oldest = try! #require(screen.promptSpan(at: 0))
        #expect(oldest.lines == 0...0)
        #expect(oldest.command?.text == "c0")
        #expect(oldest.previousPrompt == nil, "the oldest kept has nothing above it")
        #expect(oldest.nextPrompt == 1)
    }

    /// Trimming the scrollback takes the oldest blocks with it, and the answer says so rather
    /// than claiming a line it no longer has.
    @Test func aPromptTrimmedOutOfScrollbackIsGone() {
        // Room for a line or two of history, not six.
        let screen = terminal(rows: 2, scrollback: 400)
        for index in 0..<6 {
            feed(screen, Self.command("c\(index)"))
            if index < 5 { feed(screen, "\r\n") }
        }
        let kept = screen.linesScrolledOff - UInt64(screen.scrollbackCount)
        #expect(kept > 0, "some history was trimmed, or this test proves nothing")
        #expect(screen.promptSpan(at: 0)?.lines.lowerBound == kept, "clamped to the oldest kept")
    }

    /// A line number past the end is clamped rather than refused: the app asks about the line
    /// under a pointer or at the top of a viewport, and an off-by-one must not read as "no block".
    @Test func aLineOutsideTheScreenIsClampedIntoIt() {
        let screen = terminal(rows: 4)
        feed(screen, Self.command("ls"))
        #expect(screen.promptSpan(at: 9_999)?.command?.text == "ls")
        #expect(screen.promptSpan(at: .max)?.command?.text == "ls")
    }

    /// `promptSpan` works out which row holds a line as `linesScrolledOff - scrollbackCount + i`,
    /// which is only safe while `linesScrolledOff >= scrollbackCount`. That holds by
    /// construction — every row entering the scrollback goes through `pushToScrollback`, which
    /// increments the count, and trimming only ever removes rows — but reflow is where it would
    /// break if it ever did: it replaces the scrollback wholesale, and at a narrower width one
    /// wrapped line becomes two, so the row count grows. In Swift the sum underflowing is a trap
    /// rather than a wrong answer, so the invariant is pinned here rather than assumed.
    @Test func reflowKeepsTheArithmeticTheSpanDependsOn() {
        let screen = terminal(columns: 20, rows: 2)
        feed(screen, Self.command("ls") + "\r\n" + String(repeating: "a", count: 20))
        #expect(screen.promptSpan(at: 0)?.command?.text == "ls")

        // Narrower: every line is re-added, and more rows come out than went in.
        screen.resize(columns: 8, rows: 2)
        #expect(
            Int(screen.linesScrolledOff) >= screen.scrollbackCount,
            "the invariant the row arithmetic rests on")
        // Answers rather than trapping, for every line the screen still claims to have.
        let oldest = screen.linesScrolledOff - UInt64(screen.scrollbackCount)
        for line in oldest...(screen.linesScrolledOff + UInt64(screen.rows) - 1) {
            _ = screen.promptSpan(at: line)
        }
    }

    // MARK: - What bounds the search

    /// A screen with no marks must not walk the whole ring on every keypress; ⌘↑ held down would
    /// walk it again per keypress. The limit is injected small, as `SFTPClient.Limits` is, so
    /// this costs nothing — at the real 50,000 the test would have to build that many rows.
    @Test func theSearchIsBoundedAndStopsBeforeAPromptBeyondIt() {
        #expect(Terminal.promptSearchLimit > 0, "the real one is a bound, not a default of none")
        let screen = terminal(rows: 2)
        // A prompt, then more unmarked output below it than the search will look back through.
        feed(screen, Self.command("far away") + "\r\n")
        feed(screen, String(repeating: "x\r\n", count: 40))
        let bottom = screen.linesScrolledOff + UInt64(screen.rows) - 1
        #expect(
            screen.promptSpan(at: bottom, limit: 5) == nil,
            "it gave up five lines back rather than walking to the prompt")
        // And with room to reach it, the same screen answers — so the nil above is the limit
        // doing its job and not an empty screen.
        #expect(screen.promptSpan(at: bottom, limit: 10_000)?.command?.text == "far away")
    }

    /// The walk *down* from a prompt is bounded too, and when it runs out of allowance the span
    /// stops where it actually looked rather than claiming the rest of the screen.
    ///
    /// Claiming it would be the worse bug of the two: a selection would take every block below,
    /// none of which was examined. One command with a hundred thousand lines of output also made
    /// this walk all of them on the session thread, twice, which is what the other bound exists
    /// to prevent.
    @Test func theWalkDownIsBoundedAndTheSpanStopsWhereItLooked() throws {
        let screen = terminal(rows: 2)
        feed(screen, Self.command("first") + "\r\n")
        feed(screen, String(repeating: "x\r\n", count: 40))
        feed(screen, Self.command("second") + "\r\n")
        let first = try #require(screen.promptSpan(at: 0, limit: 10_000))
        #expect(first.command?.text == "first")

        // With five lines of allowance the block cannot reach the second prompt, so it ends at
        // the fifth line below its own — not at the bottom of the screen, and not inside the
        // second command.
        let bounded = try #require(screen.promptSpan(at: 0, limit: 5))
        #expect(bounded.lines.lowerBound == first.lines.lowerBound)
        #expect(bounded.lines.upperBound == first.lines.lowerBound + 5, "\(bounded.lines)")
        #expect(bounded.lines.upperBound < first.lines.upperBound, "the full block reaches further")
        #expect(bounded.nextPrompt == nil, "it never got there to see it")
    }
}
