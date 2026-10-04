import Testing

@testable import VTCore

@Suite struct TerminalPrintTests {
    @Test func printsText() {
        let t = makeTerminal()
        t.feed("hello")
        #expect(t.lines[0] == "hello")
        #expect(t.cursorPosition == [5, 0])
    }

    @Test func wrapsAtTheRightMargin() {
        let t = makeTerminal()
        t.feed("abcdefghijKL")
        #expect(t.lines[0] == "abcdefghij")
        #expect(t.lines[1] == "KL")
        #expect(t.row(0).isWrapped)
        #expect(!t.row(1).isWrapped)
        #expect(t.cursorPosition == [2, 1])
    }

    @Test func lastColumnHoldsThePendingWrap() {
        let t = makeTerminal()
        t.feed("abcdefghij")
        #expect(t.cursorPosition == [9, 0])
        #expect(t.cursor.pendingWrap)
        // A carriage return cancels the wrap: nothing moves to the next line.
        t.feed("\rX")
        #expect(t.lines[0] == "Xbcdefghij")
        #expect(t.lines[1] == "")
        #expect(!t.row(0).isWrapped)
    }

    @Test func wrapsTheSameWhetherTextArrivesAtOnceOrByteByByte() {
        let text = "The quick brown fox jumps over the lazy dog, twice over."
        let whole = makeTerminal()
        whole.feed(text)
        let pieces = makeTerminal()
        for byte in text.utf8 { pieces.feed([byte]) }
        #expect(whole.lines == pieces.lines)
        #expect(whole.cursorPosition == pieces.cursorPosition)
    }

    @Test func withoutAutowrapTheLastColumnIsOverwritten() {
        let t = makeTerminal()
        t.feed("\u{1B}[?7labcdefghijKLM")
        #expect(t.lines[0] == "abcdefghiM")
        #expect(t.lines[1] == "")
        #expect(t.cursorPosition == [9, 0])
        #expect(!t.cursor.pendingWrap)
        t.feed("N")
        #expect(t.lines[0] == "abcdefghiN")
    }

    @Test func lineFeedAtTheBottomScrollsIntoScrollback() {
        let t = makeTerminal(rows: 3)
        t.feed("1\r\n2\r\n3\r\n4")
        #expect(t.lines == ["2", "3", "4"])
        #expect(t.scrollbackLines == ["1"])
    }

    @Test func newlineModeAddsACarriageReturn() {
        let t = makeTerminal()
        t.feed("ab\nc")
        #expect(t.lines[1] == "  c")
        t.feed("\u{1B}[20h\nd")
        #expect(t.lines[2] == "d")
    }

    // MARK: Wide characters

    @Test func wideCharactersTakeTwoCells() {
        let t = makeTerminal()
        t.feed("a中b")
        let row = t.row(0)
        #expect(row.cells[1].width == .wide)
        #expect(row.cells[2].width == .spacerTail)
        #expect(row.cells[3].scalar == 0x62)
        #expect(t.lines[0] == "a中b")
        #expect(t.cursorPosition == [4, 0])
    }

    @Test func wideCharacterInTheLastColumnWrapsAndLeavesASpacerHead() {
        let t = makeTerminal()
        t.feed("abcdefghi中")
        #expect(t.row(0).cells[9].width == .spacerHead)
        #expect(t.row(0).isWrapped)
        #expect(t.lines[0] == "abcdefghi")
        #expect(t.lines[1] == "中")
        #expect(t.cursorPosition == [2, 1])
    }

    @Test func overwritingHalfAWideCharacterErasesTheOtherHalf() {
        let right = makeTerminal()
        right.feed("中\u{1B}[1;2HX")
        #expect(right.lines[0] == " X")
        #expect(right.row(0).cells[0].width == .narrow)

        let left = makeTerminal()
        left.feed("中\u{1B}[1;1HX")
        #expect(left.lines[0] == "X")
        #expect(left.row(0).cells[1].width == .narrow)
    }

    // MARK: Graphemes

    @Test func combiningMarksJoinThePreviousCharacter() {
        let t = makeTerminal()
        t.feed("e\u{301}x")
        #expect(t.row(0).scalars(at: 0) == [0x65, 0x301])
        #expect(t.row(0).scalars(at: 1) == [0x78])
        #expect(t.cursorPosition == [2, 0])
    }

    @Test func aCellKeepsALimitedNumberOfMarks() {
        let t = makeTerminal()
        t.feed("a" + String(repeating: "\u{301}", count: 1_000) + "b")
        #expect(t.row(0).scalars(at: 0).count == 1 + Terminal.graphemeScalarLimit)
        #expect(t.row(0).scalars(at: 1) == [0x62])
        #expect(t.cursorPosition == [2, 0])
    }

