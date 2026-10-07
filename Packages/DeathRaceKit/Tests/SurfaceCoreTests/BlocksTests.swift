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
