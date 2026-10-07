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

    /// An omitted right margin means the screen's last column. A pair that is inside out is
    /// ignored rather than guessed at — DEC STD 070's rule, and the one DECSTBM already
    /// follows — so a program that miscomputes its margins does not silently acquire one.
    @Test func anOmittedRightMarginMeansTheEdgeAndAnInsideOutPairIsIgnored() {
        let t = makeTerminal()
        t.feed("\u{1B}[?69h\u{1B}[5s")
        #expect(t.columnMargins == 4...9)
        t.feed("\u{1B}[2;8H\u{1B}[6;3s")
        #expect(t.columnMargins == 4...9, "the inside-out pair changed nothing")
        #expect(t.cursorPosition == [7, 1], "not even the cursor")
    }

    @Test func turningTheModeOffPutsBothScreensMarginsBack() {
        let t = makeTerminal()
        t.feed("\u{1B}[?69h\u{1B}[3;8s\u{1B}[?1049h\u{1B}[?69l\u{1B}[?1049l")
        #expect(t.columnMargins == 0...9, "the screen that was not in front gets them back too")
        #expect(!t.modes.leftRightMargins)
    }

    @Test func aSoftResetPutsBothScreensMarginsBack() {
        let t = makeTerminal()
        t.feed("\u{1B}[?69h\u{1B}[3;8s\u{1B}[?1049h\u{1B}[!p\u{1B}[?1049l")
        #expect(t.columnMargins == 0...9)
    }

    @Test func aPendingWrapSavedAtTheRightMarginComesBack() {
        let t = makeTerminal(columns: 10, rows: 3)
        t.feed("\u{1B}[?69h\u{1B}[2;5s\u{1B}[1;2Habcd")
        #expect(t.cursorPosition == [4, 0])
        t.feed("\u{1B}7\u{1B}[2;1H\u{1B}8Z")
        #expect(t.lines[0] == " abcd", "the Z wrapped rather than overwriting the margin")
        #expect(t.lines[1] == " Z")
    }

    @Test func reverseWrapTakesTheLeftMarginItLandsIn() {
        let t = makeTerminal(columns: 12, rows: 3)
        // Mode 1045 wraps whatever the line above looks like; the margins are columns 4 to 10.
        t.feed("\u{1B}[?7h\u{1B}[?1045h\u{1B}[?69h\u{1B}[4;10s\u{1B}[3;1H\u{1B}[11D")
        #expect(
            t.cursorPosition == [6, 0],
            "from the screen's own edge it wraps to the right margin, and the left margin is the stop after that")
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

/// What the margins do to printing, scrolling, editing and the cursor. esctest covers most of
/// this against xterm; the tests here pin what it cannot see — scrollback, styles, links and
/// graphemes — and give each rule a name.
@Suite struct TerminalMarginScrollTests {
    /// Fills a 5-column screen with five rows of letters and sets margins over columns 2...4,
    /// which is the shape esctest's own margin fixtures use.
    func fiveByFive(margins: String = "\u{1B}[2;4s") -> Terminal {
        let t = makeTerminal(columns: 5, rows: 5)
        for (row, line) in ["abcde", "fghij", "klmno", "pqrst", "uvwxy"].enumerated() {
            t.feed("\u{1B}[\(row + 1);1H" + line)
        }
        t.feed("\u{1B}[?69h" + margins)
        return t
    }

    @Test func printingWrapsAtTheRightMarginOntoTheLeftOne() {
        let t = makeTerminal(columns: 8, rows: 4)
        t.feed("\u{1B}[?69h\u{1B}[2;4sabcdefgh")
        #expect(t.lines == ["abcd", " efg", " h", ""], "the wrap lands on the left margin")
        #expect(t.cursorPosition == [2, 2])
    }

    @Test func withoutAutowrapPrintingPilesUpOnTheRightMargin() {
        let t = makeTerminal(columns: 8, rows: 2)
        t.feed("\u{1B}[?69h\u{1B}[2;4s\u{1B}[?7l\u{1B}[1;3Habcdef")
        #expect(t.lines[0] == "  af", "the last character overwrites the right margin")
        #expect(t.cursorPosition == [3, 0])
    }

    @Test func repeatingACharacterWrapsAtTheRightMarginToo() {
        let t = makeTerminal(columns: 5, rows: 3)
        t.feed("\u{1B}[?69h\u{1B}[2;4s\u{1B}[1;2Ha\u{1B}[3b")
        #expect(t.lines == [" aaa", " a", ""])
    }

