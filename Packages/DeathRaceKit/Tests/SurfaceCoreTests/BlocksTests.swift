import ScreenProtocol
import Testing
import VTCore

@testable import SurfaceCore

/// The blocks in view, read from the grid.
///
/// Driven through a real engine rather than a hand-built `MirrorGrid`: the marks have to arrive
/// the way a shell sends them, through the parser and a delta, or this would be testing a
/// fixture rather than the thing the app will see.
@Suite("Blocks") struct BlocksTests {

    private struct Screen {
        let session: ReplaySession
        let model: SurfaceModel

        init(columns: Int = 12, rows: Int = 4) {
            session = ReplaySession(Terminal.Configuration(columns: columns, rows: rows))
            model = SurfaceModel(session: session)
        }

        @discardableResult
        func feed(_ text: String) -> SurfaceModel.Update {
            session.feed(text)
            return model.drain()
        }

        var runs: [BlockRun] { Blocks.runs(in: model.mirror) }
    }

    /// What a shell sends for one command: the prompt, the newline Return makes, the command
    /// and its output — and then `D`, from the hook that draws the next prompt, at the start of
    /// the row after the output, where the next command's `A` follows it. So commands are fed
    /// back to back, as `RealShellTests` shows zsh, bash and fish all sending them.
    private static func command(
        _ text: String, output: [String] = [], exit: Int32, milliseconds: UInt32
    ) -> String {
        "\u{1B}]133;A\u{7}$ \(text)\u{1B}]133;B\u{7}\r\n\u{1B}]633;E;\(text)\u{7}\u{1B}]133;C\u{7}"
            + output.map { $0 + "\r\n" }.joined() + "\u{1B}]133;D;\(exit);dur=\(milliseconds)\u{7}"
    }

    private static let prompt = "\u{1B}]133;A\u{7}$ "

    // MARK: - Nothing to draw

    @Test func anEmptyScreenHasNoBlocks() {
        #expect(Screen().runs.isEmpty)
    }

    /// No integration installed is the common case, and it must look exactly like today.
    @Test func aScreenWithNoMarksHasNoBlocks() {
        let screen = Screen()
        screen.feed("just some output\r\nand more")
        #expect(screen.runs.isEmpty)
    }

    /// A full-screen program draws its own screen: a rail down the side of vim would be wrong,
    /// and the marks on the alternate screen are whatever it happened to print.
    @Test func thereAreNoBlocksOnTheAlternateScreen() {
        let screen = Screen()
        screen.feed(Self.command("ls", exit: 0, milliseconds: 5))
        #expect(!screen.runs.isEmpty)
        screen.feed("\u{1B}[?1049h\u{1B}]133;A\u{7}vim")
        #expect(screen.model.mirror.isAlternateScreen)
        #expect(screen.runs.isEmpty)
        // And they come back when the program leaves.
        screen.feed("\u{1B}[?1049l")
        #expect(!screen.runs.isEmpty)
    }

    // MARK: - One command, and several

    @Test func aFinishedCommandIsOneBlock() {
        let screen = Screen()
        screen.feed(Self.command("ls", exit: 0, milliseconds: 1_500))
        let run = try! #require(screen.runs.first)
        #expect(screen.runs.count == 1)
        #expect(run.lines == 0...1, "to the cursor, not the bottom of the screen")
        #expect(run.command?.text == "ls")
        #expect(run.command?.durationMilliseconds == 1_500)
        #expect(run.failed == false)
        #expect(run.rows == 2)
    }

    @Test func aCommandThatPrintedSeveralRowsIsStillOneBlock() {
        let screen = Screen()
        screen.feed(Self.command("seq", output: ["1", "2"], exit: 0, milliseconds: 9))
        #expect(screen.runs.count == 1)
        #expect(screen.runs.first?.lines == 0...3)
    }

    @Test func eachPromptStartsTheNextBlock() {
        let screen = Screen()
        screen.feed(Self.command("one", exit: 0, milliseconds: 10))
        screen.feed(Self.command("two", exit: 7, milliseconds: 20))
        let runs = screen.runs
        #expect(runs.count == 2)
        #expect(runs[0].lines == 0...0, "it ends where the next one begins")
        #expect(runs[0].command?.text == "one")
        #expect(runs[1].lines == 1...2)
        #expect(runs[1].command?.text == "two")
        #expect(runs[1].failed == true)
    }