    @Test func marksCountTowardTheScrollbackBudget() {
        let one = makeTerminal()
        one.feed("a\u{301}")
        let many = makeTerminal()
        many.feed("a" + String(repeating: "\u{301}", count: 32))
        #expect(many.row(0).estimatedBytes - one.row(0).estimatedBytes == 31 * 4)
    }

    @Test func combiningMarkAfterAPendingWrapJoinsTheLastColumn() {
        let t = makeTerminal()
        t.feed("abcdefghij\u{301}")
        #expect(t.row(0).scalars(at: 9) == [0x6A, 0x301])
        #expect(t.cursor.pendingWrap)
        #expect(t.lines[1] == "")
    }

    @Test func zwjSequenceIsOneWideCharacter() {
        let t = makeTerminal()
        t.feed("👨‍👩‍👧!")
        #expect(t.row(0).scalars(at: 0) == [0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467])
        #expect(t.row(0).cells[0].width == .wide)
        #expect(t.row(0).scalars(at: 2) == [0x21])
        #expect(t.cursorPosition == [3, 0])
    }

    @Test func regionalIndicatorsPairIntoFlags() {
        let t = makeTerminal()
        t.feed("🇺🇸🇬🇧")
        #expect(t.row(0).scalars(at: 0) == [0x1F1FA, 0x1F1F8])
        #expect(t.row(0).scalars(at: 2) == [0x1F1EC, 0x1F1E7])
        #expect(t.cursorPosition == [4, 0])
    }

    @Test func skinToneModifierJoinsTheEmoji() {
        let t = makeTerminal()
        t.feed("👍🏽")
        #expect(t.row(0).scalars(at: 0) == [0x1F44D, 0x1F3FD])
        #expect(t.cursorPosition == [2, 0])
    }

    @Test func variationSelector16WidensANarrowEmoji() {
        let t = makeTerminal()
        t.feed("❤\u{FE0F}x")
        #expect(t.row(0).cells[0].width == .wide)
        #expect(t.row(0).scalars(at: 0) == [0x2764, 0xFE0F])
        #expect(t.row(0).scalars(at: 2) == [0x78])
    }

    @Test func variationSelector16KeepsAProtectedCharacterProtected() {
        let t = makeTerminal()
        // DECSCA protects what follows; a selective erase (DECSED) must spare both halves.
        t.feed("\u{1B}[1\"q❤\u{FE0F}\u{1B}[0\"q\u{1B}[?2J")
        #expect(t.row(0).cells[0].isProtected)
        #expect(t.row(0).cells[1].width == .spacerTail)
        #expect(t.row(0).cells[1].isProtected)
        #expect(t.row(0).scalars(at: 0) == [0x2764, 0xFE0F])
    }

    @Test func cuttingAWideCharacterDropsItsExtraScalars() {
        let t = makeTerminal(columns: 4)
        // On the alternate screen a narrower width crops rows instead of reflowing them.
        t.feed("\u{1B}[?1049hab👩‍👩‍👧")
        #expect(t.row(0).cells[2].hasGrapheme)
        t.resize(columns: 3, rows: 5)
        #expect(t.row(0).cells[2].isEmpty)
        #expect(!t.row(0).cells[2].hasGrapheme)
        #expect(t.row(0).graphemes.isEmpty)
    }

    @Test func legacyWidthModeKeepsCodePointWidths() {
        let t = makeTerminal()
        t.feed("\u{1B}[?2027l❤\u{FE0F}")
        #expect(t.row(0).cells[0].width == .narrow)
        #expect(t.cursorPosition == [1, 0])

        let family = makeTerminal()
        family.feed("\u{1B}[?2027l👨‍👩")
        #expect(family.row(0).scalars(at: 0) == [0x1F468, 0x200D])
        #expect(family.row(0).scalars(at: 2) == [0x1F469])
        #expect(family.cursorPosition == [4, 0])
    }

    @Test func overwritingACharacterDropsItsMarks() {
        let t = makeTerminal()
        t.feed("e\u{301}\rX")
        #expect(t.row(0).scalars(at: 0) == [0x58])
        #expect(t.row(0).graphemes.isEmpty)
    }

