import Testing
import VTCore

@testable import ScreenProtocol

/// A session's side and an app's side, connected the way SessionKit connects them.
private struct Link {
    let terminal: Terminal
    var builder = DeltaBuilder()
    var mirror = MirrorGrid()
    /// Send every delta through the byte codec, as the daemon will.
    var viaCodec = true

    init(columns: Int = 10, rows: Int = 4, scrollback: Int = 50 * 1024 * 1024) {
        terminal = Terminal(Terminal.Configuration(columns: columns, rows: rows, scrollbackLimitBytes: scrollback))
    }

    /// Builds a delta, delivers it, and returns it.
    @discardableResult
    mutating func sync() throws -> ScreenDelta {
        var delta = builder.makeDelta(from: terminal, events: terminal.takeEvents())
        if viaCodec { delta = try DeltaCodec.decode(DeltaCodec.encode(delta)) }
        try mirror.apply(delta)
        builder.didDeliver(delta)
        return delta
    }

    /// What a client starting from nothing would see now.
    func freshSnapshot() -> [RowSnapshot] {
        var fresh = DeltaBuilder()
        fresh.scroll(by: builder.viewportOffset, in: terminal)
        return fresh.makeDelta(from: terminal, events: []).changedRows
    }
}

private func text(_ row: RowSnapshot) -> String {
    var out = ""
    for column in row.cells.indices where row.cells[column].width != .spacerTail {
        let scalars = row.scalars(at: column)
        if scalars.isEmpty {
            out += " "
        } else {
            for scalar in scalars { out.unicodeScalars.append(Unicode.Scalar(scalar)!) }
        }
    }
    while out.hasSuffix(" ") { out.removeLast() }
    return out
}

@Suite struct DeltaTests {
    @Test func theFirstDeltaIsASnapshot() throws {
        var link = Link()
        link.terminal.feed("hello\r\nworld")
        let delta = try link.sync()
        #expect(delta.isSnapshot)
        #expect(delta.changedRows.count == 4)
        #expect(link.mirror.lines.map(text) == ["hello", "world", "", ""])
        #expect(link.mirror.cursor.x == 5 && link.mirror.cursor.y == 1)
        #expect(delta.palette != nil)
    }

    @Test func laterDeltasCarryOnlyChangedRows() throws {
        var link = Link()
        link.terminal.feed("hello\r\nworld")
        try link.sync()
        link.terminal.feed("\u{1B}[4;1Hbye")
        let delta = try link.sync()
        #expect(!delta.isSnapshot)
        #expect(delta.changedRows.map(\.id) == [link.terminal.row(3).id])
        #expect(delta.palette == nil)
        #expect(link.mirror.lines.map(text) == ["hello", "world", "", "bye"])
    }

    @Test func scrollingSendsOnlyTheNewLine() throws {
        var link = Link()
        link.terminal.feed("1\r\n2\r\n3\r\n4")
        try link.sync()
        link.terminal.feed("\r\n5")
        let delta = try link.sync()
        #expect(delta.changedRows.count == 1)
        #expect(link.mirror.lines.map(text) == ["2", "3", "4", "5"])
        #expect(link.mirror.scrollbackCount == 1)
    }

    @Test func nothingChangedMeansNothingToSend() throws {
        var link = Link()
        link.terminal.feed("x")
        try link.sync()
        let delta = try link.sync()
        #expect(delta.changedRows.isEmpty)
    }

    @Test func aReplacedUnsentDeltaLosesNothing() throws {
        var link = Link()
        link.terminal.feed("a")
        try link.sync()
        // A delta the app never takes...
        link.terminal.feed("\r\nb\u{7}")
        let unsent = link.builder.makeDelta(from: link.terminal, events: link.terminal.takeEvents())
        // ...is replaced by a newer one, made relative to what the app has.
        link.terminal.feed("\r\nc")
        let newer = link.builder.makeDelta(from: link.terminal, events: link.terminal.takeEvents())
            .merging(unsent: unsent)
        try link.mirror.apply(newer)
        link.builder.didDeliver(newer)
        #expect(link.mirror.lines.map(text) == ["a", "b", "c", ""])
        #expect(newer.events == [.bell])
    }

