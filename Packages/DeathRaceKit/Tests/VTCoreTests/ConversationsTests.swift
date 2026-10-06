import Testing

@testable import VTCore

/// Conversations, in the engine: what the shell says about a command, and whether it survives
/// everything the screen does afterwards.
///
/// Phase 8 builds a block model on `promptMarks` and `CommandRecord`, so the paths that move or
/// destroy rows all have to be right about them. Before this suite, three tests touched marks
/// at all — and two of the things it checks were broken.
@Suite struct ConversationsTests {

    // MARK: - The OSC 133 parameter walk

    /// `D` takes a parameter list. Reading only the first one as an integer dropped the exit
    /// code of iTerm2's own `D;<exit>;aid=<id>` form.
    @Test func theExitCodeIsFoundPastOtherParameters() {
        let t = makeTerminal()
        t.feed("\u{1B}]133;D;3;aid=7\u{7}")
        #expect(t.row(0).exitCode == 3)
    }

    /// A parameter list with no bare number says nothing about how the command went. `aid=7`
    /// must not be read as an exit code, and must not be read as zero either.
    @Test func aKeyedParameterIsNotAnExitCode() {
        let t = makeTerminal()
        t.feed("\u{1B}]133;D;aid=7\u{7}")
        #expect(t.row(0).promptMarks.contains(.commandEnd))
        #expect(t.row(0).exitCode == nil)
    }

    /// A `D` with no exit code is a shell that does not report one — not a shell retracting
    /// the one it just gave. This cleared the row's code before.
    @Test func abareEndDoesNotClearACodeAlreadyThere() {
        let t = makeTerminal()
        t.feed("\u{1B}]133;D;4\u{7}")
        #expect(t.row(0).exitCode == 4)
        t.feed("\u{1B}]133;D\u{7}")
        #expect(t.row(0).exitCode == 4)
    }

    @Test func zeroIsAnExitCodeLikeAnyOther() {
        let t = makeTerminal()
        t.feed("\u{1B}]133;D;0\u{7}")
        #expect(t.row(0).exitCode == 0)
    }

    /// The duration rides as a keyed parameter, so every other terminal ignores it.
    @Test func theDurationComesFromTheShell() {
        let t = makeTerminal()
        t.feed("\u{1B}]133;D;0;dur=12400\u{7}")
        #expect(t.row(0).command?.durationMilliseconds == 12_400)
        #expect(t.row(0).command?.exitCode == 0)
    }

    @Test func aDurationThatIsNotANumberIsIgnored() {
        let t = makeTerminal()
        t.feed("\u{1B}]133;D;0;dur=soon\u{7}")
        #expect(t.row(0).command?.durationMilliseconds == nil)
        #expect(t.row(0).exitCode == 0)
    }

    @Test func anUnknownMarkChangesNothing() {
        let t = makeTerminal()
        t.feed("\u{1B}]133;Z;9\u{7}")
        #expect(t.row(0).promptMarks.isEmpty)
        #expect(t.row(0).command == nil)
    }

    // MARK: - OSC 633;E, the command's own text

    /// The text arrives at the prompt and belongs to the `commandEnd` after the output, which
    /// is a different row.
    @Test func theCommandTextLandsOnTheRowThatEndsIt() {
        let t = makeTerminal()
        t.feed("\u{1B}]133;A\u{7}$ \u{1B}]633;E;swift build\u{7}\r\nout\r\n\u{1B}]133;D;0;dur=900\u{7}")
        #expect(t.row(0).command == nil)
        #expect(t.row(2).command == CommandRecord(text: "swift build", durationMilliseconds: 900, exitCode: 0))
    }

    /// One command's text must never label the next one.
    @Test func theTextIsSpentOnTheFirstEndThatFollows() {
        let t = makeTerminal()
        t.feed("\u{1B}]633;E;first\u{7}\u{1B}]133;D;0\u{7}\r\n\u{1B}]133;D;0\u{7}")
        #expect(t.row(0).command?.text == "first")
        #expect(t.row(1).command?.text == "")
    }

