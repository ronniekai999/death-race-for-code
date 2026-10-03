import Testing

@testable import VTCore

@Suite struct TerminalResizeTests {
    @Test func narrowingWrapsLongLines() {
        let t = makeTerminal()
        t.feed("abcdefghijklm")
        t.resize(columns: 5, rows: 5)
        #expect(t.lines == ["abcde", "fghij", "klm", "", ""])
        #expect(t.row(0).isWrapped && t.row(1).isWrapped && !t.row(2).isWrapped)
        #expect(t.cursorPosition == [3, 2])
    }

    @Test func wideningJoinsWrappedLines() {
        let t = makeTerminal(columns: 5)
        t.feed("abcdefghijklm")
        t.resize(columns: 10, rows: 5)
        #expect(t.lines == ["abcdefghij", "klm", "", "", ""])
        #expect(t.cursorPosition == [3, 1])
        t.resize(columns: 20, rows: 5)
        #expect(t.lines[0] == "abcdefghijklm")
        #expect(!t.row(0).isWrapped)
    }

    @Test func hardLineBreaksStay() {
        let t = makeTerminal()
        t.feed("abc\r\ndef")
        t.resize(columns: 20, rows: 5)
        #expect(t.lines == ["abc", "def", "", "", ""])
        t.resize(columns: 2, rows: 5)
        #expect(t.lines == ["ab", "c", "de", "f", ""])
    }

    @Test func wideCharactersMoveWholeAcrossTheEdge() {
        let t = makeTerminal(columns: 6)
        t.feed("abcd中")
        t.resize(columns: 5, rows: 5)
        #expect(t.lines[0] == "abcd")
        #expect(t.row(0).cells[4].width == .spacerHead)
        #expect(t.lines[1] == "中")
        #expect(t.cursorPosition == [2, 1])
        t.resize(columns: 6, rows: 5)
        #expect(t.lines[0] == "abcd中")
        #expect(t.lines[1] == "")
        #expect(t.cursorPosition == [6 - 1, 0])
        #expect(t.cursor.pendingWrap)
    }

    @Test func theCursorKeepsItsPlaceInsideALine() {
        let t = makeTerminal()
        t.feed("abcdefghijklm\u{1B}[2;3H")
        #expect(t.cursorPosition == [2, 1])
        t.resize(columns: 5, rows: 5)
        #expect(t.cursorPosition == [2, 2])
        // The cursor is on the "m", so typing replaces it.
        t.feed("X")
        #expect(t.lines[2] == "klX")
    }

    @Test func aPendingWrapSurvives() {
        let t = makeTerminal()
        t.feed("abcdefghij")
        t.resize(columns: 5, rows: 5)
        #expect(t.lines == ["abcde", "fghij", "", "", ""])
        #expect(t.cursorPosition == [4, 1])
        #expect(t.cursor.pendingWrap)
        t.feed("X")
        #expect(t.lines[2] == "X")
        t.resize(columns: 20, rows: 5)
        #expect(t.lines[0] == "abcdefghijX")
        #expect(t.cursorPosition == [11, 0])
    }

    @Test func aCursorPastTheTextKeepsItsColumn() {
        let t = makeTerminal()
        t.feed("ab\u{1B}[8G")
        t.resize(columns: 20, rows: 5)
        #expect(t.cursorPosition == [7, 0])
        t.resize(columns: 4, rows: 5)
        #expect(t.cursorPosition == [3, 1])
    }

    @Test func scrollbackReflowsToo() {
        let t = makeTerminal(rows: 2)
        t.feed("abcdefghijklmno\r\n1\r\n2")
        #expect(t.scrollbackLines == ["abcdefghij", "klmno"])
        t.resize(columns: 20, rows: 2)
        #expect(t.scrollbackLines == ["abcdefghijklmno"])
        #expect(t.lines == ["1", "2"])
    }

    @Test func shrinkingRowsScrollsTheTopIntoScrollback() {
        let t = makeTerminal()
        t.feed("1\r\n2\r\n3\r\n4\r\n5")
        t.resize(columns: 10, rows: 3)
        #expect(t.lines == ["3", "4", "5"])
        #expect(t.scrollbackLines == ["1", "2"])
        #expect(t.cursorPosition == [1, 2])
        // Growing again brings the lines back down.
        t.resize(columns: 10, rows: 5)
        #expect(t.lines == ["1", "2", "3", "4", "5"])
        #expect(t.scrollbackCount == 0)
        #expect(t.cursorPosition == [1, 4])
    }

