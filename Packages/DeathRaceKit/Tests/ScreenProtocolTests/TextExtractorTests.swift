import Testing
import VTCore

@testable import ScreenProtocol

@Suite struct TextExtractorTests {
    private func terminal(_ text: String, columns: Int = 10, rows: Int = 4, scrollback: Int = 50 << 20) -> Terminal {
        let terminal = Terminal(
            Terminal.Configuration(columns: columns, rows: rows, scrollbackLimitBytes: scrollback))
        terminal.feed(text)
        return terminal
    }

    private func text(_ terminal: Terminal, _ a: (UInt64, Int), _ b: (UInt64, Int), rectangular: Bool = false)
        -> String
    {
        let range = TextRegion(
            TextPoint(line: a.0, column: a.1), TextPoint(line: b.0, column: b.1), rectangular: rectangular)
        return TextExtractor.text(in: range) { terminal.line($0) }
    }

    @Test func partOfALine() {
        let t = terminal("hello world")
        #expect(text(t, (0, 0), (0, 4)) == "hello")
        #expect(text(t, (0, 6), (0, 0)) == "hello w")
    }

    @Test func linesJoinWithNewlinesAndLoseTrailingBlanks() {
        let t = terminal("ab   \r\ncd\r\n\r\nef")
        #expect(text(t, (0, 0), (3, 9)) == "ab\ncd\n\nef")
        #expect(text(t, (0, 1), (1, 0)) == "b\nc")
    }

    @Test func softWrappedRowsAreOneLine() {
        let t = terminal("0123456789abc\r\nnext")
        #expect(t.row(0).isWrapped)
        #expect(text(t, (0, 0), (2, 9)) == "0123456789abc\nnext")
        #expect(text(t, (0, 5), (1, 1)) == "56789ab")
    }

    /// A line that wraps right after a space keeps the space.
    @Test func aSpaceAtAWrapIsKept() {
        let t = terminal("012345678 abc")
        #expect(text(t, (0, 0), (1, 9)) == "012345678 abc")
    }

    @Test func wideCharactersComeOnceAndWhole() {
        let t = terminal("中文 ok")
        #expect(text(t, (0, 0), (0, 9)) == "中文 ok")
        // From the right half of 中, the selection still takes all of it.
        #expect(text(t, (0, 1), (0, 2)) == "中文")
    }

    /// A wide character that does not fit at the end of a row leaves a spacer there, which is
    /// no space in the text.
    @Test func spacerHeadsAreNotText() {
        let t = terminal("012345678中")
        #expect(text(t, (0, 0), (1, 9)) == "012345678中")
    }

    @Test func combiningMarksStayWithTheirLetter() {
        let t = terminal("cafe\u{301}!")
        #expect(text(t, (0, 0), (0, 9)) == "cafe\u{301}!")
    }

    @Test func rectanglesTakeTheSameColumnsOnEveryLine() {
        let t = terminal("abcdef\r\nghijkl\r\nmn")
        #expect(text(t, (0, 3), (2, 1), rectangular: true) == "bcd\nhij\nn")
    }

    @Test func historyAndScreenTogether() {
        let t = terminal((1...9).map(String.init).joined(separator: "\r\n"))
        // Lines 0-4 are in scrollback, 5-8 on screen.
        #expect(t.linesScrolledOff == 5)
        #expect(text(t, (3, 0), (6, 9)) == "4\n5\n6\n7")
        #expect(t.line(9) == nil)
    }

    /// Lines trimmed from history are gone; the rest of the range still comes out.
    @Test func trimmedLinesContributeNothing() {
        let t = terminal((1...40).map(String.init).joined(separator: "\r\n"), scrollback: 1_500)
        let firstKept = t.linesScrolledOff - UInt64(t.scrollbackCount)
        #expect(firstKept > 0)
        #expect(t.line(firstKept - 1) == nil)
        #expect(text(t, (0, 0), (firstKept, 9)) == "\(firstKept + 1)")
    }

    @Test func rangesAndColumns() {
        let range = TextRegion(TextPoint(line: 5, column: 7), TextPoint(line: 3, column: 2))
        #expect(range.start == TextPoint(line: 3, column: 2))
        #expect(range.columns(on: 3, width: 10) == 2...9)
        #expect(range.columns(on: 4, width: 10) == 0...9)
        #expect(range.columns(on: 5, width: 10) == 0...7)
        #expect(range.columns(on: 6, width: 10) == nil)
        #expect(range.contains(TextPoint(line: 4, column: 0)))
        #expect(!range.contains(TextPoint(line: 3, column: 1)))
        let rectangle = TextRegion(TextPoint(line: 5, column: 7), TextPoint(line: 3, column: 2), rectangular: true)
        #expect(rectangle.start == TextPoint(line: 3, column: 2))
        #expect(rectangle.end == TextPoint(line: 5, column: 7))
        #expect(rectangle.columns(on: 4, width: 10) == 2...7)
        #expect(!rectangle.contains(TextPoint(line: 4, column: 8)))
    }

    @Test func theMirrorAnswersOnlyForWhatIsInView() throws {
        let t = terminal((1...9).map(String.init).joined(separator: "\r\n"))
        var builder = DeltaBuilder()
        var mirror = MirrorGrid()
        try mirror.apply(builder.makeDelta(from: t, events: []))
        #expect(mirror.viewportTopLine == 5)
        #expect(
            mirror.text(in: TextRegion(TextPoint(line: 5, column: 0), TextPoint(line: 8, column: 9))) == "6\n7\n8\n9")
        #expect(mirror.text(in: TextRegion(TextPoint(line: 4, column: 0), TextPoint(line: 8, column: 9))) == nil)
        #expect(mirror.line(5).map { TextExtractor.text(of: $0, columns: 0...9) } == "6         ")
    }
}
