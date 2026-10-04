import Testing

@testable import VTCore

@Suite struct TerminalCursorTests {
    @Test func cursorPositionIsOneBasedAndClamped() {
        let t = makeTerminal()
        t.feed("\u{1B}[3;4H")
        #expect(t.cursorPosition == [3, 2])
        t.feed("\u{1B}[H")
        #expect(t.cursorPosition == [0, 0])
        t.feed("\u{1B}[99;99H")
        #expect(t.cursorPosition == [9, 4])
        t.feed("\u{1B}[0;0f")
        #expect(t.cursorPosition == [0, 0])
    }

    @Test func relativeMovesTreatZeroAsOne() {
        let t = makeTerminal()
        t.feed("\u{1B}[3;3H\u{1B}[0A")
        #expect(t.cursorPosition == [2, 1])
        t.feed("\u{1B}[2B\u{1B}[C")
        #expect(t.cursorPosition == [3, 3])
        t.feed("\u{1B}[10D\u{1B}[99B")
        #expect(t.cursorPosition == [0, 4])
    }

    @Test func verticalMovesStopAtTheMargins() {
        let t = makeTerminal()
        t.feed("\u{1B}[2;4r\u{1B}[3;1H\u{1B}[9A")
        #expect(t.cursor.y == 1)
        t.feed("\u{1B}[9B")
        #expect(t.cursor.y == 3)
        // Below the region the bottom of the screen is the limit; going up stops at the top margin.
        t.feed("\u{1B}[5;1H\u{1B}[9B")
        #expect(t.cursor.y == 4)
        t.feed("\u{1B}[9A")
        #expect(t.cursor.y == 1)
        // Above the region, the top of the screen.
        t.feed("\u{1B}[1;1H\u{1B}[A")
        #expect(t.cursor.y == 0)
    }

    @Test func originModeAddressesTheScrollRegion() {
        let t = makeTerminal()
        t.feed("\u{1B}[2;4r\u{1B}[?6h")
        #expect(t.cursorPosition == [0, 1])
        t.feed("\u{1B}[99;1H")
        #expect(t.cursor.y == 3)
        t.feed("\u{1B}[6n")
        #expect(t.takeReplyString() == "\u{1B}[3;1R")
        t.feed("\u{1B}[?6l")
        #expect(t.cursorPosition == [0, 0])
    }

    @Test func columnAndLineAddressing() {
        let t = makeTerminal()
        t.feed("\u{1B}[5G")
        #expect(t.cursor.x == 4)
        t.feed("\u{1B}[7`")
        #expect(t.cursor.x == 6)
        t.feed("\u{1B}[3d")
        #expect(t.cursor.y == 2)
        t.feed("\u{1B}[2a")
        #expect(t.cursor.x == 8)
        t.feed("\u{1B}[e")
        #expect(t.cursor.y == 3)
        t.feed("\u{1B}[E")
        #expect(t.cursorPosition == [0, 4])
        t.feed("\u{1B}[5G\u{1B}[2F")
        #expect(t.cursorPosition == [0, 2])
    }

    @Test func hugeTabCountsStopAtTheMargins() {
        let t = makeTerminal(columns: 20)
        t.feed("\u{1B}[65535I")
        #expect(t.cursor.x == 19)
        t.feed("\u{1B}[65535Z")
        #expect(t.cursor.x == 0)
    }

    @Test func tabStopsCanBeSetClearedAndTraversed() {
        let t = makeTerminal(columns: 20)
        t.feed("\u{1B}[2I")
        #expect(t.cursor.x == 16)
        t.feed("\u{1B}[Z")
        #expect(t.cursor.x == 8)
        t.feed("\u{1B}[3Z")
        #expect(t.cursor.x == 0)
        t.feed("\u{1B}[4G\u{1B}H\r\t")
        #expect(t.cursor.x == 3)
        t.feed("\u{1B}[g\r\t")
        #expect(t.cursor.x == 8)
        t.feed("\u{1B}[3g\r\t")
        #expect(t.cursor.x == 19)
    }