    @Test func insertModeTruncatesAtTheRightMargin() {
        let t = makeTerminal(columns: 5, rows: 1)
        t.feed("abcde\u{1B}[?69h\u{1B}[2;4s\u{1B}[1;2H\u{1B}[4hZ")
        #expect(t.lines[0] == "aZbce", "the d is pushed off the right margin and the e stays put")
    }

    @Test func scrollingUpMovesOnlyTheCellsBetweenTheMargins() {
        let t = fiveByFive()
        t.feed("\u{1B}[2;3H\u{1B}[2S")
        #expect(t.lines == ["almne", "fqrsj", "kvwxo", "p   t", "u   y"])
    }

    @Test func scrollingDownMovesOnlyTheCellsBetweenTheMargins() {
        let t = fiveByFive()
        t.feed("\u{1B}[2;3H\u{1B}[2T")
        #expect(t.lines == ["a   e", "f   j", "kbcdo", "pghit", "ulmny"])
    }

    /// esctest cannot see scrollback, and this is the rule that keeps a partly-moved line out
    /// of it: a line that only partly moved is not a line that left the screen.
    @Test func aScrollBetweenMarginsReachesNoScrollback() {
        let t = fiveByFive()
        t.feed("\u{1B}[1;3H\u{1B}[9S")
        #expect(t.scrollbackCount == 0)
        #expect(t.linesScrolledOff == 0)
        #expect(t.lines == ["a   e", "f   j", "k   o", "p   t", "u   y"])
    }

    /// The same screen with the mode on but the margins left at the full width takes the
    /// whole-row path, scrollback and all — which is what makes `isFullWidthMargins` the only
    /// test the buffer needs.
    @Test func theFullWidthPathStillKeepsItsHistory() {
        let t = fiveByFive(margins: "\u{1B}[s")
        t.feed("\u{1B}[1;1H\u{1B}[2S")
        #expect(t.scrollbackLines == ["abcde", "fghij"])
        #expect(t.linesScrolledOff == 2)
    }

    @Test func insertingLinesPushesDownOnlyTheCellsBetweenTheMargins() {
        let t = fiveByFive()
        t.feed("\u{1B}[2;4r\u{1B}[2;3H\u{1B}[L")
        #expect(t.lines == ["abcde", "f   j", "kghio", "plmnt", "uvwxy"])
    }

    @Test func deletingLinesPullsUpOnlyTheCellsBetweenTheMargins() {
        let t = fiveByFive()
        t.feed("\u{1B}[2;3H\u{1B}[M")
        #expect(t.lines == ["abcde", "flmnj", "kqrso", "pvwxt", "u   y"])
    }

