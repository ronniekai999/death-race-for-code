import Testing

@testable import VTCore

/// The left and right margins (DECSLRM) and the mode that turns them on (DECLRMM, 69).
/// What the margins *do* to printing, scrolling and the cursor is tested beside those.
@Suite struct TerminalMarginTests {
    @Test func theMarginsStartAtTheWholeScreenWithTheirModeOff() {
        let t = makeTerminal()
        #expect(t.columnMargins == 0...9)
        #expect(!t.modes.leftRightMargins)
    }

    @Test func decslrmDoesNothingUntilItsModeIsOn() {
        let t = makeTerminal()
        t.feed("\u{1B}[2;2H\u{1B}[3;6s")
        #expect(t.columnMargins == 0...9)
        #expect(t.cursorPosition == [1, 1])
    }

    @Test func decslrmSetsTheMarginsAndHomesTheCursor() {
        let t = makeTerminal()
        t.feed("\u{1B}[?69h\u{1B}[3;4H\u{1B}[3;6s")
        #expect(t.columnMargins == 2...5)
        #expect(t.cursorPosition == [0, 0])
    }

    /// xterm's rule: the right margin counts only when it is further right than the left, so
    /// one parameter, or a pair the wrong way round, runs to the last column.
    @Test func aRightMarginThatIsNotToTheRightMeansTheScreensEdge() {
        let t = makeTerminal()
        t.feed("\u{1B}[?69h\u{1B}[5s")
        #expect(t.columnMargins == 4...9)
        t.feed("\u{1B}[6;3s")
        #expect(t.columnMargins == 5...9)
    }

    @Test func marginsNarrowerThanTwoColumnsAreLeftAlone() {
        let t = makeTerminal()
        t.feed("\u{1B}[?69h\u{1B}[3;6s\u{1B}[10;10s")
        #expect(t.columnMargins == 2...5)
    }

    @Test func aMarginPastTheLastColumnStopsThere() {
        let t = makeTerminal()
        t.feed("\u{1B}[?69h\u{1B}[3;99s")
        #expect(t.columnMargins == 2...9)
    }

    @Test func withTheModeOnAnEmptyCSIsIsNoLongerACursorSave() {
        let t = makeTerminal()
        t.feed("\u{1B}[?69h\u{1B}[3;6s\u{1B}[4;5H\u{1B}[s")
        #expect(t.columnMargins == 0...9, "CSI s with the mode on is DECSLRM with its defaults")
        #expect(t.cursorPosition == [0, 0])
    }

    @Test func withTheModeOffAnEmptyCSIsStillSavesTheCursor() {
        let t = makeTerminal()
        t.feed("\u{1B}[4;5H\u{1B}[s\u{1B}[1;1H\u{1B}[u")
        #expect(t.cursorPosition == [4, 3])
    }

    @Test func turningTheModeOffPutsTheMarginsBack() {
        let t = makeTerminal()
        t.feed("\u{1B}[?69h\u{1B}[3;6s\u{1B}[?69l")
        #expect(t.columnMargins == 0...9)
        #expect(!t.modes.leftRightMargins)
    }

    @Test func theModeTravelsWithTheOtherPrivateModesThroughXTSAVE() {
        let t = makeTerminal()
        t.feed("\u{1B}[?69h\u{1B}[?69s\u{1B}[?69l")
        #expect(!t.modes.leftRightMargins)
        t.feed("\u{1B}[?69r")
        #expect(t.modes.leftRightMargins)
    }

    @Test func decrqmAnswersForTheMode() {
        let t = makeTerminal()
        t.feed("\u{1B}[?69$p")
        #expect(t.takeReplyString() == "\u{1B}[?69;2$y")
        t.feed("\u{1B}[?69h\u{1B}[?69$p")
        #expect(t.takeReplyString() == "\u{1B}[?69;1$y")
    }

    @Test func decrqssReportsTheMargins() {
        let t = makeTerminal()
        t.feed("\u{1B}[?69h\u{1B}[3;6s")
        _ = t.takeReplies()
        t.feed("\u{1B}P$qs\u{1B}\\")
        #expect(t.takeReplyString() == "\u{1B}P1$r3;6s\u{1B}\\")
        t.feed("\u{1B}[?69l\u{1B}P$qs\u{1B}\\")
        #expect(t.takeReplyString() == "\u{1B}P1$r1;10s\u{1B}\\", "the margins are the full width again")
    }

    @Test func aSoftResetPutsBackTheMarginsAndTheirMode() {
        let t = makeTerminal()
        t.feed("\u{1B}[?69h\u{1B}[3;6s\u{1B}[!p")
        #expect(t.columnMargins == 0...9)
        #expect(!t.modes.leftRightMargins)
    }

    @Test func everyOtherResetPutsTheMarginsBack() {
        // RIS, DECALN, and DECCOLM once a program has allowed the switch.
        for reset in ["\u{1B}c", "\u{1B}#8", "\u{1B}[?40h\u{1B}[?3h"] {
            let t = makeTerminal()
            t.feed("\u{1B}[?69h\u{1B}[3;6s" + reset)
            #expect(t.columnMargins == 0...9, "\(reset.debugDescription) left the margins behind")
        }
    }

    @Test func aResizePutsTheMarginsBack() {
        let t = makeTerminal()
        t.feed("\u{1B}[?69h\u{1B}[3;6s")
        t.resize(columns: 20, rows: 5)
        #expect(t.columnMargins == 0...19)
    }

    @Test func eachScreenHasItsOwnMargins() {
        let t = makeTerminal()
        t.feed("\u{1B}[?69h\u{1B}[3;6s\u{1B}[?1049h")
        #expect(t.columnMargins == 0...9, "the alternate screen starts at its full width")
        t.feed("\u{1B}[2;5s")
        #expect(t.columnMargins == 1...4)
        t.feed("\u{1B}[?1049l")
        #expect(t.columnMargins == 2...5, "the primary screen kept its own")
    }
}