    @Test func saveAndRestoreCursorKeepPositionPenAndCharsets() {
        let t = makeTerminal()
        t.feed("\u{1B}[2;3H\u{1B}[1;31m\u{1B}(0\u{1B}7")
        t.feed("\u{1B}[H\u{1B}[0m\u{1B}(B\u{1B}8")
        #expect(t.cursorPosition == [2, 1])
        #expect(t.currentStyle == Style(foreground: .indexed(1), attributes: .bold))
        t.feed("q")
        #expect(t.lines[1] == "  ─")
    }

    @Test func saveAndRestoreCursorKeepOriginMode() {
        let t = makeTerminal()
        t.feed("\u{1B}[2;4r\u{1B}[?6h\u{1B}7\u{1B}[?6l\u{1B}8")
        #expect(t.modes.origin)
    }

    @Test func restoreWithoutSaveHomesTheCursor() {
        let t = makeTerminal()
        t.feed("\u{1B}[3;3H\u{1B}[1m\u{1B}8")
        #expect(t.cursorPosition == [0, 0])
        #expect(t.currentStyle == .default)
    }

    @Test func backspaceStopsAtTheLeftEdge() {
        let t = makeTerminal()
        t.feed("\u{8}X")
        #expect(t.lines[0] == "X")
    }

    @Test func backspaceLeavesTheLastColumnWhenAWrapIsPending() {
        let t = makeTerminal()
        t.feed("abcdefghij\u{8}X")
        #expect(t.lines[0] == "abcdefghXj")
        #expect(t.lines[1] == "")
    }

    @Test func reverseWraparoundBacksUpIntoTheWrappedLine() {
        let t = makeTerminal()
        t.feed("abcdefghijk\u{1B}[?45h\u{8}\u{8}Z")
        #expect(t.lines[0] == "abcdefghiZ")
        // A line that ended with a newline is not crossed.
        let hard = makeTerminal()
        hard.feed("abc\r\n\u{1B}[?45h\u{8}")
        #expect(hard.cursorPosition == [0, 1])
    }

    @Test func reverseWraparoundSpendsOneBackspaceOnAPendingWrap() {
        let t = makeTerminal()
        t.feed("\u{1B}[?45habcdefghij\u{8}")
        #expect(t.cursorPosition == [9, 0])
        #expect(!t.cursor.pendingWrap)
    }

    @Test func extendedReverseWraparoundCrossesAnyLineAndTheTop() {
        let t = makeTerminal()
        t.feed("abc\r\n\u{1B}[?1045h\u{8}")
        #expect(t.cursorPosition == [9, 0])
        t.feed("\u{1B}[2;4r\u{1B}[2;1H\u{8}")
        #expect(t.cursorPosition == [9, 3])
        // Without autowrap, nothing wraps.
        t.feed("\u{1B}[?7l\u{1B}[3;1H\u{8}")
        #expect(t.cursorPosition == [0, 2])
    }

    @Test func cursorBackwardWrapsLikeBackspace() {
        let t = makeTerminal()
        t.feed("abcdefghijklm\u{1B}[?45h\u{1B}[5D")
        #expect(t.cursorPosition == [8, 0])
        t.feed("\u{1B}[99D")
        #expect(t.cursorPosition == [0, 0])
    }

    @Test func indexAndReverseIndex() {
        let t = makeTerminal(rows: 3)
        t.feed("1\r\n2\r\n3\u{1B}[1;1H\u{1B}M")
        #expect(t.lines == ["", "1", "2"])
        t.feed("\u{1B}[3;1H\u{1B}D")
        #expect(t.lines == ["1", "2", ""])
        t.feed("\u{1B}[2;5H\u{1B}E")
        #expect(t.cursorPosition == [0, 2])
    }
}
