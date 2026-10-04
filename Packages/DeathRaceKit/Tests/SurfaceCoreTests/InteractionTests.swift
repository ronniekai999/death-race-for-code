import ConfigKit
import ScreenProtocol
import Testing
import VTCore

@testable import SurfaceCore

private let cell = CellMetrics(
    width: 16, height: 32, baseline: 25, underlineTop: 27, underlineThickness: 1, strikethroughTop: 18,
    strikethroughThickness: 1, scale: 2)

@Suite struct CellGeometryTests {
    let geometry = CellGeometry(cell: cell, layout: GridLayout(columns: 80, rows: 24, left: 8, top: 6))

    @Test func pointsToCells() {
        #expect(geometry.column(atX: 8) == 0)
        #expect(geometry.column(atX: 15.9) == 0)
        #expect(geometry.column(atX: 16) == 1)
        #expect(geometry.column(atX: -50) == 0)
        #expect(geometry.column(atX: 5_000) == 79)
        #expect(geometry.row(atY: 6) == 0)
        #expect(geometry.row(atY: 22) == 1)
        #expect(geometry.row(atY: 0) == -1)
        #expect(geometry.row(atY: 6 + 24 * 16) == 24)
    }

    @Test func boundariesRoundToTheNearestEdge() {
        #expect(geometry.boundary(atX: 8) == 0)
        #expect(geometry.boundary(atX: 11.9) == 0)
        #expect(geometry.boundary(atX: 12.1) == 1)
        #expect(geometry.boundary(atX: 5_000) == 80)
    }

    @Test func pixelsAndRects() {
        #expect(geometry.pixel(atX: 8, y: 6) == (0, 0))
        #expect(geometry.pixel(atX: 9.5, y: 7) == (3, 2))
        #expect(geometry.pixel(atX: 1_000_000, y: -5) == (80 * 16 - 1, 0))
        let rect = geometry.rect(column: 2, row: 1, cells: 2)
        #expect(rect.x == 24 && rect.y == 22 && rect.width == 16 && rect.height == 16)
    }
}

/// Rows built by the engine, for selections to read words and lines from.
private func screen(_ text: String, columns: Int = 20, rows: Int = 4) -> Terminal {
    let terminal = Terminal(Terminal.Configuration(columns: columns, rows: rows))
    terminal.feed(text)
    return terminal
}

private func point(_ line: UInt64, _ column: Int, _ boundary: Int? = nil) -> Selection.Point {
    Selection.Point(line: line, column: column, boundary: boundary ?? column)
}

@Suite struct SelectionTests {
    @Test func wordsKeepPathsAndURLsWhole() {
        let t = screen("ls ~/code/death-race (https://x.io/a?b=1) \"q\"")
        let row = t.row(0)
        #expect(WordRules.word(in: row, at: 5) == 3...19)
        #expect(WordRules.word(in: row, at: 0) == 0...1)
        // A run of blanks is a word of its own.
        #expect(WordRules.word(in: row, at: 2) == 2...2)
        // The second row is " (https://x.io/a?b=1": brackets end words and are words of one
        // character; the URL is one word.
        #expect(WordRules.word(in: t.row(1), at: 0) == 0...0)
        #expect(WordRules.word(in: t.row(1), at: 1) == 1...1)
        #expect(WordRules.word(in: t.row(1), at: 3) == 2...19)
    }

    @Test func wideCharactersAreWholeInWords() {
        let t = screen("ab 中文字 cd")
        // From the right half of 文.
        #expect(WordRules.word(in: t.row(0), at: 6) == 3...8)
    }

