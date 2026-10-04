import Testing

@testable import VTCore

@Suite struct TerminalOSCTests {
    @Test func titlesAndIconNames() {
        let t = makeTerminal()
        t.feed("\u{1B}]0;both\u{7}")
        #expect(t.title == "both")
        #expect(t.iconName == "both")
        #expect(t.takeEvents() == [.titleChanged("both"), .iconNameChanged("both")])
        t.feed("\u{1B}]2;window\u{1B}\\\u{1B}]1;icon\u{7}")
        #expect(t.title == "window")
        #expect(t.iconName == "icon")
    }

    @Test func titlesAreCapped() {
        let t = makeTerminal()
        t.feed("\u{1B}]2;" + String(repeating: "x", count: 10_000) + "\u{7}")
        #expect(t.title.utf8.count == Terminal.maxTextLength)
    }

    @Test func titlesKeepUTF8() {
        let t = makeTerminal()
        t.feed("\u{1B}]2;Legends Never Die ✦ 999\u{7}")
        #expect(t.title == "Legends Never Die ✦ 999")
    }

    @Test func workingDirectory() {
        let t = makeTerminal()
        t.feed("\u{1B}]7;file://host/Users/me/code\u{7}")
        #expect(t.workingDirectory == "file://host/Users/me/code")
        #expect(t.takeEvents() == [.workingDirectoryChanged("file://host/Users/me/code")])
    }

    @Test func paletteColorsSetQueryAndReset() {
        let t = makeTerminal()
        t.feed("\u{1B}]4;1;rgb:ff/00/80;2;#00ff00\u{7}")
        #expect(t.palette.colors[1] == RGB(0xFF, 0x00, 0x80))
        #expect(t.palette.colors[2] == RGB(0x00, 0xFF, 0x00))
        #expect(t.takeEvents() == [.colorsChanged])
        t.feed("\u{1B}]4;1;?\u{7}")
        #expect(t.takeReplyString() == "\u{1B}]4;1;rgb:ffff/0000/8080\u{7}")
        t.feed("\u{1B}]104;1\u{7}")
        #expect(t.palette.colors[1] == t.configuration.palette.colors[1])
        #expect(t.palette.colors[2] == RGB(0x00, 0xFF, 0x00))
        t.feed("\u{1B}]104\u{7}")
        #expect(t.palette == t.configuration.palette)
    }

    @Test func dynamicColorsAnswerWithTheQuerysTerminator() {
        let t = makeTerminal()
        t.feed("\u{1B}]11;#102030\u{7}")
        #expect(t.palette.background == RGB(0x10, 0x20, 0x30))
        t.feed("\u{1B}]11;?\u{1B}\\")
        #expect(t.takeReplyString() == "\u{1B}]11;rgb:1010/2020/3030\u{1B}\\")
        t.feed("\u{1B}]10;?;?\u{7}")
        let fg = t.palette.foreground
        let bg = t.palette.background
        #expect(t.takeReplyString() == "\u{1B}]10;\(fg.x11)\u{7}\u{1B}]11;\(bg.x11)\u{7}")
        t.feed("\u{1B}]111\u{7}")
        #expect(t.palette.background == t.configuration.palette.background)
    }

    /// The app's theme changes under a running program: what the program set stays, the rest
    /// follows the theme, and resets and queries use the new theme.
    @Test func aNewBasePaletteKeepsWhatProgramsSet() {
        let t = makeTerminal()
        t.feed("\u{1B}]4;1;#010203\u{7}\u{1B}]11;#040506\u{7}")
        _ = t.takeEvents()
        t.setBasePalette(.xterm)
        #expect(t.palette.colors[1] == RGB(1, 2, 3))
        #expect(t.palette.colors[2] == Palette.xterm.colors[2])
        #expect(t.palette.background == RGB(4, 5, 6))
        #expect(t.palette.foreground == Palette.xterm.foreground)
        #expect(t.palette.cursor == Palette.xterm.cursor)
        #expect(t.takeEvents() == [.colorsChanged])

        t.feed("\u{1B}]104;1\u{7}\u{1B}]111\u{7}")
        #expect(t.palette == Palette.xterm)
        // Reset, they follow the theme again.
        t.setBasePalette(.legendsNeverDie)
        #expect(t.palette == Palette.legendsNeverDie)
        t.feed("\u{1B}]11;?\u{7}")
        #expect(t.takeReplyString() == "\u{1B}]11;rgb:1010/0808/2222\u{7}")
    }

    @Test func aFullResetForgetsWhatProgramsSet() {
        let t = makeTerminal()
        t.feed("\u{1B}]4;5;#010203\u{7}\u{1B}]10;#040506\u{7}\u{1B}c")
        t.setBasePalette(.xterm)
        #expect(t.palette == Palette.xterm)
    }