    @Test func lineEditingDoesNothingWhenTheCursorIsOutsideTheMargins() {
        for sequence in ["\u{1B}[L", "\u{1B}[M"] {
            let t = fiveByFive()
            t.feed("\u{1B}[2;1H" + sequence)
            #expect(
                t.lines == ["abcde", "fghij", "klmno", "pqrst", "uvwxy"],
                "\(sequence.debugDescription) moved cells")
        }
    }

    @Test func insertingCharactersDropsWhatPassesTheRightMargin() {
        let t = makeTerminal(columns: 8, rows: 1)
        t.feed("abcdefg\u{1B}[?69h\u{1B}[2;5s\u{1B}[1;3H\u{1B}[@")
        #expect(t.lines[0] == "ab cdfg", "the e is pushed off the margin and gone")
    }

    @Test func deletingCharactersPullsNothingInFromPastTheRightMargin() {
        let t = makeTerminal(columns: 5, rows: 1)
        t.feed("abcde\u{1B}[?69h\u{1B}[2;4s\u{1B}[1;3H\u{1B}[P")
        #expect(t.lines[0] == "abd e")
        t.feed("\u{1B}[1;3H\u{1B}[99P")
        #expect(t.lines[0] == "ab  e", "and it stops at the margin however much is asked for")
    }

    @Test func characterEditingDoesNothingWhenTheCursorIsOutsideTheMargins() {
        for sequence in ["\u{1B}[@", "\u{1B}[99P"] {
            let t = makeTerminal(columns: 5, rows: 1)
            t.feed("abcde\u{1B}[?69h\u{1B}[2;4s\u{1B}[1;1H" + sequence)
            #expect(t.lines[0] == "abcde", "\(sequence.debugDescription) moved cells")
        }
    }

    @Test func tabsStopAtTheRightMarginAndBackwardsTabsDoNot() {
        let t = makeTerminal(columns: 40, rows: 1)
        t.feed("\u{1B}[?69h\u{1B}[10;20s\u{1B}[1;1H\t")
        #expect(t.cursorPosition == [8, 0])
        t.feed("\t")
        #expect(t.cursorPosition == [16, 0])
        t.feed("\t\t")
        #expect(t.cursorPosition == [19, 0], "forward tabs stop at the right margin")
        t.feed("\u{1B}[2Z")
        #expect(t.cursorPosition == [8, 0], "backward tabs walk out of the margins")
    }

    @Test func theCursorStopsAtEachMargin() {
        let t = makeTerminal(columns: 20, rows: 2)
        t.feed("\u{1B}[?69h\u{1B}[5;10s\u{1B}[1;7H\u{1B}[99C")
        #expect(t.cursorPosition == [9, 0])
        t.feed("\u{1B}[99D")
        #expect(t.cursorPosition == [4, 0])
    }

    @Test func aCursorOutsideTheMarginsUsesTheScreensOwnEdges() {
        let t = makeTerminal(columns: 20, rows: 2)
        t.feed("\u{1B}[?69h\u{1B}[5;10s\u{1B}[1;15H\u{1B}[99C")
        #expect(t.cursorPosition == [19, 0], "right of the margin, the screen's edge is the stop")
        t.feed("\u{1B}[1;2H\u{1B}[99D")
        #expect(t.cursorPosition == [0, 0], "and left of it, column one")
    }

    @Test func carriageReturnGoesToTheLeftMargin() {
        let t = makeTerminal(columns: 20, rows: 2)
        t.feed("\u{1B}[?69h\u{1B}[5;10s\u{1B}[1;6H\r")
        #expect(t.cursorPosition == [4, 0])
        t.feed("\u{1B}[1;5H\r")
        #expect(t.cursorPosition == [4, 0], "and stays put when it is already there")
        t.feed("\u{1B}[1;3H\r")
        #expect(t.cursorPosition == [0, 0], "from left of the margin it is the screen's own edge")
        t.feed("\u{1B}[?6h\u{1B}[1;3H\r")
        #expect(t.cursorPosition == [4, 0], "except in origin mode, where the margin is the only line start")
    }

    @Test func indexScrollsOnlyForACursorBetweenTheMargins() {
        let t = fiveByFive()
        t.feed("\u{1B}[2;5r\u{1B}[5;1H\u{1B}D")
        #expect(t.lines == ["abcde", "fghij", "klmno", "pqrst", "uvwxy"], "nothing moved")
        #expect(t.cursorPosition == [0, 4], "and the cursor stayed on the bottom margin")
        t.feed("\u{1B}[5;3H\u{1B}D")
        #expect(t.lines == ["abcde", "flmnj", "kqrso", "pvwxt", "u   y"], "and scrolled from inside them")
    }

    @Test func reverseIndexScrollsOnlyForACursorBetweenTheMargins() {
        let t = fiveByFive()
        t.feed("\u{1B}[2;5r\u{1B}[2;1H\u{1B}M")
        #expect(t.lines == ["abcde", "fghij", "klmno", "pqrst", "uvwxy"], "nothing moved")
        #expect(t.cursorPosition == [0, 1], "and the cursor stayed on the top margin")
    }

    /// Printing one character at a time is a different path from printing a run of ASCII, and
    /// the margin has to bound both.
    @Test func aCharacterOffTheASCIIPathWrapsAtTheRightMarginToo() {
        let t = makeTerminal(columns: 6, rows: 3)
        t.feed("\u{1B}[?69h\u{1B}[2;4s\u{1B}[1;4H\u{E9}\u{E8}")
        #expect(t.lines == ["   \u{E9}", " \u{E8}", ""])
    }

    @Test func aTwoColumnCharacterTooWideForTheMarginWrapsWhole() {
        let t = makeTerminal(columns: 6, rows: 3)
        // Columns 3 and 4 are the last two inside the margin, so there it still fits.
        t.feed("\u{1B}[?69h\u{1B}[2;4s\u{1B}[1;3H\u{4E16}")
        #expect(t.row(0).cells[2].scalar == 0x4E16)
        t.feed("\u{1B}[1;4H\u{4E16}")
        #expect(t.row(0).cells[3].width == .spacerHead, "no room left before the margin: a spacer, then the wrap")
        #expect(t.row(1).cells[1].scalar == 0x4E16, "and the character itself starts at the left margin")
        // REP writes its repeats through a path of their own, with the same rule.
        t.feed("\u{1B}[2;4H\u{4E16}\u{1B}[1b")
        #expect(t.row(1).cells[3].width == .spacerHead)
        #expect(t.row(2).cells[1].scalar == 0x4E16)
    }

    @Test func repeatingATwoColumnCharacterStaysWholeAtTheRightMargin() {
        let t = makeTerminal(columns: 6, rows: 2)
        // With autowrap off there is nowhere to wrap to, so the repeats pile up on the last
        // two columns inside the margin rather than straddling it.
        t.feed("\u{1B}[?69h\u{1B}[2;4s\u{1B}[?7l\u{1B}[1;3H\u{4E16}\u{1B}[2b")
        #expect(t.row(0).cells[2].scalar == 0x4E16)
        #expect(t.row(0).cells[3].width == .spacerTail)
        #expect(t.cursorPosition == [3, 0])
    }

    @Test func reverseWrapGoesBackToTheRightMargin() {
        let t = makeTerminal(columns: 20, rows: 3)
        // Mode 1045 reverse-wraps whatever the line above looks like.
        t.feed("\u{1B}[?7h\u{1B}[?1045h\u{1B}[?69h\u{1B}[5;10s")
        t.feed("\u{1B}[3;5H\u{8}")
        #expect(t.cursorPosition == [9, 1], "from the left margin, back to the right margin a line up")
        t.feed("\u{1B}[3;1H\u{8}")
        #expect(t.cursorPosition == [9, 1], "and the same from the screen's own edge")
    }

    @Test func movingALineAtATimeLandsOnTheLeftMargin() {
        let t = makeTerminal(columns: 20, rows: 6)
        t.feed("\u{1B}[?69h\u{1B}[5;10s\u{1B}[2;4r\u{1B}[3;7H\u{1B}[99E")
        #expect(t.cursorPosition == [4, 3], "CNL stops at the bottom margin, on the left margin")
        t.feed("\u{1B}[3;7H\u{1B}[99F")
        #expect(t.cursorPosition == [4, 1], "and CPL at the top one")
    }

    /// A cell's style and its link are indexes into the table of the row that holds it, so a
    /// scroll that moves cells between rows has to look both up again. Nothing esctest checks
    /// can see either.
    @Test func aStyleAndALinkRideAlongWithTheCellsTheyBelongTo() {
        let t = makeTerminal(columns: 5, rows: 3)
        let open = "\u{1B}]8;;https://wrld.example/999\u{1B}\\"
        t.feed("\u{1B}[2;1H\u{1B}[1;32m" + open + "xyz" + "\u{1B}]8;;\u{1B}\\\u{1B}[0m")
        t.feed("\u{1B}[?69h\u{1B}[2;4s\u{1B}[1;3H\u{1B}[S")
        let row = t.row(0)
        #expect(row.text == " yz")
        #expect(t.style(x: 1, y: 0) == Style(foreground: .indexed(2), attributes: .bold))
        #expect(row.link(at: 1)?.uri == "https://wrld.example/999")
        #expect(row.link(at: 2)?.uri == "https://wrld.example/999")
        #expect(row.links.count == 1, "the link is registered once in the row it landed on")
    }

    @Test func aGraphemeRidesAlongToo() {
        let t = makeTerminal(columns: 5, rows: 3)
        t.feed("\u{1B}[2;2He\u{301}")
        t.feed("\u{1B}[?69h\u{1B}[2;4s\u{1B}[1;3H\u{1B}[S")
        #expect(t.row(0).text == " e\u{301}")
        #expect(t.row(0).graphemes[1] == [0x301])
    }

    @Test func aWideCharacterCutByAMarginLosesTheHalfThatMoved() {
        let t = makeTerminal(columns: 6, rows: 3)
        // 世 lands on columns 4 and 5, so the right margin cuts it in half.
        t.feed("\u{1B}[2;4H\u{4E16}")
        t.feed("\u{1B}[?69h\u{1B}[2;4s\u{1B}[1;3H\u{1B}[S")
        #expect(t.row(0).text == "", "the half that moved is blanked rather than drawn without the other")
        #expect(t.row(1).text == "", "and the margin blanked both halves of the character it cut")
        #expect(t.row(1).cells[4].width == .narrow, "so no spacer is left behind outside the margin")
    }
}