    @Test func vsCodeEscapesAreUndone() {
        #expect(Terminal.unescapeVSCode("echo a\\x3bb") == "echo a;b")
        #expect(Terminal.unescapeVSCode("a\\\\b") == "a\\b")
        // An escape we do not know keeps its character rather than losing it.
        #expect(Terminal.unescapeVSCode("a\\qb") == "aqb")
        // A trailing backslash is text, not the start of something.
        #expect(Terminal.unescapeVSCode("a\\") == "a\\")
        // A short or malformed byte escape is not silently turned into a different character.
        #expect(Terminal.unescapeVSCode("a\\x3") == "ax3")
        #expect(Terminal.unescapeVSCode("a\\xzzb") == "axzzb")
    }

    /// A command line is shown on screen and written to disk, so it carries no controls and no
    /// unbounded length — the same rule the rest of the app uses for text it did not write.
    @Test func theCommandTextIsCleanedAndCapped() {
        let t = makeTerminal()
        t.feed("\u{1B}]633;E;echo \\x07bell\u{7}\u{1B}]133;D;0\u{7}")
        #expect(t.row(0).command?.text == "echo bell")

        let t2 = makeTerminal()
        t2.feed("\u{1B}]633;E;" + String(repeating: "x", count: 5_000) + "\u{7}\u{1B}]133;D;0\u{7}")
        #expect(t2.row(0).command?.text.count == CommandRecord.textLimit)
    }

    /// A command's own output can print anything, including something shaped like a mark. The
    /// engine takes marks from the stream by design, so what this pins down is that `E` with
    /// no text clears the pending text rather than leaving it to label a later command.
    @Test func anEmptyCommandTextClearsWhatWasPending() {
        let t = makeTerminal()
        t.feed("\u{1B}]633;E;real\u{7}\u{1B}]633;E\u{7}\u{1B}]133;D;0\u{7}")
        #expect(t.row(0).command?.text == "")
    }

    @Test func otherVSCodeSubcommandsAreIgnored() {
        let t = makeTerminal()
        t.feed("\u{1B}]633;P;Cwd=/tmp\u{7}\u{1B}]133;D;0\u{7}")
        #expect(t.row(0).command?.text == "")
    }

    // MARK: - Does a mark survive what the screen does?

    /// ED. This was the second bug: a blanked row kept its marks, so a block model would draw
    /// a rail around nothing.
    @Test func clearingTheScreenTakesTheMarksWithIt() {
        let t = makeTerminal()
        t.feed("\u{1B}]133;A\u{7}$ ls\u{1B}]133;D;0\u{7}")
        #expect(!t.row(0).promptMarks.isEmpty)
        t.feed("\u{1B}[2J")
        #expect(t.row(0).promptMarks.isEmpty)
        #expect(t.row(0).command == nil)
    }

    /// Erasing part of a line does not unsay where its prompt began.
    @Test func erasingPartOfALineKeepsItsMarks() {
        let t = makeTerminal()
        t.feed("\u{1B}]133;A\u{7}$ ls\u{1B}[3G\u{1B}[0K")
        #expect(t.row(0).promptMarks == .promptStart)
    }

    @Test func aFullWidthEraseOfOneLineTakesItsMarks() {
        let t = makeTerminal()
        t.feed("\u{1B}]133;A\u{7}$ ls\u{1B}[2K")
        #expect(t.row(0).promptMarks.isEmpty)
    }

    @Test func risLeavesNoMarksBehind() {
        let t = makeTerminal()
        t.feed("\u{1B}]133;A\u{7}$ \u{1B}]133;D;1\u{7}\u{1B}c")
        #expect(t.row(0).promptMarks.isEmpty)
        #expect(t.row(0).command == nil)
    }

    @Test func decalnLeavesNoMarksBehind() {
        let t = makeTerminal()
        t.feed("\u{1B}]133;A\u{7}$ \u{1B}]133;D;1\u{7}\u{1B}#8")
        #expect(t.row(0).promptMarks.isEmpty)
    }

