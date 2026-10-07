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

    /// What a shell sends for one command, start to finish.
    private static func command(_ text: String, exit: Int32, milliseconds: UInt32) -> String {
        "\u{1B}]133;A\u{7}$ \(text)\u{1B}]133;B\u{7}\u{1B}]633;E;\(text)\u{7}\u{1B}]133;C\u{7}"
            + "\u{1B}]133;D;\(exit);dur=\(milliseconds)\u{7}"
    }

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

    @Test func aCommandOnOneRowIsOneBlock() {
        let screen = Screen()
        screen.feed(Self.command("ls", exit: 0, milliseconds: 1_500))
        let run = try! #require(screen.runs.first)
        #expect(screen.runs.count == 1)
        #expect(run.lines == 0...3, "to the end of the viewport: nothing has come after it yet")
        #expect(run.command?.text == "ls")
        #expect(run.command?.durationMilliseconds == 1_500)
        #expect(run.failed == false)
        #expect(run.rows == 4)
    }

    @Test func aCommandThatPrintedSeveralRowsIsStillOneBlock() {
        let screen = Screen()
        screen.feed("\u{1B}]133;A\u{7}$ seq\u{1B}]133;C\u{7}\r\n1\r\n2\u{1B}]133;D;0;dur=9\u{7}")
        #expect(screen.runs.count == 1)
        #expect(screen.runs.first?.lines == 0...3)
    }

    @Test func eachPromptStartsTheNextBlock() {
        let screen = Screen()
        screen.feed(Self.command("one", exit: 0, milliseconds: 10))
        screen.feed("\r\n" + Self.command("two", exit: 7, milliseconds: 20))
        let runs = screen.runs
        #expect(runs.count == 2)
        #expect(runs[0].lines == 0...0, "it ends where the next one begins")
        #expect(runs[0].command?.text == "one")
        #expect(runs[1].lines == 1...3)
        #expect(runs[1].command?.text == "two")
        #expect(runs[1].failed == true)
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

        // With the next prompt in view, the lines above it are the block that is ending.
        screen.feed("\r\n\u{1B}]133;D;0;dur=5\u{7}\u{1B}]133;A\u{7}$ ")
        let runs = screen.runs
        #expect(runs.count == 2)
        #expect(runs[0].lines.lowerBound == screen.model.mirror.viewportTopLine, "up to the top edge")
    }

    // MARK: - Which one you are in

    @Test func theBlockHoldingTheCursorIsTheCurrentOne() {
        let screen = Screen()
        screen.feed(Self.command("one", exit: 0, milliseconds: 10))
        screen.feed("\r\n" + Self.command("two", exit: 0, milliseconds: 20))
        #expect(screen.runs.map(\.isCurrent) == [false, true])
    }

    /// Scrolled back through history, the cursor is still in the block it is in — it does not
    /// move to whatever happens to be on screen.
    @Test func scrollingDoesNotMoveWhichBlockIsCurrent() {
        let screen = Screen(columns: 12, rows: 2)
        for index in 0..<8 {
            screen.feed(Self.command("c\(index)", exit: 0, milliseconds: 10) + "\r\n")
        }
        screen.feed("\u{1B}]133;A\u{7}$ ")
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
            screen.feed(Self.command("c\(index)", exit: 0, milliseconds: 10) + "\r\n")
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

    private static func command(_ text: String) -> String {
        "\u{1B}]133;A\u{7}$ \(text)\u{1B}]133;B\u{7}\u{1B}]633;E;\(text)\u{7}\u{1B}]133;C\u{7}"
            + "\u{1B}]133;D;0;dur=100\u{7}"
    }

    // MARK: - The scroll a jump asks for

    /// `scroll(by:)` is relative, and that is all a jump needs: the engine says which line, the
    /// view knows which line is at the top, and the difference is the scroll.
    @Test func aJumpBackAsksToGoIntoHistory() {
        let screen = Screen(rows: 4)
        for index in 0..<8 {
            screen.feed(Self.command("c\(index)"))
            if index < 7 { screen.feed("\r\n") }
        }
        let mirror = screen.model.mirror
        #expect(mirror.viewportTopLine == 4, "four rows of an eight-line screen")
        // Positive is back into history, which is `TerminalSession.scroll(by:)`'s own sign.
        #expect(Blocks.scroll(toPut: 0, atTopOf: mirror) == 4)
        #expect(Blocks.scroll(toPut: 2, atTopOf: mirror) == 2)
        // Forward, toward the output, is negative.
        #expect(Blocks.scroll(toPut: 6, atTopOf: mirror) == -2)
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
        let screen = Screen(rows: 4)
        screen.feed(Self.command("make") + "\r\nfirst\r\nsecond\r\n" + Self.command("ls"))
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

    /// A block of one line is still a selection, which is the common case: prompt, command and
    /// output all on one row.
    @Test func aOneLineBlockSelectsThatLine() throws {
        let screen = Screen(rows: 4)
        screen.feed(Self.command("ls") + "\r\n" + Self.command("pwd"))
        let mirror = screen.model.mirror
        let selection = Blocks.selection(of: PromptSpan(lines: 0...0), in: mirror)
        let range = try #require(selection.range)
        #expect(range.start.line == 0 && range.end.line == 0)
        let text = TextExtractor.text(in: range) { mirror.line($0) }
        #expect(text.contains("ls") && !text.contains("pwd"))
    }
}