/// What rides on the margins: the column-editing sequences, which are defined in terms of
/// them, and origin mode's horizontal half.
@Suite struct TerminalColumnEditTests {
    /// The same five rows esctest's own fixtures use, with the scroll region over rows 2...4.
    func fiveByFive(_ setup: String) -> Terminal {
        let t = makeTerminal(columns: 5, rows: 5)
        for (row, line) in ["abcde", "fghij", "klmno", "pqrst", "uvwxy"].enumerated() {
            t.feed("\u{1B}[\(row + 1);1H" + line)
        }
        t.feed(setup)
        return t
    }

    @Test func decicPushesColumnsIntoEveryRowOfTheRegion() {
        let t = fiveByFive("\u{1B}[2;4r\u{1B}[2;2H")
        t.feed("\u{1B}[2'}")
        #expect(t.lines == ["abcde", "f  gh", "k  lm", "p  qr", "uvwxy"])
    }

    @Test func decdcPullsColumnsOutOfEveryRowOfTheRegion() {
        let t = fiveByFive("\u{1B}[2;4r\u{1B}[2;2H")
        t.feed("\u{1B}[2'~")
        #expect(t.lines == ["abcde", "fij", "kno", "pst", "uvwxy"])
    }

    @Test func columnEditingDoesNothingWhenTheCursorIsOutsideTheMargins() {
        for sequence in ["\u{1B}['}", "\u{1B}['~"] {
            let t = fiveByFive("\u{1B}[?69h\u{1B}[2;4s\u{1B}[2;1H")
            t.feed(sequence)
            #expect(
                t.lines == ["abcde", "fghij", "klmno", "pqrst", "uvwxy"],
                "\(sequence.debugDescription) moved cells")
        }
    }

    @Test func columnEditingDoesNothingWhenTheCursorIsOutsideTheScrollRegion() {
        let t = fiveByFive("\u{1B}[2;4r\u{1B}[1;2H")
        t.feed("\u{1B}['}")
        #expect(t.lines == ["abcde", "fghij", "klmno", "pqrst", "uvwxy"])
    }

    @Test func decbiMovesLeftUntilTheLeftMarginAndThenScrolls() {
        let t = fiveByFive("\u{1B}[?69h\u{1B}[2;4s\u{1B}[2;4r\u{1B}[2;3H")
        t.feed("\u{1B}6")
        #expect(t.cursorPosition == [1, 1], "inside the margins it is one column left")
        t.feed("\u{1B}6")
        #expect(t.cursorPosition == [1, 1], "on the left margin the cursor stays")
        #expect(t.lines == ["abcde", "f ghj", "k lmo", "p qrt", "uvwxy"], "and the text moves instead")
    }

    @Test func decfiMovesRightUntilTheRightMarginAndThenScrolls() {
        let t = fiveByFive("\u{1B}[?69h\u{1B}[2;4s\u{1B}[2;4r\u{1B}[2;4H")
        t.feed("\u{1B}9")
        #expect(t.cursorPosition == [3, 1], "on the right margin the cursor stays")
        #expect(t.lines == ["abcde", "fhi j", "kmn o", "prs t", "uvwxy"])
        t.feed("\u{1B}[2;5H\u{1B}9")
        #expect(t.cursorPosition == [4, 1], "and at the screen's own edge there is nowhere to go")
    }

    @Test func backIndexingOutsideTheMarginsStillMovesTheCursor() {
        let t = fiveByFive("\u{1B}[?69h\u{1B}[3;5s\u{1B}[2;2H")
        t.feed("\u{1B}6")
        #expect(t.cursorPosition == [0, 1], "DEC STD 070 lets it move outside the margins")
        t.feed("\u{1B}6")
        #expect(t.cursorPosition == [0, 1], "but the screen's own edge is the end of it")
        #expect(t.lines == ["abcde", "fghij", "klmno", "pqrst", "uvwxy"], "and nothing scrolled")
    }

    @Test func backIndexingAtTheScreensOwnEdgeHasNowhereToGo() {
        let t = fiveByFive("\u{1B}[?69h\u{1B}[2;4s\u{1B}[2;1H")
        t.feed("\u{1B}6")
        #expect(t.cursorPosition == [0, 1])
        #expect(t.lines == ["abcde", "fghij", "klmno", "pqrst", "uvwxy"], "nothing scrolled")
    }

    /// Origin mode's horizontal half. The region here is rows 6...11 and columns 5...10, which
    /// is esctest's own setup.
    func withOrigin() -> Terminal {
        let t = makeTerminal(columns: 20, rows: 12)
        t.feed("\u{1B}[6;11r\u{1B}[?69h\u{1B}[5;10s\u{1B}[?6h")
        return t
    }

    @Test func addressingCountsFromTheMarginsInOriginMode() {
        let t = withOrigin()
        t.feed("\u{1B}[1;1H")
        #expect(t.cursorPosition == [4, 5], "the origin is the margins' own corner")
        t.feed("\u{1B}[3;2H")
        #expect(t.cursorPosition == [5, 7])
        t.feed("\u{1B}[99;99H")
        #expect(t.cursorPosition == [9, 10], "and addressing is clamped to the margins")
        t.feed("\u{1B}[1G")
        #expect(t.cursorPosition == [4, 10], "CHA counts from the left margin too")
    }

    @Test func theRelativeMovesIgnoreOriginMode() {
        let t = withOrigin()
        t.feed("\u{1B}[2;2H\u{1B}[2a")
        #expect(t.cursorPosition == [7, 6], "HPR moves by two columns wherever the origin is")
        t.feed("\u{1B}[2;2H\u{1B}[2e")
        #expect(t.cursorPosition == [5, 8], "and VPR by two rows")
    }

    @Test func rowAddressingLeavesTheColumnAloneInOriginMode() {
        let t = withOrigin()
        t.feed("\u{1B}[3;2H\u{1B}[5d")
        #expect(t.cursorPosition == [5, 9], "VPA must not read the column as an origin-relative one")
    }

    /// The other half of origin mode: a program that addresses the page relative to the margins
    /// is told where the cursor is in the same coordinates. That is what makes esctest's tests
    /// named `HPA_IgnoresOriginMode` and `VPA_IgnoresOriginMode` pass here, while HPA and VPA
    /// count from the margins like every other absolute move: the report undoes the addressing,
    /// so the number read back is the number the program asked for.
    @Test func theCursorIsReportedFromTheMarginsInOriginMode() {
        let t = withOrigin()
        t.feed("\u{1B}[3;2H")
        _ = t.takeReplies()
        t.feed("\u{1B}[6n")
        #expect(t.takeReplyString() == "\u{1B}[3;2R")
        t.feed("\u{1B}[?6n")
        #expect(t.takeReplyString() == "\u{1B}[?3;2R")
        // Turning the mode off homes the cursor, as xterm does, so the reading that follows
        // addresses the screen again first.
        t.feed("\u{1B}[?6l\u{1B}[6;8H\u{1B}[6n")
        #expect(t.takeReplyString() == "\u{1B}[6;8R", "and from the screen's own corner once it is off")
    }

    @Test func aChecksumRectangleCountsFromTheMarginsInOriginMode() {
        let t = makeTerminal(columns: 20, rows: 12) { $0.answersChecksumRequests = true }
        t.feed("\u{1B}[6;5HX\u{1B}[6;11r\u{1B}[?69h\u{1B}[5;10s\u{1B}[?6h")
        _ = t.takeReplies()
        t.feed("\u{1B}[1;0;1;1;1;1*y")
        #expect(t.takeReplyString() == "\u{1B}P1!~0058\u{1B}\\", "the rectangle's own corner is the origin")
    }
}