    @Test func screenSwitchesAndResizesAreSnapshots() throws {
        var link = Link()
        link.terminal.feed("primary")
        try link.sync()
        link.terminal.feed("\u{1B}[?1049halt")
        #expect(try link.sync().isSnapshot)
        #expect(link.mirror.lines[0].cells.count == 10)
        #expect(link.mirror.isAlternateScreen)
        link.terminal.resize(columns: 12, rows: 3)
        let delta = try link.sync()
        #expect(delta.isSnapshot)
        #expect(link.mirror.columns == 12 && link.mirror.rows == 3)
    }

    @Test func aMirrorRefusesADeltaItCannotApply() throws {
        var link = Link()
        link.terminal.feed("x")
        let first = link.builder.makeDelta(from: link.terminal, events: [])
        link.builder.didDeliver(first)
        link.terminal.feed("y")
        let second = link.builder.makeDelta(from: link.terminal, events: [])
        // The mirror never saw the first delta.
        var mirror = MirrorGrid()
        #expect(throws: MirrorGrid.ApplyError.needsSnapshot) { try mirror.apply(second) }
        #expect(mirror.lines.isEmpty)
    }

    /// The app took a delta and never applied it. The next one builds on it, so applying that
    /// would leave the skipped rows stale: the mirror must refuse it, and a snapshot recovers.
    @Test func aMirrorRefusesADeltaBuiltOnOneItSkipped() throws {
        var link = Link()
        link.terminal.feed("one")
        try link.sync()
        link.terminal.feed("\r\ntwo")
        let skipped = link.builder.makeDelta(from: link.terminal, events: [])
        link.builder.didDeliver(skipped)
        link.terminal.feed("\r\nthree")
        let next = link.builder.makeDelta(from: link.terminal, events: [])
        #expect(next.baseVersion == skipped.version)
        #expect(throws: MirrorGrid.ApplyError.needsSnapshot) { try link.mirror.apply(next) }
        #expect(link.mirror.lines.map(text) == ["one", "", "", ""])
        link.builder.reset()
        #expect(try link.sync().isSnapshot)
        #expect(link.mirror.lines.map(text) == ["one", "two", "three", ""])
    }

    @Test func unsentDeltasFoldTheirEvents() throws {
        var link = Link()
        try link.sync()
        var unsent = link.builder.makeDelta(from: link.terminal, events: [])
        for i in 0..<1_000 {
            link.terminal.feed("\u{7}\u{1B}]2;lap \(i)\u{7}")
            unsent = link.builder.makeDelta(from: link.terminal, events: link.terminal.takeEvents())
                .merging(unsent: unsent)
        }
        #expect(unsent.events == [.bell, .titleChanged("lap 999")])
    }

    @Test func colorsTravelWhenTheyChange() throws {
        var link = Link()
        try link.sync()
        link.terminal.feed("\u{1B}]11;#123456\u{7}")
        let delta = try link.sync()
        #expect(delta.palette?.background == RGB(0x12, 0x34, 0x56))
        #expect(link.mirror.palette.background == RGB(0x12, 0x34, 0x56))
        #expect(try link.sync().palette == nil)
    }

    @Test func modesAndKittyFlagsAreMirrored() throws {
        var link = Link()
        link.terminal.feed("\u{1B}[?2004h\u{1B}[?1006h\u{1B}[?1002h\u{1B}[>11u\u{1B}[5 q")
        try link.sync()
        #expect(link.mirror.modes.bracketedPaste)
        #expect(link.mirror.modes.mouseEncoding == .sgr)
        #expect(link.mirror.modes.mouseTracking == .buttonEvent)
        #expect(link.mirror.kittyFlags == 11)
        #expect(link.mirror.cursor.shape == .bar)
        #expect(link.mirror.cursor.blinks == true)
    }
}

@Suite struct ViewportTests {
    private func scrolled() throws -> Link {
        var link = Link()
        for line in 1...10 { link.terminal.feed("\(line)\r\n") }
        link.terminal.feed("11")
        try link.sync()
        return link
    }