    /// The screen this was found on: a command that failed, then one that worked. The shell
    /// sends each `D` at the start of the next prompt's row, and read as that prompt's, the
    /// failure's ✗ and rail went to the command that had worked, and its ✓ to the prompt.
    @Test func aFailureBelongsToItsOwnCommandNotTheNextOne() {
        let screen = Screen(columns: 20, rows: 6)
        screen.feed(Self.command("fast -u", output: ["fast: not found"], exit: 127, milliseconds: 8))
        screen.feed(Self.command("speedtest-cli", output: ["Download: 112"], exit: 0, milliseconds: 23_300))
        screen.feed(Self.prompt)
        let runs = screen.runs
        #expect(runs.map { $0.command?.text } == ["fast -u", "speedtest-cli", nil])
        #expect(runs.map(\.failed) == [true, false, nil])
        #expect(runs.map(\.lines) == [0...1, 2...3, 4...4])
    }

    /// The block being typed in ends at the cursor: the rows under a prompt are empty, and a
    /// band down to the bottom of the screen marks nothing. Something written below the cursor
    /// is still part of it.
    @Test func theBlockYouAreTypingInEndsAtTheCursor() {
        let screen = Screen(columns: 20, rows: 6)
        screen.feed(Self.command("ls", exit: 0, milliseconds: 10) + Self.prompt)
        #expect(screen.runs.last?.lines == 1...1)
        #expect(screen.runs.last?.isCurrent == true)
        // Two rows down, a word, and back up to the prompt.
        screen.feed("\u{1B}[2Bnote\u{1B}[2A")
        #expect(screen.runs.last?.lines == 1...3)
    }

    /// The prompt you are typing at: no `D` yet, so nothing is known about how it went, which
    /// is not the same as its having gone well.
    @Test func aPromptWithNoEndYetSaysNothingAboutHowItWent() {
        let screen = Screen()
        screen.feed("\u{1B}]133;A\u{7}$ sleep 60\u{1B}]133;C\u{7}")
        let run = try! #require(screen.runs.first)
        #expect(run.command == nil)
        #expect(run.failed == nil)
    }

    // MARK: - A block that began above the screen

    /// Output that filled the screen pushes its own prompt off the top. The rail still has to
    /// reach the top edge, or it would stop in mid-air partway down a build's output.
    @Test func aBlockThatBeganAboveTheScreenReachesItsTopEdge() {
        let screen = Screen(columns: 12, rows: 3)
        screen.feed("\u{1B}]133;A\u{7}$ build\u{1B}]133;C\u{7}\r\na\r\nb\r\nc\r\nd")
        #expect(screen.model.mirror.lines.count == 3)
        // The prompt has scrolled away, so there is no mark in view at all.
        #expect(screen.runs.isEmpty, "nothing in view says a block is there; the engine would have to be asked")

        // With the next prompt in view, the lines above it are the block that is ending, and
        // its end, on that prompt's row, is its own.
        screen.feed("\r\n\u{1B}]133;D;0;dur=5\u{7}\u{1B}]133;A\u{7}$ ")
        let runs = screen.runs
        #expect(runs.count == 2)
        #expect(runs[0].lines.lowerBound == screen.model.mirror.viewportTopLine, "up to the top edge")
        #expect(runs[0].command?.durationMilliseconds == 5)
        #expect(runs[1].command == nil)
    }

    // MARK: - Which one you are in

    @Test func theBlockHoldingTheCursorIsTheCurrentOne() {
        let screen = Screen()
        screen.feed(Self.command("one", exit: 0, milliseconds: 10))
        screen.feed(Self.command("two", exit: 0, milliseconds: 20))
        #expect(screen.runs.map(\.isCurrent) == [false, true])
    }

    /// Scrolled back through history, the cursor is still in the block it is in — it does not
    /// move to whatever happens to be on screen.
    @Test func scrollingDoesNotMoveWhichBlockIsCurrent() {
        let screen = Screen(columns: 12, rows: 2)
        for index in 0..<8 {
            screen.feed(Self.command("c\(index)", exit: 0, milliseconds: 10))
        }
        screen.feed(Self.prompt)
        #expect(screen.runs.last?.isCurrent == true)
        screen.session.scroll(by: 6)
        _ = screen.model.drain()
        #expect(screen.runs.allSatisfy { !$0.isCurrent }, "the cursor's block is not on screen any more")
    }

