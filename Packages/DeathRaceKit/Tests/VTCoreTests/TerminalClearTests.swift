import Testing

@testable import VTCore

@Suite struct TerminalClearTests {
    /// Eight numbered lines and a prompt on a 5-row screen: four lines in history.
    private func terminalAtAPrompt() -> Terminal {
        let t = makeTerminal(columns: 10, rows: 5)
        t.feed("1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8\r\n$ ls")
        return t
    }

    @Test func clearToStartMovesThePromptToTheTopAndDropsHistory() {
        let t = terminalAtAPrompt()
        #expect(t.scrollbackCount == 4)
        let generation = t.generation
        #expect(t.clear(.toStart))
        #expect(t.lines == ["$ ls", "", "", "", ""])
        #expect(t.scrollbackCount == 0)
        #expect(t.cursorPosition == [4, 0])
        #expect(t.generation == generation + 1)
        // Typing carries on where it was.
        t.feed(" -l")
        #expect(t.lines[0] == "$ ls -l")
    }

    @Test func clearToStartKeepsAWrappedCommandWhole() {
        let t = makeTerminal(columns: 5, rows: 5)
        t.feed("x\r\ny\r\n$ abcdefgh")
        #expect(t.lines == ["x", "y", "$ abc", "defgh", ""])
        #expect(t.clear(.toStart))
        #expect(t.lines == ["$ abc", "defgh", "", "", ""])
        #expect(t.row(0).isWrapped)
        #expect(t.cursorPosition == [4, 1])
    }

    @Test func clearToStartMovesTheSavedCursorWithItsLine() {
        let t = makeTerminal(columns: 10, rows: 5)
        // Saved on the prompt's line, row 2, which becomes row 0.
        t.feed("a\r\nb\r\n$ x\u{1B}7")
        #expect(t.clear(.toStart))
        t.feed("\u{1B}[5;1H\u{1B}8X")
        #expect(t.lines[0] == "$ xX")
    }

    @Test func clearScrollbackKeepsTheScreen() {
        let t = terminalAtAPrompt()
        let screen = t.lines
        #expect(t.clear(.scrollback))
        #expect(t.lines == screen)
        #expect(t.scrollbackCount == 0)
        #expect(t.cursorPosition == [4, 4])
    }

    @Test func theAlternateScreenIsLeftAlone() {
        let t = terminalAtAPrompt()
        t.feed("\u{1B}[?1049h\u{1B}[Hvim")
        let generation = t.generation
        #expect(!t.clear(.toStart))
        #expect(!t.clear(.scrollback))
        #expect(t.lines[0] == "vim")
        #expect(t.generation == generation)
        t.feed("\u{1B}[?1049l")
        #expect(t.scrollbackCount == 4)
    }

    @Test func nothingToClearChangesNothing() {
        let t = makeTerminal()
        t.feed("$ ")
        let generation = t.generation
        #expect(!t.clear(.toStart))
        #expect(!t.clear(.scrollback))
        #expect(t.generation == generation)
        #expect(t.lines[0] == "$")
    }

    @Test func lineNumbersAreNeverReused() {
        let t = terminalAtAPrompt()
        let before = t.linesScrolledOff
        t.clear(.toStart)
        // The four lines above the prompt left the screen; their numbers stay used.
        #expect(t.linesScrolledOff == before + 4)
    }
}