    @Test func scrollingBackShowsHistory() throws {
        var link = try scrolled()
        link.builder.scroll(by: 3, in: link.terminal)
        try link.sync()
        #expect(link.mirror.lines.map(text) == ["5", "6", "7", "8"])
        #expect(link.mirror.viewportOffset == 3)
        link.builder.scroll(by: 100, in: link.terminal)
        try link.sync()
        #expect(link.mirror.lines.map(text) == ["1", "2", "3", "4"])
    }

    @Test func aScrolledBackViewportStaysOnItsLines() throws {
        var link = try scrolled()
        link.builder.scroll(by: 3, in: link.terminal)
        try link.sync()
        link.terminal.feed("\r\n12\r\n13")
        let delta = try link.sync()
        #expect(link.mirror.lines.map(text) == ["5", "6", "7", "8"])
        #expect(link.mirror.viewportOffset == 5)
        #expect(delta.changedRows.isEmpty)
    }

    @Test func atTheBottomTheViewportFollowsOutput() throws {
        var link = try scrolled()
        link.builder.scroll(by: 2, in: link.terminal)
        link.builder.scrollToBottom()
        link.terminal.feed("\r\n12")
        try link.sync()
        #expect(link.mirror.lines.map(text) == ["9", "10", "11", "12"])
    }

    /// Lines keep their numbers as output scrolls, whether scrollback keeps them, trims them
    /// or keeps none at all. "1" is printed first, so it is line 0.
    @Test(arguments: [50 * 1024 * 1024, 2_000, 0])
    func lineNumbersStayWithTheirLines(scrollback: Int) throws {
        var link = Link(columns: 10, rows: 4, scrollback: scrollback)
        for n in 1...30 { link.terminal.feed("\(n)\r\n") }
        link.terminal.feed("31")
        try link.sync()
        #expect(link.mirror.lines.map(text) == ["28", "29", "30", "31"])
        #expect(link.mirror.viewportTopLine == 27)
        #expect(link.terminal.linesScrolledOff == 27)
        guard scrollback > 0 else { return }
        link.builder.scroll(by: 3, in: link.terminal)
        try link.sync()
        #expect(link.mirror.lines.map(text) == ["25", "26", "27", "28"])
        #expect(link.mirror.viewportTopLine == 24)
        // Output below a scrolled-back view moves nothing in it, numbers included.
        link.terminal.feed("\r\n32\r\n33")
        try link.sync()
        #expect(link.mirror.lines.map(text) == ["25", "26", "27", "28"])
        #expect(link.mirror.viewportTopLine == 24)
    }

    @Test func theAlternateScreenNumbersItsOwnLines() throws {
        var link = Link(columns: 10, rows: 4)
        link.terminal.feed("a\r\nb\r\nc\r\nd\r\ne")
        try link.sync()
        #expect(link.mirror.viewportTopLine == 1)
        link.terminal.feed("\u{1B}[?1049h\u{1B}[H1\r\n2\r\n3\r\n4\r\n5\r\n6")
        try link.sync()
        #expect(link.mirror.lines.map(text) == ["3", "4", "5", "6"])
        #expect(link.mirror.viewportTopLine == 2)
        link.terminal.feed("\u{1B}[?1049l")
        try link.sync()
        #expect(link.mirror.viewportTopLine == 1)
    }

    @Test func aResizeReturnsToTheBottom() throws {
        var link = try scrolled()
        link.builder.scroll(by: 3, in: link.terminal)
        try link.sync()
        link.terminal.resize(columns: 8, rows: 4)
        try link.sync()
        #expect(link.mirror.viewportOffset == 0)
        #expect(link.mirror.lines.map(text) == ["8", "9", "10", "11"])
    }
}