    @Test func invalidUTF8PrintsReplacementCharacters() {
        let t = makeTerminal()
        t.feed([0x61, 0xFF, 0x62, 0xE2, 0x82])
        #expect(t.row(0).scalars(at: 1) == [0xFFFD])
        #expect(t.row(0).scalars(at: 2) == [0x62])
        // The truncated sequence is still pending; the next byte completes it as invalid.
        t.feed([0x63])
        #expect(t.lines[0] == "a\u{FFFD}b\u{FFFD}c")
    }

    // MARK: Character sets

    @Test func decSpecialGraphicsDrawsLines() {
        let t = makeTerminal()
        t.feed("\u{1B}(0lqk\u{1B}(Bq")
        #expect(t.lines[0] == "┌─┐q")
    }

    @Test func shiftOutInvokesG1() {
        let t = makeTerminal()
        t.feed("\u{1B})0\u{0E}q\u{0F}q")
        #expect(t.lines[0] == "─q")
    }

    @Test func singleShiftAppliesToOneCharacter() {
        let t = makeTerminal()
        t.feed("\u{1B}*0\u{1B}Nqq")
        #expect(t.lines[0] == "─q")
    }

    @Test func britishCharsetMapsThePoundSign() {
        let t = makeTerminal()
        t.feed("\u{1B}(A#\u{1B}(B#")
        #expect(t.lines[0] == "£#")
    }

    // MARK: Insert mode, REP, tabs

    @Test func insertModeShiftsTheLineRight() {
        let t = makeTerminal()
        t.feed("abc\r\u{1B}[4hXY")
        #expect(t.lines[0] == "XYabc")
        #expect(t.cursorPosition == [2, 0])
    }

    @Test func repeatRepeatsTheLastCharacter() {
        let t = makeTerminal()
        t.feed("a\u{1B}[3b")
        #expect(t.lines[0] == "aaaa")
        // A REP is a control sequence too: the next one has nothing to repeat.
        t.feed("\u{1B}[b")
        #expect(t.lines[0] == "aaaa")
        t.feed("b\u{1B}[b")
        #expect(t.lines[0] == "aaaabb")
        // After a control, there is nothing to repeat.
        t.feed("\r\n\u{1B}[3b")
        #expect(t.lines[1] == "")
    }

    /// REP writes in bulk where it can; whatever path it takes, it must leave the screen that
    /// printing the character that many more times leaves.
    @Test(arguments: [
        ("x", "x"), ("中", "中"), ("é", "é"), ("\u{1B}(0q", "q"), ("\u{1B}[4hx", "x"), ("\u{1B}[4h中", "中"),
        ("\u{1B}[?7lx", "x"), ("\u{1B}[?7l中", "中"), ("\u{1B}[1;31mx", "x"), ("\u{1B}[1\"q中", "中"),
        ("👍", "👍"), ("👨\u{200D}", "👨"), ("🇺", "🇺"), ("\u{1B}[?2027l🇺", "🇺"), ("👍🏽", "👍"),
    ])
    func repeatMatchesPrintingAgain(_ character: String, _ printed: String) {
        let starts = ["", "\u{1B}[1;9H", "\u{1B}[2;10H", "\u{1B}[5;10H", "\u{1B}[3;4r\u{1B}[4;8H", "ab中\u{1B}[1;2H"]
        for start in starts {
            for times in [1, 2, 3, 4, 9, 10, 11, 25, 39, 40] {
                let repeated = makeTerminal()
                repeated.feed(start + character + "\u{1B}[\(times)b")
                let again = makeTerminal()
                again.feed(start + character + String(repeating: printed, count: times))
                #expect(
                    repeated.dump() == again.dump(),
                    "\(character.debugDescription) at \(start.debugDescription), \(times) times")
            }
        }
    }

    @Test func tabsStopEveryEightColumns() {
        let t = makeTerminal()
        t.feed("\tX")
        #expect(t.lines[0] == "        X")
        // Past the last stop, a tab goes to the last column.
        t.feed("\r\n\t\tY")
        #expect(t.lines[1] == "         Y")
    }

    // MARK: Damage tracking

    @Test func changedRowsGetNewerVersions() {
        let t = makeTerminal()
        t.feed("a")
        let before = t.currentVersion
        let untouched = t.row(1).version
        t.feed("\u{1B}[3;1Hb")
        #expect(t.row(2).version > before)
        #expect(t.row(1).version == untouched)
    }

    @Test func rowIdsSurviveScrolling() {
        let t = makeTerminal(rows: 3)
        t.feed("1\r\n2\r\n3")
        let id = t.row(1).id
        t.feed("\r\n")
        #expect(t.row(0).id == id)
        #expect(t.row(0).text == "2")
    }
}