    /// The alternate screen is its own grid; a full-screen program must not be able to lose
    /// the primary screen's marks, and must not inherit them either.
    @Test func theAlternateScreenHasMarksOfItsOwn() {
        let t = makeTerminal()
        t.feed("\u{1B}]133;A\u{7}$ ls\u{1B}]133;D;0\u{7}")
        t.feed("\u{1B}[?1049h")
        #expect(t.row(0).promptMarks.isEmpty)
        t.feed("\u{1B}[?1049l")
        #expect(t.row(0).promptMarks == [.promptStart, .commandEnd])
        #expect(t.row(0).exitCode == 0)
    }

    /// IL and DL move rows, so they have to move the marks on them.
    @Test func insertedAndDeletedLinesCarryTheirMarks() {
        let t = makeTerminal()
        t.feed("\u{1B}]133;A\u{7}a\r\nb")
        t.feed("\u{1B}[H\u{1B}[L")  // insert a blank line above the marked one
        #expect(t.row(0).promptMarks.isEmpty)
        #expect(t.row(1).promptMarks == .promptStart)
        t.feed("\u{1B}[H\u{1B}[M")  // delete it again
        #expect(t.row(0).promptMarks == .promptStart)
    }

    /// SU and SD scroll the region; the marks go with the text.
    @Test func scrollingTheRegionCarriesMarks() {
        let t = makeTerminal()
        t.feed("\u{1B}]133;A\u{7}a")
        t.feed("\u{1B}[T")  // SD: everything moves down one
        #expect(t.row(0).promptMarks.isEmpty)
        #expect(t.row(1).promptMarks == .promptStart)
    }

    /// A marked row scrolled off is still a marked row: the block model reads the scrollback.
    @Test func marksSurviveGoingIntoTheScrollback() {
        let t = makeTerminal(rows: 2)
        t.feed("\u{1B}]133;A\u{7}$ ls\u{1B}]133;D;0;dur=50\u{7}\r\nb\r\nc")
        #expect(t.scrollbackRow(0).promptMarks == [.promptStart, .commandEnd])
        #expect(t.scrollbackRow(0).command?.durationMilliseconds == 50)
    }

    /// Trimming the scrollback past its cap drops whole rows; nothing is left half-marked.
    @Test func trimmingTheScrollbackDropsWholeRows() {
        let t = makeTerminal(rows: 2) { $0.scrollbackLimitBytes = 1 }
        t.feed("\u{1B}]133;A\u{7}$ ls\u{1B}]133;D;0\u{7}\r\n")
        for i in 0..<50 { t.feed("line \(i)\r\n") }
        // Whatever survived the cap, no row claims a command the trim should have taken.
        for i in 0..<t.scrollbackCount {
            let row = t.scrollbackRow(i)
            if row.command != nil { #expect(row.promptMarks.contains(PromptMarks.commandEnd)) }
        }
    }

    /// Reflow folds a wrapped line's marks onto its first row and mints new row ids, which is
    /// why the block model anchors to line numbers rather than ids. What must not happen is a
    /// mark or a command being lost.
    @Test func reflowKeepsMarksAndTheCommandRecord() {
        let t = makeTerminal(columns: 10, rows: 4)
        t.feed("\u{1B}]133;A\u{7}0123456789abcde\u{1B}]133;D;2;dur=77\u{7}")
        #expect(t.row(0).promptMarks.contains(.promptStart))
        t.resize(columns: 20, rows: 4)
        let marked = (0..<4).map { t.row($0) }.first { !$0.promptMarks.isEmpty }
        let row = try! #require(marked)
        #expect(row.promptMarks.contains(.promptStart))
        #expect(row.promptMarks.contains(.commandEnd))
        #expect(row.command == CommandRecord(text: "", durationMilliseconds: 77, exitCode: 2))
    }

    /// Resizing to the same width must not disturb anything.
    @Test func aResizeToTheSameWidthKeepsMarksWhereTheyAre() {
        let t = makeTerminal(columns: 10, rows: 4)
        t.feed("\u{1B}]133;A\u{7}$ ls\u{1B}]133;D;0\u{7}")
        t.resize(columns: 10, rows: 4)
        #expect(t.row(0).promptMarks == [.promptStart, .commandEnd])
        #expect(t.row(0).exitCode == 0)
    }
}