@Suite struct DeltaEquivalenceTests {
    /// Random output in random chunks: after every delta the mirror must hold exactly what a
    /// client starting from nothing would see.
    @Test(arguments: 0..<40)
    func deltasReproduceTheScreen(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        var link = Link(columns: 1 + Int(rng.next() % 30), rows: 1 + Int(rng.next() % 8), scrollback: 4096)
        link.viaCodec = seed % 2 == 0
        var stream: [UInt8] = []
        for _ in 0..<200 { stream += randomPiece(&rng) }
        var index = 0
        while index < stream.count {
            let n = 1 + Int(rng.next() % 64)
            link.terminal.feed(Array(stream[index..<min(stream.count, index + n)]))
            index += n
            if rng.next() % 5 == 0 { link.builder.scroll(by: Int(rng.next() % 7) - 3, in: link.terminal) }
            if rng.next() % 17 == 0 {
                link.terminal.resize(columns: 1 + Int(rng.next() % 30), rows: 1 + Int(rng.next() % 8))
            }
            try link.sync()
            #expect(link.mirror.lines == link.freshSnapshot())
            #expect(link.mirror.cursor.x == link.terminal.cursor.x && link.mirror.cursor.y == link.terminal.cursor.y)
        }
    }

    private func randomPiece(_ rng: inout SplitMix64) -> [UInt8] {
        let pieces = [
            "hello ", "wide 中文 ", "e\u{301}", "👨‍👩‍👧", "\r\n", "\n", "\r", "\t", "\u{8}",
            "\u{1B}[31m", "\u{1B}[0m", "\u{1B}[1;38;2;10;20;30m", "\u{1B}[44m", "\u{1B}[K", "\u{1B}[2J", "\u{1B}[J",
            "\u{1B}[H", "\u{1B}[3;5H", "\u{1B}[2A", "\u{1B}[5C", "\u{1B}[L", "\u{1B}[M", "\u{1B}[2P", "\u{1B}[3@",
            "\u{1B}[2X", "\u{1B}[S", "\u{1B}[T", "\u{1B}[2;3r", "\u{1B}[r", "\u{1B}M", "\u{1B}D", "\u{1B}7", "\u{1B}8",
            "\u{1B}[?1049h", "\u{1B}[?1049l", "\u{1B}[?7l", "\u{1B}[?7h", "\u{1B}[4h", "\u{1B}[4l", "\u{1B}]133;A\u{7}",
            "\u{1B}]2;title\u{7}", "\u{1B}(0lqk\u{1B}(B", "\u{1B}#8", "\u{1B}[3J", "\u{1B}c", "x\u{1B}[3b",
            "0123456789abcdefghij",
        ]
        let piece = pieces[Int(rng.next() % UInt64(pieces.count))]
        return Array(piece.utf8)
    }
}

@Suite struct DeltaCodecTests {
    private func richDelta() -> ScreenDelta {
        var modes = TerminalModes()
        for keyPath in DeltaCodec.booleanModes { modes[keyPath: keyPath].toggle() }
        modes.mouseTracking = .anyEvent
        modes.mouseEncoding = .sgrPixels
        var palette = Palette.legendsNeverDie
        palette.colors[7] = RGB(1, 2, 3)
        let row = RowSnapshot(
            id: 42, version: 7,
            cells: [
                Cell(scalar: 0x41, styleID: 1), Cell(scalar: 0x4E2D, width: .wide, styleID: 0),
                Cell(scalar: 0, width: .spacerTail, styleID: 0), Cell(content: 0x65 | 1 << 21, styleID: 0),
            ],
            styles: [
                .default,
                Style(
                    foreground: .rgb(1, 2, 3), background: .indexed(200), underlineColor: .indexed(5),
                    attributes: [.bold, .italic], underline: .curly),
            ],
            graphemes: [3: [0x301]], isWrapped: true, promptMarks: [.promptStart, .commandEnd], exitCode: -1)
        return ScreenDelta(
            generation: 3, version: 99, isSnapshot: false, columns: 4, rows: 1, viewportOffset: 2,
            scrollbackCount: 10, viewportTopLine: 0x1234_5678_9ABC, rowIDs: [42], changedRows: [row],
            cursor: CursorSnapshot(x: 3, y: 0, pendingWrap: true, visible: false, shape: .underline, blinks: false),
            modes: modes, kittyFlags: 31, isAlternateScreen: true, title: "Legends ✦ 999", palette: palette,
            events: [
                .bell, .titleChanged("t"), .iconNameChanged("i"), .workingDirectoryChanged("file:///tmp"),
                .notification(title: "Ring Ring", body: "done"), .progress(.cleared), .progress(.normal(percent: 42)),
                .progress(.error(percent: nil)), .progress(.indeterminate), .progress(.paused(percent: 7)),
                .clipboardWrite(selection: "c", contents: [0, 1, 255]),
                .promptMark(.promptStart, rowID: 1), .promptMark(.commandEnd(exitCode: 2), rowID: 3),
                .promptMark(.commandEnd(exitCode: nil), rowID: 4), .colorsChanged, .screenReplaced,
            ], readingPassword: true)
    }