    /// The arithmetic both the band and ⌘⇧A depend on, pinned on its own: the cursor is placed
    /// in the active area, so the viewport's own scroll is part of the line it sits on. A test
    /// through `runs` would only notice a wrong sum when it changed which block was current.
    @Test func theCursorsLineCountsTheViewportsOwnScroll() {
        let screen = Screen(columns: 12, rows: 2)
        for index in 0..<8 {
            screen.feed(Self.command("c\(index)", exit: 0, milliseconds: 10))
        }
        let onScreen = Blocks.cursorLine(in: screen.model.mirror)
        #expect(onScreen == screen.model.mirror.viewportTopLine &+ UInt64(screen.model.mirror.cursor.y))

        // Scrolled back, the cursor has not moved but the top of the view has, so the offset is
        // what keeps the answer the same line.
        screen.session.scroll(by: 5)
        _ = screen.model.drain()
        #expect(screen.model.mirror.viewportOffset == 5, "the screen did not scroll back")
        #expect(Blocks.cursorLine(in: screen.model.mirror) == onScreen)
    }

    // MARK: - Scrolled back

    /// A failed `make` with its output, then the next prompt — on a screen just big enough
    /// that scrolling back one line leaves that prompt, and the `D` on it, below the view.
    private static func failedMake(on screen: Screen, outputLines: Int = 3) {
        for index in 0..<4 {
            screen.feed(Self.command("c\(index)", exit: 0, milliseconds: 10))
        }
        let output = (1...outputLines).map { "error: e\($0)" }
        screen.feed(Self.command("make", output: output, exit: 2, milliseconds: 4_200))
        screen.feed(Self.prompt)
    }

    /// The case the review found: scrolled back one line, the failed command's own record is
    /// on the next prompt's row, which is no longer in view, and its rail went with it.
    @Test func aFailureKeepsItsRailWhenItsEndIsJustBelowTheView() {
        let screen = Screen(columns: 20, rows: 6)
        Self.failedMake(on: screen)
        #expect(screen.runs.first { $0.command?.text == "make" }?.failed == true, "at the bottom")

        screen.session.scroll(by: 1)
        let update = screen.model.drain()
        #expect(screen.model.mirror.viewportOffset == 1, "the screen did not scroll back")
        let last = try? #require(screen.runs.last)
        #expect(last?.command?.text == "make")
        #expect(last?.failed == true)
        #expect(update.viewportMoved)
    }

    /// Scrolled up into the middle of a long failure to read it: the next prompt is many lines
    /// below, and the rail still says the command failed.
    @Test func aFailureKeepsItsRailWhileYouReadItsOutput() {
        let screen = Screen(columns: 20, rows: 6)
        Self.failedMake(on: screen, outputLines: 30)
        screen.session.scroll(by: 12)
        _ = screen.model.drain()
        #expect(screen.runs.last?.command?.text == "make")
        #expect(screen.runs.last?.failed == true)
    }

    /// fish sends `D` at the end of the output, on its own row, and the next `A` on the row
    /// after: the record is in the block, below the view, rather than on the prompt's row.
    @Test func aRecordInsideTheBlockBelowTheViewCountsToo() {
        let screen = Screen(columns: 20, rows: 4)
        screen.feed(Self.command("c0", exit: 0, milliseconds: 10))
        screen.feed(
            "\u{1B}]133;A\u{7}$ false\u{1B}]133;B\u{7}\r\n\u{1B}]633;E;false\u{7}\u{1B}]133;C\u{7}"
                + "one\r\ntwo\r\nthree\r\n\u{1B}]133;D;1\u{7}\r\n")
        screen.feed(Self.prompt)
        screen.session.scroll(by: 2)
        _ = screen.model.drain()
        #expect(screen.runs.last?.command?.text == "false")
        #expect(screen.runs.last?.failed == true)
    }