/// What a review of the margin work found, each pinned so it stays found.
@Suite struct TerminalMarginReviewTests {
    @Test func aWrapAtTheRightMarginDoesNotJoinTheLine() {
        let t = makeTerminal(columns: 8, rows: 4)
        t.feed("ZZZZZZZZ\u{1B}[?69h\u{1B}[2;4s\u{1B}[1;2Habcdef")
        #expect(t.lines[0] == "ZabcZZZZ")
        #expect(!t.row(0).isWrapped, "the columns between the margins wrapped, not the line")
        t.resize(columns: 16, rows: 4)
        #expect(t.lines[0] == "ZabcZZZZ", "so a reflow does not splice in what lay outside them")
        #expect(t.lines[1] == " def")
    }

    @Test func shiftingBetweenMarginsLeavesNoHalfOfATwoColumnCharacter() {
        let insert = makeTerminal(columns: 8, rows: 1)
        // 世 on columns 4 and 5, with the right margin falling between its halves.
        insert.feed("\u{1B}[1;4H\u{4E16}\u{1B}[?69h\u{1B}[2;5s\u{1B}[1;2H\u{1B}[@")
        #expect(insert.row(0).cells[4].width == .narrow, "the head pushed onto the margin lost its tail")
        let delete = makeTerminal(columns: 8, rows: 1)
        delete.feed("\u{1B}[1;3H\u{4E16}\u{1B}[?69h\u{1B}[2;5s\u{1B}[1;3H\u{1B}[P")
        #expect(delete.row(0).cells[2].width == .narrow, "and the tail pulled out from under its head goes too")
    }