    @Test func shrinkingRowsDropsBlankLinesBelowTheCursorFirst() {
        let t = makeTerminal()
        t.feed("1\r\n2")
        t.resize(columns: 10, rows: 3)
        #expect(t.lines == ["1", "2", ""])
        #expect(t.scrollbackCount == 0)
    }

    @Test func growingAfterAClearKeepsTheScrollbackOutOfView() {
        let t = makeTerminal(rows: 3)
        t.feed("1\r\n2\r\n3\r\n4\u{1B}[H\u{1B}[2J$ ")
        #expect(t.scrollbackLines == ["1"])
        t.resize(columns: 10, rows: 5)
        #expect(t.lines == ["$", "", "", "", ""])
        #expect(t.scrollbackLines == ["1"])
        #expect(t.cursorPosition == [2, 0])
    }

    @Test func narrowingDoesNotPushOutputAwayForBlankLines() {
        let t = makeTerminal()
        t.feed("abcdefghijkl")
        t.resize(columns: 4, rows: 5)
        #expect(t.lines == ["abcd", "efgh", "ijkl", "", ""])
        #expect(t.scrollbackCount == 0)
    }

    @Test func theAlternateScreenIsCroppedNotReflowed() {
        let t = makeTerminal()
        t.feed("abcdefghijklm\u{1B}[?1049h\u{1B}[H0123456789")
        t.resize(columns: 5, rows: 5)
        #expect(t.lines[0] == "01234")
        #expect(t.lines[1] == "")
        t.feed("\u{1B}[?1049l")
        #expect(t.lines == ["abcde", "fghij", "klm", "", ""])
    }

    @Test func stylesMarksAndGraphemesSurvive() {
        let t = makeTerminal(columns: 4)
        t.feed("\u{1B}]133;A\u{7}\u{1B}[31mab\u{1B}[0mce\u{301}\u{1B}[44mfg")
        t.resize(columns: 3, rows: 5)
        #expect(t.lines[0] == "abc")
        #expect(t.lines[1] == "e\u{301}fg")
        #expect(t.style(x: 0, y: 0) == Style(foreground: .indexed(1)))
        #expect(t.style(x: 2, y: 0) == .default)
        #expect(t.row(1).scalars(at: 0) == [0x65, 0x301])
        #expect(t.style(x: 2, y: 1) == Style(background: .indexed(4)))
        #expect(t.row(0).promptMarks == .promptStart)
        #expect(t.row(1).promptMarks.isEmpty)
    }

    @Test func resizingBumpsTheGenerationOnlyWhenTheSizeChanges() {
        let t = makeTerminal()
        let generation = t.generation
        t.resize(columns: 10, rows: 5)
        #expect(t.generation == generation)
        t.resize(columns: 12, rows: 5)
        #expect(t.generation == generation + 1)
        #expect(t.columns == 12)
        #expect(t.configuration.columns == 12)
    }

    @Test func scrollRegionAndMarginsResetOnResize() {
        let t = makeTerminal()
        t.feed("\u{1B}[2;4r")
        t.resize(columns: 10, rows: 8)
        #expect(t.scrollRegion == 0...7)
    }

    @Test func resizingAnEmptyScreenAndToOneColumn() {
        let t = makeTerminal()
        t.resize(columns: 3, rows: 2)
        #expect(t.cursorPosition == [0, 0])
        t.feed("中x")
        t.resize(columns: 1, rows: 4)
        #expect(t.columns == 1)
        #expect(t.lines.count == 4)
    }

    @Test func reflowIsStableAcrossRoundTrips() {
        let t = makeTerminal(columns: 7, rows: 4)
        let text = "The quick brown fox jumps over the lazy dog 中文 👍🏽 done"
        t.feed(text)
        let before = t.scrollbackLines + t.lines
        for columns in [3, 11, 5, 23, 7] { t.resize(columns: columns, rows: 4) }
        #expect(t.scrollbackLines + t.lines == before)
    }
}