    /// Following the output there is nothing below the view to say anything, and a block that
    /// is still running says nothing about how it went, scrolled back or not.
    @Test func nothingBelowTheViewSaysNothing() {
        let screen = Screen(columns: 20, rows: 6)
        Self.failedMake(on: screen)
        #expect(screen.model.mirror.outcomeBelow == nil)
        screen.feed("\u{1B}]633;E;sleep 9\u{7}sleep 9\u{1B}]133;C\u{7}\r\n")
        for index in 0..<8 { screen.feed("tick \(index)\r\n") }
        screen.session.scroll(by: 2)
        _ = screen.model.drain()
        #expect(screen.model.mirror.outcomeBelow == nil)
        #expect(screen.runs.last?.failed == nil)
    }

    /// The record arriving while scrolled back changes the rail though no row in view does, so
    /// the update has to say so or the view would not draw it.
    @Test func anOutcomeArrivingBelowTheViewIsSomethingToDraw() {
        let screen = Screen(columns: 20, rows: 6)
        Self.failedMake(on: screen)
        screen.feed("\u{1B}]633;E;make\u{7}make\u{1B}]133;C\u{7}\r\nerror: again\r\n")
        screen.session.scroll(by: 1)
        _ = screen.model.drain()
        #expect(screen.runs.last?.failed == nil, "still running")
        let update = screen.feed("\u{1B}]133;D;2;dur=900\u{7}")
        #expect(update.outcomeBelowChanged)
        #expect(!update.isEmpty)
        #expect(screen.runs.last?.failed == true)
    }

    /// A program that prints a mark of its own is overruled by the shell's, which always comes
    /// after the output. The engine cannot tell whose bytes they are, and no terminal can.
    @Test func theShellsOwnEndIsTheLastWordInABlock() {
        let screen = Screen()
        screen.feed("\u{1B}]133;A\u{7}$ liar\u{1B}]133;C\u{7}")
        screen.feed("\u{1B}]133;D;99\u{7}\r\n")
        screen.feed("\u{1B}]633;E;liar\u{7}\u{1B}]133;D;0;dur=3000\u{7}")
        #expect(screen.runs.first?.command?.exitCode == 0)
        #expect(screen.runs.first?.command?.durationMilliseconds == 3_000)
    }
}

/// The two decisions the macOS half needs made for it: how far to scroll to reach a prompt, and
/// what a block's selection covers. Both portable, so both gated here rather than on a Mac.
@Suite("Jumping and selecting") struct BlockJumpTests {

    private struct Screen {
        let session: ReplaySession
        let model: SurfaceModel

        init(columns: Int = 12, rows: Int = 4) {
            session = ReplaySession(Terminal.Configuration(columns: columns, rows: rows))
            model = SurfaceModel(session: session)
        }

        @discardableResult
        func feed(_ text: String) -> SurfaceModel.Update {
            session.feed(text)
            return model.drain()
        }
    }

    /// What a shell sends for one command, as `BlocksTests.command` explains: `D` at the start
    /// of the row after the output, where the next command's prompt follows it.
    private static func command(_ text: String, output: [String] = []) -> String {
        "\u{1B}]133;A\u{7}$ \(text)\u{1B}]133;B\u{7}\r\n\u{1B}]633;E;\(text)\u{7}\u{1B}]133;C\u{7}"
            + output.map { $0 + "\r\n" }.joined() + "\u{1B}]133;D;0;dur=100\u{7}"
    }

    // MARK: - The scroll a jump asks for

    /// `scroll(by:)` is relative, and that is all a jump needs: the engine says which line, the
    /// view knows which line is at the top, and the difference is the scroll.
    @Test func aJumpBackAsksToGoIntoHistory() {
        let screen = Screen(rows: 4)
        for index in 0..<8 { screen.feed(Self.command("c\(index)")) }
        let mirror = screen.model.mirror
        #expect(mirror.viewportTopLine == 5, "four rows of a nine-line screen: eight prompts and the last end")
        // Positive is back into history, which is `TerminalSession.scroll(by:)`'s own sign.
        #expect(Blocks.scroll(toPut: 0, atTopOf: mirror) == 5)
        #expect(Blocks.scroll(toPut: 2, atTopOf: mirror) == 3)
        // Forward, toward the output, is negative.
        #expect(Blocks.scroll(toPut: 7, atTopOf: mirror) == -2)
    }

    /// A target already at the top scrolls nothing — so ⌘↑ on the first prompt in view does not
    /// twitch the screen.
    @Test func aTargetAlreadyAtTheTopScrollsNothing() {
        let screen = Screen(rows: 4)
        screen.feed(Self.command("ls"))
        #expect(Blocks.scroll(toPut: screen.model.mirror.viewportTopLine, atTopOf: screen.model.mirror) == 0)
    }