    @Test func characterSelectionsRunBetweenBoundaries() {
        let t = screen("hello world")
        var selection = Selection(at: point(0, 1, 1), granularity: .character, rectangular: false, columns: 20) {
            t.line($0)
        }
        #expect(selection.range == nil)
        selection.extend(to: point(0, 4, 5), columns: 20) { t.line($0) }
        #expect(selection.range == TextRange(TextPoint(line: 0, column: 1), TextPoint(line: 0, column: 4)))
        // Dragging back past the start selects the other way.
        selection.extend(to: point(0, 0, 0), columns: 20) { t.line($0) }
        #expect(selection.range == TextRange(TextPoint(line: 0, column: 0), TextPoint(line: 0, column: 0)))
        // Onto the next line at its start: the first line to its end.
        selection.extend(to: point(1, 0, 0), columns: 20) { t.line($0) }
        let text = selection.range.map { range in TextExtractor.text(in: range) { t.line($0) } }
        #expect(text == "ello world\n")
    }

    @Test func wordSelectionsGrowByWords() {
        let t = screen("one two three four")
        var selection = Selection(at: point(0, 5), granularity: .word, rectangular: false, columns: 20) { t.line($0) }
        #expect(selection.range == TextRange(TextPoint(line: 0, column: 4), TextPoint(line: 0, column: 6)))
        selection.extend(to: point(0, 9), columns: 20) { t.line($0) }
        #expect(selection.range == TextRange(TextPoint(line: 0, column: 4), TextPoint(line: 0, column: 12)))
        // Back before the start: from that word to the end of the first one.
        selection.extend(to: point(0, 1), columns: 20) { t.line($0) }
        #expect(selection.range == TextRange(TextPoint(line: 0, column: 0), TextPoint(line: 0, column: 6)))
    }

    @Test func lineSelectionsFollowSoftWraps() {
        let t = screen("a long line that wraps around\r\nnext", columns: 10, rows: 5)
        let selection = Selection(at: point(1, 2), granularity: .line, rectangular: false, columns: 10) { t.line($0) }
        let text = selection.range.map { range in TextExtractor.text(in: range) { t.line($0) } }
        #expect(text == "a long line that wraps around")
    }

    @Test func rectanglesUseCells() {
        let t = screen("abcdef\r\nghijkl\r\nmnopqr")
        var selection = Selection(at: point(0, 1), granularity: .word, rectangular: true, columns: 20) { t.line($0) }
        selection.extend(to: point(2, 3), columns: 20) { t.line($0) }
        let text = selection.range.map { range in TextExtractor.text(in: range) { t.line($0) } }
        #expect(text == "bcd\nhij\nnop")
        #expect(selection.range?.isRectangular == true)
    }
}

@Suite struct PacingTests {
    @Test func trackpadDistanceAddsUpToLines() {
        var scroll = ScrollAccumulator()
        var lines: [Int] = []
        for delta in [10.0, 10, 40, -10, -6] {
            lines.append(scroll.lines(forDelta: delta, precise: true, cellHeight: 16, multiplier: 3))
        }
        // 10 points is less than a line; 20 is one with 4 over; 44 is two more. Turning back
        // starts afresh: -10 is nothing yet, -16 a line.
        #expect(lines == [0, 1, 2, 0, -1])
    }

    @Test func wheelNotchesAreMultipliedLines() {
        var scroll = ScrollAccumulator()
        var lines: [Int] = []
        for delta in [1.0, -2, 0.1, 0] {
            lines.append(scroll.lines(forDelta: delta, precise: false, cellHeight: 16, multiplier: 3))
        }
        #expect(lines == [3, -6, 1, 0])
    }

    @Test func theLinkPausesAfterThreeIdleTicks() {
        var pacer = FramePacer()
        var results: [Bool] = []
        results.append(pacer.wake())  // starts the link
        results.append(pacer.wake())  // already running
        results.append(pacer.tick(drew: true))
        results.append(pacer.tick(drew: false))
        results.append(pacer.tick(drew: false))
        results.append(pacer.wake())  // new work resets the count
        results.append(pacer.tick(drew: false))
        results.append(pacer.tick(drew: false))
        results.append(pacer.tick(drew: false))  // the third idle tick pauses
        #expect(results == [true, false, true, true, true, false, true, true, false])
        #expect(!pacer.isRunning)
        let restarted = pacer.wake()
        #expect(restarted)
    }