    @Test func roundTrips() throws {
        let delta = richDelta()
        #expect(try DeltaCodec.decode(DeltaCodec.encode(delta)) == delta)
    }

    @Test func everyBooleanModeIsEncoded() {
        let booleans = Mirror(reflecting: TerminalModes()).children.filter { $0.value is Bool }
        #expect(booleans.count == DeltaCodec.booleanModes.count)
    }

    @Test func everyTruncationFailsCleanly() {
        let bytes = DeltaCodec.encode(richDelta())
        for length in 0..<bytes.count {
            #expect(throws: DeltaCodec.DecodeError.self) { try DeltaCodec.decode(Array(bytes[..<length])) }
        }
    }

    @Test func corruptionNeverCrashes() {
        let bytes = DeltaCodec.encode(richDelta())
        var rng = SplitMix64(seed: 7)
        for _ in 0..<2_000 {
            var corrupted = bytes
            for _ in 0..<1 + Int(rng.next() % 4) {
                corrupted[Int(rng.next() % UInt64(corrupted.count))] = UInt8(truncatingIfNeeded: rng.next())
            }
            _ = try? DeltaCodec.decode(corrupted)
        }
    }

    @Test func forgedCountsDoNotAllocate() {
        var w = ByteWriter()
        w.bytes.append(contentsOf: DeltaCodec.magic)
        w.u8(DeltaCodec.formatVersion)
        w.u64(0)  // generation
        w.u64(0)  // version
        w.u64(0)  // base version
        w.bool(true)
        for _ in 0..<4 { w.u32(1) }  // columns, rows, viewport offset, scrollback count
        w.u64(0)  // viewport top line
        w.u32(UInt32.max)  // "four billion row ids"
        #expect(throws: DeltaCodec.DecodeError.truncated) { try DeltaCodec.decode(w.bytes) }
    }

    @Test func forgedSizesAndLineNumbersAreRejected() {
        var huge = richDelta()
        huge.columns = DeltaCodec.maxDimension + 1
        #expect(throws: DeltaCodec.DecodeError.invalid("screen size")) {
            try DeltaCodec.decode(DeltaCodec.encode(huge))
        }
        // The rows below the top line would count past the largest line number.
        var late = richDelta()
        late.viewportTopLine = UInt64.max
        #expect(throws: DeltaCodec.DecodeError.invalid("line number")) {
            try DeltaCodec.decode(DeltaCodec.encode(late))
        }
    }

    @Test func badHeadersAreRejected() {
        #expect(throws: DeltaCodec.DecodeError.badMagic) { try DeltaCodec.decode(Array("NOPE".utf8) + [1]) }
        var bytes = DeltaCodec.encode(richDelta())
        bytes[4] = 200
        #expect(throws: DeltaCodec.DecodeError.unsupportedVersion(200)) { try DeltaCodec.decode(bytes) }
    }

    @Test func invalidScalarsAreRejected() {
        var delta = richDelta()
        delta.changedRows[0].cells[0] = Cell(content: 0xD800, styleID: 0)
        #expect(throws: DeltaCodec.DecodeError.self) { try DeltaCodec.decode(DeltaCodec.encode(delta)) }
    }
}

/// A small deterministic generator, so failures reproduce.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