    /// A line number crosses a process boundary, so it could be anything. Clamped rather than
    /// wrapped: a wrap would scroll hard the opposite way.
    @Test func anAbsurdLineIsClampedNotWrapped() {
        let screen = Screen(rows: 4)
        screen.feed(Self.command("ls"))
        let mirror = screen.model.mirror
        #expect(Blocks.scroll(toPut: .max, atTopOf: mirror) < 0, "forward, however far")
        #expect(Blocks.scroll(toPut: 0, atTopOf: mirror) >= 0, "back, however far")
    }

    // MARK: - What a block's selection covers

    /// The command and its output, and nothing of the block after it.
    @Test func aBlocksSelectionCoversItsLinesAndNoMore() throws {
        let screen = Screen(rows: 6)
        screen.feed(Self.command("make", output: ["first", "second"]) + Self.command("ls"))
        let mirror = screen.model.mirror
        let runs = Blocks.runs(in: mirror)
        let first = try #require(runs.first { $0.command?.text == "make" })
        let span = PromptSpan(lines: first.lines, command: first.command)

        let selection = Blocks.selection(of: span, in: mirror)
        let range = try #require(selection.range, "a block's selection covers lines, so it is never empty")
        #expect(range.start.line == first.lines.lowerBound)
        #expect(range.end.line == first.lines.upperBound)
        #expect(!range.isRectangular, "a block is lines, not a column of them")

        let text = TextExtractor.text(in: range) { mirror.line($0) }
        #expect(text.contains("make"), "the command itself")
        #expect(text.contains("first") && text.contains("second"), "its output")
        #expect(!text.contains("ls"), "and nothing of the next block")
    }

    /// Output that wrapped into the next prompt's row. `.line` granularity follows `isWrapped`
    /// outward, and the block's selection must still stop at the block.
    ///
    /// This is the shape that broke the promise, and it took two attempts to write: a row that
    /// exactly fills the width is *not* wrapped, because the flag is set when a character is
    /// forced onto the next row rather than when one ends it. Output with no trailing newline
    /// is what puts a prompt on a continuation row — and the walk down then took that prompt,
    /// and the command on it, into the previous block's selection.
    @Test func outputThatWrappedIntoTheNextPromptDoesNotDragItIn() throws {
        let screen = Screen(columns: 8, rows: 5)
        // Output longer than the width and with no newline after it, so it wraps and the next
        // prompt lands on the continuation row. Exactly filling the width is not enough: the
        // wrap flag is set when a character is forced onto the next row, not when one ends it.
        screen.feed(
            "\u{1B}]133;A\u{7}$ make\u{1B}]133;B\u{7}\r\n\u{1B}]633;E;make\u{7}\u{1B}]133;C\u{7}"
                + String(repeating: "x", count: 12) + "\u{1B}]133;D;0;dur=100\u{7}")
        screen.feed(Self.command("ls"))
        let mirror = screen.model.mirror
        let runs = Blocks.runs(in: mirror)
        let first = try #require(runs.first { $0.command?.text == "make" })
        let next = try #require(runs.first { $0.command?.text == "ls" })

        let selection = Blocks.selection(of: PromptSpan(lines: first.lines, command: first.command), in: mirror)
        let range = try #require(selection.range)
        #expect(range.end.line == first.lines.upperBound, "\(range) against the block \(first.lines)")
        #expect(range.end.line < next.lines.lowerBound, "it reached into the next command's block")
        let text = TextExtractor.text(in: range) { mirror.line($0) }
        #expect(!text.contains("ls"), "and nothing of the next block: \(text)")
    }

    /// A block of one line is still a selection: a command with no output is its prompt's row.
    @Test func aOneLineBlockSelectsThatLine() throws {
        let screen = Screen(rows: 4)
        screen.feed(Self.command("ls") + Self.command("pwd"))
        let mirror = screen.model.mirror
        let selection = Blocks.selection(of: PromptSpan(lines: 0...0), in: mirror)
        let range = try #require(selection.range)
        #expect(range.start.line == 0 && range.end.line == 0)
        let text = TextExtractor.text(in: range) { mirror.line($0) }
        #expect(text.contains("ls") && !text.contains("pwd"))
    }
}