    @Test func percentiles() {
        var stats = LatencyStats(capacity: 100)
        #expect(stats.percentile(0.95) == nil)
        for value in 1...100 { stats.add(Double(value)) }
        #expect(stats.percentile(0.5) == 51)
        #expect(stats.percentile(0.95) == 95)
        // Only the latest samples count.
        for _ in 1...100 { stats.add(1_000) }
        #expect(stats.percentile(0.5) == 1_000)
        #expect(stats.count == 200)
    }
}

private func press(
    _ code: UInt16, _ flags: EventFlags = [], typed: String = "", plain: String? = nil, unmodified: String? = nil,
    repeat isRepeat: Bool = false
) -> KeyPress {
    KeyPress(
        keyCode: code, flags: flags, characters: typed, plainCharacters: plain ?? typed,
        unmodifiedCharacters: unmodified ?? (plain ?? typed).lowercased(), isRepeat: isRepeat)
}

@Suite struct KeyRoutingTests {
    @Test func typingGoesThroughTheInputMethod() {
        #expect(KeyRouting.route(press(0x00, typed: "a"), optionAsMeta: .left, composing: false) == .inputMethod)
        #expect(
            KeyRouting.route(press(0x00, .shift, typed: "A"), optionAsMeta: .left, composing: false) == .inputMethod)
    }

    @Test func keysThatTypeNothingAreEncodedAtOnce() {
        #expect(
            KeyRouting.route(press(0x7E, [.function]), optionAsMeta: .left, composing: false) == .encode(KeyEvent(.up)))
        #expect(
            KeyRouting.route(press(0x24, .shift), optionAsMeta: .left, composing: false)
                == .encode(KeyEvent(.enter, modifiers: .shift)))
        #expect(
            KeyRouting.route(press(0x7A, repeat: true), optionAsMeta: .left, composing: false)
                == .encode(KeyEvent(.function(1), action: .repeat)))
        #expect(
            KeyRouting.route(press(0x53, .numericPad, typed: "1"), optionAsMeta: .left, composing: false)
                == .encode(KeyEvent(.keypad(.digit(1)))))
    }

    @Test func controlChordsSkipTheInputMethod() {
        let route = KeyRouting.route(
            press(0x08, .control, typed: "\u{3}", plain: "c"), optionAsMeta: .left, composing: false)
        #expect(route == .encode(KeyEvent(.character("c"), modifiers: .control, text: "c")))
        guard case .encode(let event) = route else { return }
        #expect(KeyEncoder.encode(event, modes: TerminalModes(), kittyFlags: 0) == [0x03])
    }

    @Test func optionIsMetaOnTheConfiguredSide() {
        let left = press(0x03, [.option, .leftOption], typed: "ƒ", plain: "f")
        let right = press(0x03, [.option, .rightOption], typed: "ƒ", plain: "f")
        #expect(
            KeyRouting.route(left, optionAsMeta: .left, composing: false)
                == .encode(KeyEvent(.character("f"), modifiers: .alt, text: "f")))
        // The right Option types the layout's character.
        #expect(KeyRouting.route(right, optionAsMeta: .left, composing: false) == .inputMethod)
        #expect(KeyRouting.route(right, optionAsMeta: .right, composing: false) != .inputMethod)
        #expect(KeyRouting.route(left, optionAsMeta: .neither, composing: false) == .inputMethod)
        #expect(KeyRouting.route(left, optionAsMeta: .both, composing: false) != .inputMethod)
        // With Shift: Meta and the shifted character.
        let shifted = press(0x03, [.option, .leftOption, .shift], typed: "Ï", plain: "F", unmodified: "f")
        #expect(
            KeyRouting.route(shifted, optionAsMeta: .left, composing: false)
                == .encode(KeyEvent(.character("f"), modifiers: [.alt, .shift], text: "F")))
        guard case .encode(let event) = KeyRouting.route(left, optionAsMeta: .left, composing: false) else { return }
        #expect(KeyEncoder.encode(event, modes: TerminalModes(), kittyFlags: 0) == [0x1B, 0x66])
    }

    @Test func eventsWithoutSideBitsCountAsTheLeftOption() {
        #expect(KeyRouting.optionIsMeta([.option], .left))
        #expect(!KeyRouting.optionIsMeta([.option], .right))
        #expect(!KeyRouting.optionIsMeta([.leftOption], .left))
    }

    @Test func composingGetsEverything() {
        #expect(KeyRouting.route(press(0x7B), optionAsMeta: .left, composing: true) == .inputMethod)
        #expect(
            KeyRouting.route(press(0x08, .control, typed: "\u{3}", plain: "c"), optionAsMeta: .left, composing: true)
                == .inputMethod)
    }

    @Test func otherLayoutsReportTheirUSKey() {
        // The key that types ф in a Russian layout is the US "a".
        let route = KeyRouting.route(
            press(0x00, .control, typed: "\u{1}", plain: "ф", unmodified: "ф"), optionAsMeta: .left, composing: false)
        #expect(route == .encode(KeyEvent(.character("ф"), modifiers: .control, text: "ф", baseLayoutKey: "a")))
    }

    @Test func insertedTextBecomesAKeyEvent() {
        let event = KeyRouting.textEvent("é", press: press(0x0E, typed: "é", plain: "é", unmodified: "e"))
        #expect(event == KeyEvent(.character("e"), text: "é"))
        let composed = KeyRouting.textEvent("日本", press: nil)
        #expect(composed.text == "日本")
        #expect(KeyEncoder.encode(composed, modes: TerminalModes(), kittyFlags: 0) == Array("日本".utf8))
    }

    @Test func keyCodes() {
        #expect(MacKeyCode.key(for: 0x35) == .escape)
        #expect(MacKeyCode.key(for: 0x72) == .insert)
        #expect(MacKeyCode.key(for: 0x6F) == .function(12))
        #expect(MacKeyCode.key(for: 0x5A) == .function(20))
        #expect(MacKeyCode.key(for: 0x4C) == .keypad(.enter))
        #expect(MacKeyCode.key(for: 0x3D) == .modifier(.rightAlt))
        #expect(MacKeyCode.key(for: 0x00) == nil)
        #expect(MacKeyCode.usLayoutCharacter(for: 0x32) == "`")
    }
}