    @Test func clipboardWritesAreEventsAndReadsAreRefused() {
        let t = makeTerminal()
        t.feed("\u{1B}]52;c;aGVsbG8=\u{7}")
        #expect(t.takeEvents() == [.clipboardWrite(selection: "c", contents: Array("hello".utf8))])
        t.feed("\u{1B}]52;;d29ybGQ=\u{7}")
        #expect(t.takeEvents() == [.clipboardWrite(selection: "c", contents: Array("world".utf8))])
        t.feed("\u{1B}]52;c;?\u{7}")
        #expect(t.takeEvents().isEmpty)
        #expect(t.takeReplies().isEmpty)
        t.feed("\u{1B}]52;c;not base64!\u{7}")
        #expect(t.takeEvents().isEmpty)
    }

    @Test func promptMarksLandOnTheCursorRow() {
        let t = makeTerminal()
        t.feed("\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}ls\r\n\u{1B}]133;C\u{7}file\r\n")
        t.feed("\u{1B}]133;D;1\u{7}\u{1B}]133;A\u{7}$ ")
        #expect(t.row(0).promptMarks == [.promptStart, .commandStart])
        #expect(t.row(1).promptMarks == .outputStart)
        #expect(t.row(2).promptMarks == [.commandEnd, .promptStart])
        #expect(t.row(2).exitCode == 1)
        let events = t.takeEvents()
        #expect(events.first == .promptMark(.promptStart, rowID: t.row(0).id))
        #expect(events.dropLast().last == .promptMark(.commandEnd(exitCode: 1), rowID: t.row(2).id))
    }

    @Test func promptMarksScrollWithTheirRows() {
        let t = makeTerminal(rows: 2)
        t.feed("\u{1B}]133;A\u{7}$ ls\r\na\r\nb")
        #expect(t.scrollbackRow(0).promptMarks == .promptStart)
        #expect(t.row(0).promptMarks.isEmpty)
    }

    @Test func notifications() {
        let t = makeTerminal()
        t.feed("\u{1B}]9;Build finished\u{7}\u{1B}]777;notify;Ring Ring;Tests passed\u{7}")
        #expect(
            t.takeEvents() == [
                .notification(title: "", body: "Build finished"),
                .notification(title: "Ring Ring", body: "Tests passed"),
            ])
    }

    @Test func progressReports() {
        let t = makeTerminal()
        t.feed("\u{1B}]9;4;1;42\u{7}\u{1B}]9;4;2\u{7}\u{1B}]9;4;3\u{7}\u{1B}]9;4;4;150\u{7}\u{1B}]9;4;0\u{7}")
        #expect(
            t.takeEvents() == [
                .progress(.normal(percent: 42)), .progress(.error(percent: nil)), .progress(.indeterminate),
                .progress(.paused(percent: 100)), .progress(.cleared),
            ])
    }

    @Test func unknownCommandsAreIgnored() {
        let t = makeTerminal()
        t.feed("\u{1B}]8;;https://example.com\u{7}link\u{1B}]8;;\u{7}\u{1B}]5000;x\u{7}\u{1B}]nope\u{7}")
        #expect(t.lines[0] == "link")
        #expect(t.takeEvents().isEmpty)
    }
}

/// Events wait in the terminal until a host takes them; a burst folds to what it changed.
@Suite struct TerminalEventFoldingTests {
    @Test func aBurstFoldsToItsOutcome() {
        let events: [TerminalEvent] =
            [.bell, .titleChanged("a"), .bell, .colorsChanged, .titleChanged("b"), .colorsChanged]
        #expect(TerminalEvent.coalesced(events) == [.bell, .titleChanged("b"), .colorsChanged])
    }

    @Test func notificationsAndPromptMarksKeepTheNewest() {
        let notes = (0..<20).map { TerminalEvent.notification(title: "", body: "\($0)") }
        #expect(TerminalEvent.coalesced(notes) == Array(notes.suffix(16)))
        let marks = (0..<100).map { TerminalEvent.promptMark(.promptStart, rowID: UInt64($0)) }
        #expect(TerminalEvent.coalesced(marks) == Array(marks.suffix(64)))
    }

    @Test func aTerminalNobodyReadsKeepsFewEvents() {
        let t = makeTerminal()
        for i in 0..<10_000 { t.feed("\u{7}\u{1B}]2;lap \(i)\u{7}") }
        #expect(t.events.count < Terminal.eventFoldThreshold)
        #expect(TerminalEvent.coalesced(t.takeEvents()) == [.bell, .titleChanged("lap 9999")])
    }
}
