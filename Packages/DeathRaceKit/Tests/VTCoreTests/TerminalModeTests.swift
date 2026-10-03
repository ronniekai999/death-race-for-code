import Testing

@testable import VTCore

/// Modes, screens and resets.
@Suite struct TerminalModeTests {
    @Test func alternateScreen1049SavesAndRestoresThePrimary() {
        let t = makeTerminal()
        t.feed("abc\u{1B}[1;32m\u{1B}[?1049h")
        #expect(t.isAlternateScreen)
        #expect(t.lines == ["", "", "", "", ""])
        #expect(t.cursorPosition == [3, 0])
        t.feed("\u{1B}[0mXYZ\u{1B}[5;5H\u{1B}[?1049l")
        #expect(!t.isAlternateScreen)
        #expect(t.lines[0] == "abc")
        #expect(t.cursorPosition == [3, 0])
        #expect(t.currentStyle == Style(foreground: .indexed(2), attributes: .bold))
    }

    @Test func alternateScreen1049StartsClean() {
        let t = makeTerminal()
        t.feed("\u{1B}[?1049hold\u{1B}[?1049l\u{1B}[?1049h")
        #expect(t.lines[0] == "")
    }

    @Test func alternateScreen47KeepsItsContent() {
        let t = makeTerminal()
        t.feed("\u{1B}[?47hfoo\u{1B}[?47l")
        #expect(t.lines[0] == "")
        t.feed("\u{1B}[?47h")
        #expect(t.lines[0] == "foo")
    }

    @Test func alternateScreen1047ClearsOnTheWayOut() {
        let t = makeTerminal()
        t.feed("\u{1B}[?1047hfoo\u{1B}[?1047l\u{1B}[?47h")
        #expect(t.lines[0] == "")
    }

    @Test func screenSwitchesBumpTheGeneration() {
        let t = makeTerminal()
        let generation = t.generation
        t.feed("\u{1B}[?1049h")
        #expect(t.generation == generation + 1)
        #expect(t.takeEvents().contains(.screenReplaced))
        // Entering twice is not a switch.
        t.feed("\u{1B}[?1049h")
        #expect(t.generation == generation + 1)
    }

    @Test func decsetTogglesModes() {
        let t = makeTerminal()
        t.feed("\u{1B}[?1h\u{1B}[?25l\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?2004h\u{1B}[?1004h\u{1B}[?2026h")
        #expect(t.modes.applicationCursorKeys)
        #expect(!t.cursor.visible)
        #expect(t.modes.mouseTracking == .buttonEvent)
        #expect(t.modes.mouseEncoding == .sgr)
        #expect(t.modes.bracketedPaste)
        #expect(t.modes.focusEvents)
        #expect(t.modes.synchronizedOutput)
        t.feed("\u{1B}[?1;1002;1006;2004;1004;2026l\u{1B}[?25h")
        #expect(t.modes == TerminalModes())
    }

    @Test func resettingAnotherMouseModeLeavesTheCurrentOne() {
        let t = makeTerminal()
        t.feed("\u{1B}[?1003h\u{1B}[?1000l")
        #expect(t.modes.mouseTracking == .anyEvent)
        t.feed("\u{1B}[?1003l")
        #expect(t.modes.mouseTracking == .none)
    }

    @Test func keypadModes() {
        let t = makeTerminal()
        t.feed("\u{1B}=")
        #expect(t.modes.applicationKeypad)
        t.feed("\u{1B}>")
        #expect(!t.modes.applicationKeypad)
    }

    @Test func modeReports() {
        let t = makeTerminal()
        t.feed("\u{1B}[?2004$p")
        #expect(t.takeReplyString() == "\u{1B}[?2004;2$y")
        t.feed("\u{1B}[?2004h\u{1B}[?2004$p")
        #expect(t.takeReplyString() == "\u{1B}[?2004;1$y")
        t.feed("\u{1B}[?9999$p")
        #expect(t.takeReplyString() == "\u{1B}[?9999;0$y")
        t.feed("\u{1B}[4$p")
        #expect(t.takeReplyString() == "\u{1B}[4;2$y")
        t.feed("\u{1B}[?1049h\u{1B}[?1049$p")
        #expect(t.takeReplyString() == "\u{1B}[?1049;1$y")
    }

    @Test func cursorStyles() {
        let t = makeTerminal()
        t.feed("\u{1B}[5 q")
        #expect(t.cursorShape == .bar)
        #expect(t.cursorBlinks == true)
        t.feed("\u{1B}[2 q")
        #expect(t.cursorShape == .block)
        #expect(t.cursorBlinks == false)
        t.feed("\u{1B}[4 q")
        #expect(t.cursorShape == .underline)
        #expect(t.cursorBlinks == false)
        t.feed("\u{1B}[0 q")
        #expect(t.cursorShape == .block)
        #expect(t.cursorBlinks == nil)
    }

    @Test func kittyKeyboardFlagsPushPopAndSet() {
        let t = makeTerminal()
        t.feed("\u{1B}[>1u")
        #expect(t.kittyKeyboardFlags == 1)
        t.feed("\u{1B}[?u")
        #expect(t.takeReplyString() == "\u{1B}[?1u")
        t.feed("\u{1B}[>5u")
        #expect(t.kittyKeyboardFlags == 5)
        t.feed("\u{1B}[<u")
        #expect(t.kittyKeyboardFlags == 1)
        t.feed("\u{1B}[<9u")
        #expect(t.kittyKeyboardFlags == 0)
        t.feed("\u{1B}[=3;1u")
        #expect(t.kittyKeyboardFlags == 3)
        t.feed("\u{1B}[=4;2u")
        #expect(t.kittyKeyboardFlags == 7)
        t.feed("\u{1B}[=1;3u")
        #expect(t.kittyKeyboardFlags == 6)
    }

    @Test func kittyKeyboardFlagsArePerScreen() {
        let t = makeTerminal()
        t.feed("\u{1B}[>1u\u{1B}[?1049h")
        #expect(t.kittyKeyboardFlags == 0)
        t.feed("\u{1B}[>31u")
        #expect(t.kittyKeyboardFlags == 31)
        t.feed("\u{1B}[?1049l")
        #expect(t.kittyKeyboardFlags == 1)
    }

    @Test func softResetResetsModesButNotTheScreen() {
        let t = makeTerminal()
        t.feed("abc\u{1B}[4h\u{1B}[?6h\u{1B}[?7l\u{1B}[?25l\u{1B}[1m\u{1B}[2;3r\u{1B}[!p")
        #expect(t.lines[0] == "abc")
        #expect(!t.modes.insert)
        #expect(!t.modes.origin)
        #expect(t.modes.autowrap)
        #expect(t.cursor.visible)
        #expect(t.currentStyle == .default)
        #expect(t.scrollRegion == 0...4)
    }

    @Test func fullResetClearsTheScreenButKeepsScrollback() {
        let t = makeTerminal(rows: 2)
        t.feed("\u{1B}]2;title\u{7}1\r\n2\r\n3\u{1B}[?2004h\u{1B}[1m\u{1B}c")
        #expect(t.lines == ["", ""])
        #expect(t.cursorPosition == [0, 0])
        #expect(t.scrollbackLines == ["1"])
        #expect(t.title == "")
        #expect(t.modes == TerminalModes())
        #expect(t.currentStyle == .default)
    }

    @Test func fullResetLeavesTheAlternateScreen() {
        let t = makeTerminal()
        t.feed("\u{1B}[?1049hfoo\u{1B}c")
        #expect(!t.isAlternateScreen)
    }
}