    @Test func lineEditingLeavesTheCursorOnTheLeftMargin() {
        let t = makeTerminal(columns: 5, rows: 5)
        for (row, line) in ["abcde", "fghij", "klmno", "pqrst", "uvwxy"].enumerated() {
            t.feed("\u{1B}[\(row + 1);1H" + line)
        }
        t.feed("\u{1B}[?69h\u{1B}[2;4s\u{1B}[2;3H\u{1B}[L")
        #expect(t.cursorPosition == [1, 1], "the line's home position is the left margin")
        t.feed("\u{1B}[L")
        #expect(
            t.lines == ["abcde", "f   j", "k   o", "pghit", "ulmny"],
            "so a second insert still has somewhere to act")
    }

    /// Whether a row forgets what it was about is the erasing sequence's business. It was
    /// briefly the protection state's, which meant an SPA/EPA pair protecting nothing changed
    /// what ED did to a row's marks.
    @Test func whatForgetsARowsMarksIsTheSequenceNotTheProtection() {
        let plain = makeTerminal(columns: 6, rows: 2)
        plain.feed("\u{1B}]133;A\u{7}ab\u{1B}V\u{1B}W\u{1B}[2;1H\u{1B}[2J")
        #expect(plain.row(0).text == "")
        #expect(plain.row(0).promptMarks.isEmpty, "ED cleared the row, so what it was about goes with it")
        let selective = makeTerminal(columns: 6, rows: 2)
        selective.feed("\u{1B}]133;A\u{7}ab\u{1B}V\u{1B}W\u{1B}[2;1H\u{1B}[?2J")
        #expect(!selective.row(0).promptMarks.isEmpty, "and a selective erase still keeps them")
    }

    /// VS16 widening is a fourth print path, and it has to stop at the margin like the others.
    @Test func aWidenedEmojiStopsAtTheRightMargin() {
        let t = makeTerminal(columns: 8, rows: 2)
        t.feed("\u{1B}[?69h\u{1B}[2;5s\u{1B}[1;4Ha\u{FE0F}")
        #expect(t.cursorPosition == [4, 0], "the cursor stops on the right margin with a wrap pending")
        t.feed("XY")
        #expect(t.lines[0] == "   a\u{FE0F}", "so what follows wraps instead of escaping the margin")
        #expect(t.lines[1] == " XY")
    }
}

