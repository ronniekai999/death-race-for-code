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

    /// VS Code's own form is `E;<command>;<nonce>`. Taking everything after the first `;`
    /// put the nonce, and the separator before it, on the end of every command it reported.
    /// Nothing is lost by splitting on all of them: both escapers write a real `;` as `\x3b`.
    @Test func theCommandStopsAtTheNextParameter() {
        let t = makeTerminal()
        t.feed("\u{1B}]633;E;echo hi;1a2b3c\u{7}\u{1B}]133;D;0\u{7}")
        #expect(t.row(0).command?.text == "echo hi")
    }

    /// And a `;` that was part of the command still arrives whole, because it travels escaped.
    @Test func anEscapedSemicolonIsStillPartOfTheCommand() {
        let t = makeTerminal()
        t.feed("\u{1B}]633;E;echo a\\x3b echo b;nonce\u{7}\u{1B}]133;D;0\u{7}")
        #expect(t.row(0).command?.text == "echo a; echo b")
    }

    /// `UInt8(_:radix:)` accepts a leading sign, so `\x+3` was read as the byte 3 — a control
    /// character smuggled in through an escape that is not one. Anything that is not two hex
    /// digits is taken literally, as every other near-miss already is.
    @Test func aSignIsNotAHexDigit() {
        let t = makeTerminal()
        t.feed("\u{1B}]633;E;a\\x+3b\u{7}\u{1B}]133;D;0\u{7}")
        #expect(t.row(0).command?.text == "ax+3b")
    }

    /// A shell that reports the command and then never reports its end — killed, or an
    /// integration half installed — must not have its text turn up on the next command.
    @Test func aCommandWithNoEndDoesNotLandOnTheNextOne() {
        let t = makeTerminal()
        t.feed("\u{1B}]633;E;the one that got away\u{7}")
        t.feed("\u{1B}]133;A\u{7}\u{1B}]133;D;0\u{7}")
        #expect(t.row(0).command?.text != "the one that got away")
        #expect(t.row(0).command?.text.isEmpty != false)
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

    /// Erasing a whole line is not clearing the screen, and a prompt does it on every single
    /// command: zsh and bash both rewrite their prompt line with `\r` then an erase. Forgetting
    /// the marks here threw away the record of the command that had just finished, every time,
    /// because `OSC 133;D` is written on exactly the row the prompt is about to redraw. Found
    /// by the real-shell tests, which is the pairing they exist for.
    @Test func erasingAWholeLineKeepsItsMarksBecauseAPromptDoesThat() {
        let t = makeTerminal()
        t.feed("\u{1B}]133;D;0;dur=5\u{7}\u{1B}]133;A\u{7}$ ls\r\u{1B}[2K")
        #expect(t.row(0).promptMarks.contains(PromptMarks.commandEnd))
        #expect(t.row(0).command?.durationMilliseconds == 5)
    }

    /// The same, for the erase-to-end-of-display a prompt uses. By range this is identical to
    /// clearing the screen — cursor at column zero, erase to the last column — which is why
    /// the engine is told the intent rather than left to guess it.
    @Test func aPromptRedrawingFromTheCursorKeepsItsMarks() {
        let t = makeTerminal()
        t.feed("\u{1B}]133;D;3\u{7}\u{1B}]133;A\u{7}$ \r\u{1B}[J")
        #expect(t.row(0).promptMarks.contains(PromptMarks.commandEnd))
        #expect(t.row(0).exitCode == 3)
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
    /// A cap of 1 byte leaves no scrollback at all, so the loop that used to be here never
    /// ran a single iteration and the test could not have failed. The cap is now big enough to
    /// keep some rows and small enough to drop others, and the first assertion is that there
    /// is in fact something to look at.
    @Test func trimmingTheScrollbackDropsWholeRows() {
        let t = makeTerminal(columns: 20, rows: 2) { $0.scrollbackLimitBytes = 8_000 }
        t.feed("\u{1B}]133;A\u{7}$ ls\u{1B}]133;D;0;dur=5\u{7}\r\n")
        for i in 0..<200 { t.feed("line \(i)\r\n") }
        #expect(t.scrollbackCount > 0, "nothing was kept, so nothing below was checked")
        #expect(t.scrollbackCount < 200, "nothing was dropped, so the trim was never exercised")
        // Whatever survived the cap, no row claims a command without the mark it belongs to —
        // a row cannot be half trimmed.
        for i in 0..<t.scrollbackCount {
            let row = t.scrollbackRow(i)
            if row.command != nil { #expect(row.promptMarks.contains(PromptMarks.commandEnd)) }
        }
    }

    /// A command line is the one thing on a row whose size is not fixed, and the scrollback is
    /// trimmed by `estimatedBytes` — so a row left it out of the count, and a thousand long
    /// command lines were a megabyte the cap could not see.
    @Test func aCommandLineCountsTowardsTheScrollbacksSize() {
        let long = String(repeating: "x", count: CommandRecord.textLimit)
        let plain = makeTerminal(columns: 20, rows: 2) { $0.scrollbackLimitBytes = 40_000 }
        let withCommands = makeTerminal(columns: 20, rows: 2) { $0.scrollbackLimitBytes = 40_000 }
        for i in 0..<60 {
            plain.feed("line \(i)\r\n")
            withCommands.feed("\u{1B}]633;E;\(long)\u{7}\u{1B}]133;D;0\u{7}line \(i)\r\n")
        }
        #expect(
            withCommands.scrollbackCount < plain.scrollbackCount,
            "rows carrying a kilobyte of command line were counted as though they did not")
    }
    /// `ESC[H ESC[J` is how a full-screen program and `clear` wipe the screen, and it leaves
    /// nothing on the rows below the cursor — so their marks are about text that is gone.
    @Test func eraseToTheEndOfTheScreenForgetsTheRowsItBlanked() {
        let t = makeTerminal(rows: 4)
        t.feed("\u{1B}[3;1H\u{1B}]133;A\u{7}$ ls\u{1B}]133;D;7\u{7}")
        #expect(t.row(2).promptMarks.contains(.commandEnd))
        t.feed("\u{1B}[H\u{1B}[J")
        #expect(t.row(2).promptMarks.isEmpty, "a mark was left on a row that was blanked")
        #expect(t.row(2).command == nil)
    }

    /// But the cursor's own row keeps its marks, because erasing part of it is exactly how a
    /// prompt redraws itself — `\r` then erase-to-end — and that row is the one holding them.
    @Test func aPromptRedrawingItselfKeepsItsOwnMark() {
        let t = makeTerminal(rows: 4)
        t.feed("\u{1B}]133;A\u{7}$ ls\u{1B}]133;D;0\u{7}")
        t.feed("\r\u{1B}[J$ ls -l")
        #expect(t.row(0).promptMarks.contains(.promptStart))
        #expect(t.row(0).promptMarks.contains(.commandEnd))
    }

    /// The other half of the same rule: `ESC[1J` blanks every row above the cursor.
    @Test func eraseToTheStartOfTheScreenForgetsTheRowsItBlanked() {
        let t = makeTerminal(rows: 4)
        t.feed("\u{1B}]133;A\u{7}$ ls\u{1B}]133;D;7\u{7}")
        t.feed("\u{1B}[3;1H\u{1B}[1J")
        #expect(t.row(0).promptMarks.isEmpty)
        #expect(t.row(0).command == nil)
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