@Suite struct DropAndDirectoryTests {
    @Test func pathsAreQuotedLikeTerminal() {
        #expect(ShellQuoting.quote("/Users/me/notes.md") == "/Users/me/notes.md")
        #expect(ShellQuoting.quote("/Users/me/My Files/a&b (1).txt") == "/Users/me/My\\ Files/a\\&b\\ \\(1\\).txt")
        #expect(ShellQuoting.quote("~start") == "\\~start")
        #expect(ShellQuoting.quote("/tmp/café.txt") == "/tmp/café.txt")
        #expect(ShellQuoting.quote("/tmp/new\nline's") == "'/tmp/new\nline'\\''s'")
        #expect(ShellQuoting.quote(paths: ["/a b", "/c"]) == "/a\\ b /c ")
    }

    @Test func localDirectoriesFromOSC7() {
        let names: Set<String> = ["Ronnies-MacBook-Pro.local"]
        #expect(WorkingDirectoryURL.path(from: "file:///Users/me", localHostNames: names) == "/Users/me")
        #expect(WorkingDirectoryURL.path(from: "file://localhost/tmp", localHostNames: names) == "/tmp")
        #expect(
            WorkingDirectoryURL.path(from: "file://ronnies-macbook-pro/Users/me/My%20Code", localHostNames: names)
                == "/Users/me/My Code")
        #expect(WorkingDirectoryURL.path(from: "file://server.example.com/home/me", localHostNames: names) == nil)
        #expect(WorkingDirectoryURL.path(from: "kitty-shell-cwd://localhost/a%20b", localHostNames: names) == "/a%20b")
        #expect(WorkingDirectoryURL.path(from: "/Users/me", localHostNames: names) == nil)
        #expect(WorkingDirectoryURL.path(from: "file:///bad%2", localHostNames: names) == nil)
        #expect(WorkingDirectoryURL.path(from: "file:///nul%00", localHostNames: names) == nil)
        #expect(WorkingDirectoryURL.path(from: "file:///%E6%97%A5", localHostNames: names) == "/日")
        #expect(WorkingDirectoryURL.path(from: "file:///%FF", localHostNames: names) == nil)
    }
}

