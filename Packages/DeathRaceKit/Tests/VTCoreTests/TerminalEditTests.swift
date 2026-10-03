import Testing

@testable import VTCore

/// Erasing, inserting, deleting and scrolling.
@Suite struct TerminalEditTests {
    /// A terminal with `aaaa`, `bbbb`… on its five rows.
    private func lettered(columns: Int = 10) -> Terminal {
        let t = makeTerminal(columns: columns)
        t.feed("\u{1B}[1;1Haaaa\u{1B}[2;1Hbbbb\u{1B}[3;1Hcccc\u{1B}[4;1Hdddd\u{1B}[5;1Heeee")
        return t
    }

    // MARK: Erase

    @Test func eraseInLine() {
        let t = makeTerminal()
        t.feed("abcdefghij\u{1B}[1;4H\u{1B}[K")
        #expect(t.lines[0] == "abc")
        t.feed("\r\u{1B}[2Cxyz\u{1B}[1;3H\u{1B}[1K")
        #expect(t.lines[0] == "   yz")
        t.feed("\u{1B}[2K")
        #expect(t.lines[0] == "")
    }

    @Test func eraseInLineClearsThePendingWrapAndTheWrapFlag() {
        let t = makeTerminal()
        t.feed("abcdefghijk\u{1B}[1;5H\u{1B}[K")
        #expect(!t.row(0).isWrapped)
        #expect(!t.cursor.pendingWrap)
    }

    @Test func eraseInDisplayBelowAndAbove() {
        let below = lettered()
        below.feed("\u{1B}[3;3H\u{1B}[J")
        #expect(below.lines == ["aaaa", "bbbb", "cc", "", ""])

        let above = lettered()
        above.feed("\u{1B}[3;3H\u{1B}[1J")
        #expect(above.lines == ["", "", "   c", "dddd", "eeee"])
        #expect(above.cursorPosition == [2, 2])
    }

    @Test func eraseInDisplayAllKeepsTheCursorAndScrollback() {
        let t = makeTerminal(rows: 2)
        t.feed("1\r\n2\r\n3\u{1B}[2J")
        #expect(t.lines == ["", ""])
        #expect(t.cursorPosition == [1, 1])
        #expect(t.scrollbackLines == ["1"])
        t.feed("\u{1B}[3J")
        #expect(t.scrollbackCount == 0)
    }

    @Test func eraseCharacters() {
        let t = makeTerminal()
        t.feed("abcdef\u{1B}[1;2H\u{1B}[3X")
        #expect(t.lines[0] == "a   ef")
        #expect(t.cursorPosition == [1, 0])
        t.feed("\u{1B}[99X")
        #expect(t.lines[0] == "a")
    }

    @Test func erasedCellsTakeTheBackgroundColorOnly() {
        let t = makeTerminal()
        t.feed("\u{1B}[1;31;44m\u{1B}[2J")
        #expect(t.style(x: 0, y: 0) == Style(background: .indexed(4)))
        #expect(t.style(x: 9, y: 4) == Style(background: .indexed(4)))
        t.feed("\u{1B}[0;32m\u{1B}[K")
        #expect(t.style(x: 0, y: 0) == .default)
    }

    @Test func erasingHalfAWideCharacterErasesAllOfIt() {
        let t = makeTerminal()
        t.feed("中文\u{1B}[1;2H\u{1B}[K")
        #expect(t.lines[0] == "")
        let u = makeTerminal()
        u.feed("中文\u{1B}[1;3H\u{1B}[X")
        #expect(u.lines[0] == "中")
        #expect(u.row(0).cells[3].width == .narrow)
    }

    @Test func selectiveEraseSparesProtectedCharacters() {
        let t = makeTerminal()
        t.feed("\u{1B}[1\"qAB\u{1B}[0\"qCD\u{1B}[?2K")
        #expect(t.lines[0] == "AB")
        t.feed("\u{1B}[?2J")
        #expect(t.lines[0] == "AB")
        // Plain erases ignore protection.
        t.feed("\u{1B}[2K")
        #expect(t.lines[0] == "")
    }

    // MARK: Insert and delete

    @Test func insertCharacters() {
        let t = makeTerminal()
        t.feed("abcdef\u{1B}[1;2H\u{1B}[2@")
        #expect(t.lines[0] == "a  bcdef")
        t.feed("\u{1B}[1;1Habcdefghij\u{1B}[1;2H\u{1B}[2@")
        #expect(t.lines[0] == "a  bcdefgh")
    }