/// What the security review found, and the invariant it swept for: every `.spacerTail` on the
/// screen has a `.wide` cell to its left. A tail with nothing to its left is not a cosmetic
/// problem — the app's double-click asks `WordRules.word` for the word at that cell, and a
/// half character with no other half makes it describe a range that runs backwards.
@Suite struct TerminalOrphanTailTests {
    /// Printing a wide character that the right margin refuses overwrites the cell the cursor
    /// is on. If a wide character already stood there, its tail is one column further right —
    /// outside the margins, where nothing else on the margin paths looks.
    @Test func aWideCharacterRefusedByTheRightMarginTakesTheOldTailWithIt() {
        let t = makeTerminal()
        t.feed("\u{1B}[1;8H\u{4F60}")  // 你 across columns 8 and 9
        t.feed("\u{1B}[?69h\u{1B}[1;8s")  // the right margin lands on 你's head
        t.feed("\u{1B}[1;8H\u{4F60}")  // no room for a second one: a spacer head and a wrap
        let row = t.row(0)
        #expect(row.cells[7].width == .spacerHead, "the refused character leaves its head behind")
        #expect(row.cells[8].width != .spacerTail, "and takes the old character's tail with it")
        #expect(orphanTails(t).isEmpty)
    }

    /// REP has its own copy of the rule, in `printRepeated`'s bulk loop rather than in
    /// `printScalar`, so it has to be reached its own way: an odd starting column leaves one
    /// column before the margin after three repetitions, and the fourth does not fit.
    @Test func repSpillsOntoTheMarginWithItsOwnCopyOfTheRule() {
        let t = makeTerminal()
        t.feed("\u{1B}[1;8H\u{4F60}")  // the tail to orphan, on column 9
        t.feed("\u{1B}[?69h\u{1B}[1;8s")
        t.feed("\u{1B}[1;2H\u{4F60}\u{1B}[3b")  // 你 at 2-3, then three more: 4-5, 6-7, and 8 refuses
        #expect(orphanTails(t).isEmpty)
    }