@Suite struct SecureInputTests {
    @Test func autoFollowsPasswordsAndTheMenu() {
        var secure = SecureInput(mode: .auto)
        #expect(!secure.desired)
        secure.appIsActive = true
        secure.focusedTabReadsPassword = true
        #expect(secure.desired)
        secure.focusedTabReadsPassword = false
        secure.menuChecked = true
        #expect(secure.desired)
        // Never in the background.
        secure.appIsActive = false
        #expect(!secure.desired)
    }

    @Test func alwaysAndManual() {
        var always = SecureInput(mode: .always)
        always.appIsActive = true
        #expect(always.desired)
        var manual = SecureInput(mode: .manual)
        manual.appIsActive = true
        manual.focusedTabReadsPassword = true
        #expect(!manual.desired)
        manual.menuChecked = true
        #expect(manual.desired)
    }

    @Test func callsStayBalanced() {
        var secure = SecureInput(mode: .always)
        var calls: [String] = []
        let enable = {
            calls.append("on")
            return true
        }
        let disable = {
            calls.append("off")
            return true
        }
        secure.apply(enable: enable, disable: disable)
        #expect(calls.isEmpty)
        secure.appIsActive = true
        secure.apply(enable: enable, disable: disable)
        secure.apply(enable: enable, disable: disable)
        secure.appIsActive = false
        secure.apply(enable: enable, disable: disable)
        secure.apply(enable: enable, disable: disable)
        #expect(calls == ["on", "off"])
        // A failed call is retried next time rather than recorded.
        secure.appIsActive = true
        secure.apply(enable: { false }, disable: disable)
        #expect(!secure.isEnabled)
        secure.apply(enable: enable, disable: disable)
        #expect(secure.isEnabled)
    }
}

@Suite struct PreeditLayoutTests {
    @Test func atTheCursor() {
        let layout = PreeditLayout(text: "にほん", cursorColumn: 2, cursorRow: 3, columns: 20)
        #expect(layout.row == 3)
        #expect(layout.cells.map(\.column) == [2, 4, 6])
        #expect(layout.cells.allSatisfy { $0.isWide })
        #expect(layout.caretColumn == 8)
    }

    @Test func movedLeftNearTheEdgeAndCutWhenTooWide() {
        let near = PreeditLayout(text: "日本語", cursorColumn: 17, cursorRow: 0, columns: 20)
        #expect(near.cells.map(\.column) == [14, 16, 18])
        let tooWide = PreeditLayout(text: "日本語です", cursorColumn: 0, cursorRow: 0, columns: 7)
        #expect(tooWide.cells.map(\.column) == [0, 2, 4])
    }

    @Test func theCaretCanBeInside() {
        let layout = PreeditLayout(text: "abc", cursorColumn: 5, cursorRow: 0, columns: 20, caret: 1)
        #expect(layout.caretColumn == 6)
        #expect(layout.cells.map(\.isWide) == [false, false, false])
    }
}