    @Test func deleteCharacters() {
        let t = makeTerminal()
        t.feed("abcdef\u{1B}[1;2H\u{1B}[2P")
        #expect(t.lines[0] == "adef")
        t.feed("\u{1B}[99P")
        #expect(t.lines[0] == "a")
    }

    @Test func insertAndDeleteMoveMarksWithTheirCharacters() {
        let t = makeTerminal()
        t.feed("ae\u{301}\u{1B}[1;1H\u{1B}[2@")
        #expect(t.row(0).scalars(at: 3) == [0x65, 0x301])
        t.feed("\u{1B}[3P")
        #expect(t.row(0).scalars(at: 0) == [0x65, 0x301])
        #expect(t.row(0).graphemes.count == 1)
    }

    @Test func insertAndDeleteLines() {
        let t = lettered()
        t.feed("\u{1B}[2;3H\u{1B}[L")
        #expect(t.lines == ["aaaa", "", "bbbb", "cccc", "dddd"])
        #expect(t.cursorPosition == [0, 1])
        t.feed("\u{1B}[2M")
        #expect(t.lines == ["aaaa", "cccc", "dddd", "", ""])
    }

    @Test func insertAndDeleteLinesStayInsideTheScrollRegion() {
        let t = lettered()
        t.feed("\u{1B}[2;4r\u{1B}[2;1H\u{1B}[L")
        #expect(t.lines == ["aaaa", "", "bbbb", "cccc", "eeee"])
        t.feed("\u{1B}[M")
        #expect(t.lines == ["aaaa", "bbbb", "cccc", "", "eeee"])
        // Outside the region, nothing happens.
        t.feed("\u{1B}[5;1H\u{1B}[L")
        #expect(t.lines == ["aaaa", "bbbb", "cccc", "", "eeee"])
    }

    // MARK: Scrolling

    @Test func lineFeedScrollsOnlyTheRegion() {
        let t = lettered()
        t.feed("\u{1B}[2;4r\u{1B}[4;1H\n")
        #expect(t.lines == ["aaaa", "cccc", "dddd", "", "eeee"])
        #expect(t.scrollbackCount == 0)
    }

    @Test func regionAtTheTopScrollsIntoScrollback() {
        let t = lettered()
        t.feed("\u{1B}[1;3r\u{1B}[3;1H\n")
        #expect(t.lines == ["bbbb", "cccc", "", "dddd", "eeee"])
        #expect(t.scrollbackLines == ["aaaa"])
    }

    @Test func scrollUpAndDown() {
        let t = lettered()
        t.feed("\u{1B}[2S")
        #expect(t.lines == ["cccc", "dddd", "eeee", "", ""])
        #expect(t.scrollbackLines == ["aaaa", "bbbb"])
        t.feed("\u{1B}[T")
        #expect(t.lines == ["", "cccc", "dddd", "eeee", ""])
    }

    @Test func scrollDownWithFiveParametersIsNotAScroll() {
        let t = lettered()
        t.feed("\u{1B}[1;2;3;4;5T")
        #expect(t.lines == ["aaaa", "bbbb", "cccc", "dddd", "eeee"])
    }

    @Test func invalidScrollRegionsAreIgnored() {
        let t = makeTerminal()
        t.feed("\u{1B}[2;4r\u{1B}[4;2r")
        #expect(t.scrollRegion == 1...3)
        t.feed("\u{1B}[3;3r")
        #expect(t.scrollRegion == 1...3)
        t.feed("\u{1B}[r")
        #expect(t.scrollRegion == 0...4)
    }

    @Test func scrollbackKeepsToItsBudget() {
        // A ten-column row costs a little under 200 bytes; this budget holds three.
        let t = makeTerminal(rows: 2) { $0.scrollbackLimitBytes = 600 }
        for line in 0..<10 { t.feed("\(line)\r\n") }
        #expect(t.scrollbackLines == ["6", "7", "8"])
        #expect(t.lines == ["9", ""])
    }

    @Test func theAlternateScreenHasNoScrollback() {
        let t = makeTerminal(rows: 2)
        t.feed("\u{1B}[?1049h1\r\n2\r\n3")
        #expect(t.lines == ["2", "3"])
        #expect(t.scrollbackCount == 0)
    }

    @Test func screenAlignmentFillsWithE() {
        let t = makeTerminal(columns: 3, rows: 3)
        t.feed("\u{1B}[2;3r\u{1B}#8")
        #expect(t.lines == ["EEE", "EEE", "EEE"])
        #expect(t.scrollRegion == 0...2)
        #expect(t.cursorPosition == [0, 0])
    }
}