    /// The whole chain the review's fuzzer walked: once a tail is orphaned inside the margins,
    /// turning the margins off and deleting the columns to its left slides it to column 0,
    /// where nothing can be to its left at all.
    @Test func noSequenceSlidesAnOrphanedTailToTheFirstColumn() {
        let t = makeTerminal()
        t.feed("\u{1B}[1;8H\u{4F60}")
        t.feed("\u{1B}[?69h\u{1B}[1;8s")
        t.feed("\u{1B}[1;8H\u{4F60}")
        t.feed("\u{1B}[?69l\u{1B}[1;1H\u{1B}[8P")  // margins off, DCH slides it left
        #expect(orphanTails(t).isEmpty)
        t.feed("\u{1B}[1;2Hx")
        #expect(orphanTails(t).isEmpty)
    }

    /// Every cell on the active screen whose left neighbour does not make it a tail.
    private func orphanTails(_ t: Terminal) -> [[Int]] {
        var found: [[Int]] = []
        for y in 0..<t.rows {
            let cells = t.row(y).cells
            for x in cells.indices where cells[x].width == .spacerTail {
                if x == 0 || cells[x - 1].width != .wide { found.append([x, y]) }
            }
        }
        return found
    }
}

/// The second thing the security review found: a report has to stay inside the grammar it is
/// written in, whatever the cursor is doing.
@Suite struct TerminalCursorReportTests {
    /// The addressing paths clamp into the margins; `restoreCursor` deliberately does not,
    /// because a cursor outside them is legal and DECBI and DECFI are defined in terms of one.
    /// So a save taken before the margins existed can be restored to the left of them with
    /// origin mode still on, and the subtraction alone answered `CSI 1;-3R` — digits are all a
    /// CSI parameter can hold, so that is a reply no program can read.
    @Test func cprNeverReportsAColumnLeftOfTheCoordinateSpace() {
        let t = makeTerminal()
        t.feed("\u{1B}[?6h\u{1B}7\u{1B}[?69h\u{1B}[5;10s\u{1B}8\u{1B}[6n")
        #expect(t.takeReplyString() == "\u{1B}[1;1R")
        #expect(t.cursorPosition == [0, 0], "and the cursor is still where DECRC put it")
    }

    @Test func decxcprReportsTheSameWay() {
        let t = makeTerminal()
        t.feed("\u{1B}[?6h\u{1B}7\u{1B}[?69h\u{1B}[5;10s\u{1B}8\u{1B}[?6n")
        #expect(t.takeReplyString() == "\u{1B}[?1;1R")
    }

    /// The row half has the same shape through DECSTBM and has had since origin mode existed,
    /// so it is fixed with the column half rather than left one token away from it.
    @Test func cprNeverReportsARowAboveTheCoordinateSpace() {
        let t = makeTerminal()
        t.feed("\u{1B}[?6h\u{1B}7\u{1B}[3;4r\u{1B}8\u{1B}[6n")
        #expect(t.takeReplyString() == "\u{1B}[1;1R")
    }

    /// And the ordinary case is untouched: inside the margins the report still counts from
    /// them, which is what makes a program's own column come back unchanged.
    @Test func theReportStillCountsFromTheMarginsWhereItShould() {
        let t = makeTerminal()
        t.feed("\u{1B}[?69h\u{1B}[3;8s\u{1B}[?6h\u{1B}[1;2H\u{1B}[6n")
        #expect(t.takeReplyString() == "\u{1B}[1;2R", "the column the program asked for")
        #expect(t.cursorPosition == [3, 0], "which is column 4 on the screen")
    }
}
