import VTCore

/// `ScreenDelta` as bytes, for crossing a process boundary: the session daemon sends these
/// over XPC (Phase 7). Debug builds round-trip every delta through it in process, so the
/// format is exercised long before the daemon exists.
///
/// Little-endian and versioned. Decoding is strict and defensive: every count is checked
/// against the bytes that remain before anything is allocated, and anything unknown is an
/// error, so a malformed message cannot make the app allocate or crash.
public enum DeltaCodec {
    static let magic: [UInt8] = Array("DRSD".utf8)
    public static let formatVersion: UInt8 = 1

    public enum DecodeError: Error, Equatable {
        case truncated
        case badMagic
        case unsupportedVersion(UInt8)
        case invalid(String)
    }

    // MARK: - Encoding

    public static func encode(_ delta: ScreenDelta) -> [UInt8] {
        var w = ByteWriter()
        w.bytes.append(contentsOf: magic)
        w.u8(formatVersion)
        w.u64(delta.generation)
        w.u64(delta.version)
        w.bool(delta.isSnapshot)
        w.u32(UInt32(clamping: delta.columns))
        w.u32(UInt32(clamping: delta.rows))
        w.u32(UInt32(clamping: delta.viewportOffset))
        w.u32(UInt32(clamping: delta.scrollbackCount))

        w.u32(UInt32(delta.rowIDs.count))
        for id in delta.rowIDs { w.u64(id) }
        w.u32(UInt32(delta.changedRows.count))
        for row in delta.changedRows { encode(row, into: &w) }

        let c = delta.cursor
        w.u32(UInt32(clamping: c.x))
        w.u32(UInt32(clamping: c.y))
        w.bool(c.pendingWrap)
        w.bool(c.visible)
        w.u8(c.shape.rawValue)
        w.u8(c.blinks.map { $0 ? 1 : 0 } ?? 2)

        encode(delta.modes, into: &w)
        w.u8(delta.kittyFlags)
        w.bool(delta.isAlternateScreen)
        w.string(delta.title)
        if let palette = delta.palette {
            w.bool(true)
            for color in palette.colors { w.rgb(color) }
            w.rgb(palette.foreground)
            w.rgb(palette.background)
            w.rgb(palette.cursor)
        } else {
            w.bool(false)
        }
        w.u32(UInt32(delta.events.count))
        for event in delta.events { encode(event, into: &w) }
        w.bool(delta.echoOff)
        return w.bytes
    }

    private static func encode(_ row: RowSnapshot, into w: inout ByteWriter) {
        w.u64(row.id)
        w.u64(row.version)
        w.bool(row.isWrapped)
        w.u8(row.promptMarks.rawValue)
        w.optionalI32(row.exitCode)
        w.u32(UInt32(row.cells.count))
        for cell in row.cells {
            w.u32(cell.content)
            w.u16(cell.styleID)
            w.u16(cell.reserved)
        }
        w.u32(UInt32(row.styles.count))
        for style in row.styles {
            w.u32(style.foreground.raw)
            w.u32(style.background.raw)
            w.u32(style.underlineColor.raw)
            w.u16(style.attributes.rawValue)
            w.u8(style.underline.rawValue)
        }
        w.u32(UInt32(row.graphemes.count))
        for column in row.graphemes.keys.sorted() {
            let scalars = row.graphemes[column]!
            w.u32(UInt32(column))
            w.u32(UInt32(scalars.count))
            for scalar in scalars { w.u32(scalar) }
        }
    }

    /// Every Boolean mode, in a fixed order; new modes go at the end. A test checks this
    /// covers all of them. (Computed: key paths are not Sendable, so they cannot be a
    /// static constant.)
    static var booleanModes: [WritableKeyPath<TerminalModes, Bool>] {
        [
            \.insert, \.newline, \.applicationCursorKeys, \.reverseVideo, \.origin, \.autowrap, \.autorepeat,
            \.cursorBlink, \.cursorVisible, \.reverseWraparound, \.applicationKeypad, \.focusEvents,
            \.alternateScroll, \.metaSendsEscape, \.bracketedPaste, \.synchronizedOutput, \.graphemeClustering,
            \.colorSchemeUpdates, \.reverseWraparoundExtended, \.backarrowSendsBackspace,
        ]
    }

    private static func encode(_ modes: TerminalModes, into w: inout ByteWriter) {
        var bits: UInt32 = 0
        for (index, keyPath) in booleanModes.enumerated() where modes[keyPath: keyPath] {
            bits |= 1 << UInt32(index)
        }
        w.u32(bits)
        w.u8(modes.mouseTracking.rawValue)
        w.u8(modes.mouseEncoding.rawValue)
    }

    private static func encode(_ event: TerminalEvent, into w: inout ByteWriter) {
        switch event {
        case .bell:
            w.u8(0)
        case .titleChanged(let text):
            w.u8(1)
            w.string(text)
        case .iconNameChanged(let text):
            w.u8(2)
            w.string(text)
        case .workingDirectoryChanged(let text):
            w.u8(3)
            w.string(text)
        case .notification(let title, let body):
            w.u8(4)
            w.string(title)
            w.string(body)
        case .progress(let report):
            w.u8(5)
            switch report {
            case .cleared: w.u8(0)
            case .normal(let percent):
                w.u8(1)
                w.optionalI32(Int32(clamping: percent))
            case .error(let percent):
                w.u8(2)
                w.optionalI32(percent.map { Int32(clamping: $0) })
            case .indeterminate: w.u8(3)
            case .paused(let percent):
                w.u8(4)
                w.optionalI32(percent.map { Int32(clamping: $0) })
            }
        case .clipboardWrite(let selection, let contents):
            w.u8(6)
            w.string(selection)
            w.u32(UInt32(contents.count))
            w.bytes.append(contentsOf: contents)
        case .promptMark(let mark, let rowID):
            w.u8(7)
            switch mark {
            case .promptStart: w.u8(0)
            case .commandStart: w.u8(1)
            case .outputStart: w.u8(2)
            case .commandEnd(let code):
                w.u8(3)
                w.optionalI32(code)
            }
            w.u64(rowID)
        case .colorsChanged:
            w.u8(8)
        case .screenReplaced:
            w.u8(9)
        }
    }

    // MARK: - Decoding

    public static func decode(_ bytes: [UInt8]) throws(DecodeError) -> ScreenDelta {
        var r = ByteReader(bytes: bytes)
        guard try r.take(4) == magic else { throw .badMagic }
        let version = try r.u8()
        guard version == formatVersion else { throw .unsupportedVersion(version) }

        let generation = try r.u64()
        let deltaVersion = try r.u64()
        let isSnapshot = try r.bool()
        let columns = Int(try r.u32())
        let rows = Int(try r.u32())
        let viewportOffset = Int(try r.u32())
        let scrollbackCount = Int(try r.u32())

        let idCount = try r.count(elementSize: 8)
        var rowIDs: [UInt64] = []
        rowIDs.reserveCapacity(idCount)
        for _ in 0..<idCount { rowIDs.append(try r.u64()) }
        let rowCount = try r.count(elementSize: 31)
        var changedRows: [RowSnapshot] = []
        changedRows.reserveCapacity(rowCount)
        for _ in 0..<rowCount { changedRows.append(try decodeRow(&r)) }

        let cursorX = Int(try r.u32())
        let cursorY = Int(try r.u32())
        let pendingWrap = try r.bool()
        let visible = try r.bool()
        guard let shape = CursorShape(rawValue: try r.u8()) else { throw .invalid("cursor shape") }
        let blinks: Bool? =
            switch try r.u8() {
            case 0: false
            case 1: true
            case 2: nil
            default: throw .invalid("cursor blink")
            }

        let modes = try decodeModes(&r)
        let kittyFlags = try r.u8()
        let isAlternateScreen = try r.bool()
        let title = try r.string()
        var palette: Palette?
        if try r.bool() {
            var colors: [RGB] = []
            colors.reserveCapacity(256)
            for _ in 0..<256 { colors.append(try r.rgb()) }
            palette = Palette(colors: colors, foreground: try r.rgb(), background: try r.rgb(), cursor: try r.rgb())
        }
        let eventCount = try r.count(elementSize: 1)
        var events: [TerminalEvent] = []
        events.reserveCapacity(eventCount)
        for _ in 0..<eventCount { events.append(try decodeEvent(&r)) }
        let echoOff = try r.bool()
        guard r.isAtEnd else { throw .invalid("trailing bytes") }

        return ScreenDelta(
            generation: generation, version: deltaVersion, isSnapshot: isSnapshot, columns: columns, rows: rows,
            viewportOffset: viewportOffset, scrollbackCount: scrollbackCount, rowIDs: rowIDs,
            changedRows: changedRows,
            cursor: CursorSnapshot(
                x: cursorX, y: cursorY, pendingWrap: pendingWrap, visible: visible, shape: shape, blinks: blinks),
            modes: modes, kittyFlags: kittyFlags, isAlternateScreen: isAlternateScreen, title: title,
            palette: palette, events: events, echoOff: echoOff)
    }

    private static func decodeRow(_ r: inout ByteReader) throws(DecodeError) -> RowSnapshot {
        let id = try r.u64()
        let version = try r.u64()
        let isWrapped = try r.bool()
        let marks = PromptMarks(rawValue: try r.u8())
        let exitCode = try r.optionalI32()

        let cellCount = try r.count(elementSize: 8)
        var cells = ContiguousArray<Cell>()
        cells.reserveCapacity(cellCount)
        for _ in 0..<cellCount {
            let content = try r.u32()
            // Bits above the hyperlink flag are unused; the scalar must be a real one, so the
            // renderer can trust what it draws.
            guard content >> 26 == 0, ByteReader.isValidScalar(content & 0x1F_FFFF) else {
                throw .invalid("cell")
            }
            var cell = Cell(content: content, styleID: try r.u16())
            cell.reserved = try r.u16()
            cells.append(cell)
        }
        let styleCount = try r.count(elementSize: 15)
        guard styleCount >= 1 else { throw .invalid("a row needs the default style") }
        var styles = ContiguousArray<Style>()
        styles.reserveCapacity(styleCount)
        for _ in 0..<styleCount {
            let foreground = try r.color()
            let background = try r.color()
            let underlineColor = try r.color()
            let attributes = TextAttributes(rawValue: try r.u16())
            guard let underline = UnderlineStyle(rawValue: try r.u8()) else { throw .invalid("underline style") }
            styles.append(
                Style(
                    foreground: foreground, background: background, underlineColor: underlineColor,
                    attributes: attributes, underline: underline))
        }
        for cell in cells where Int(cell.styleID) >= styles.count { throw .invalid("style index out of range") }
        let graphemeCount = try r.count(elementSize: 8)
        var graphemes: [Int: [UInt32]] = [:]
        for _ in 0..<graphemeCount {
            let column = Int(try r.u32())
            guard column < cells.count else { throw .invalid("grapheme column out of range") }
            let scalarCount = try r.count(elementSize: 4)
            var scalars: [UInt32] = []
            scalars.reserveCapacity(scalarCount)
            for _ in 0..<scalarCount {
                let scalar = try r.u32()
                guard scalar != 0, ByteReader.isValidScalar(scalar) else { throw .invalid("grapheme scalar") }
                scalars.append(scalar)
            }
            graphemes[column] = scalars
        }
        return RowSnapshot(
            id: id, version: version, cells: cells, styles: styles, graphemes: graphemes, isWrapped: isWrapped,
            promptMarks: marks, exitCode: exitCode)
    }

    private static func decodeModes(_ r: inout ByteReader) throws(DecodeError) -> TerminalModes {
        let bits = try r.u32()
        var modes = TerminalModes()
        for (index, keyPath) in booleanModes.enumerated() {
            modes[keyPath: keyPath] = bits & (1 << UInt32(index)) != 0
        }
        guard let tracking = MouseTracking(rawValue: try r.u8()) else { throw .invalid("mouse tracking") }
        guard let encoding = MouseEncoding(rawValue: try r.u8()) else { throw .invalid("mouse encoding") }
        modes.mouseTracking = tracking
        modes.mouseEncoding = encoding
        return modes
    }

    private static func decodeEvent(_ r: inout ByteReader) throws(DecodeError) -> TerminalEvent {
        switch try r.u8() {
        case 0: return .bell
        case 1: return .titleChanged(try r.string())
        case 2: return .iconNameChanged(try r.string())
        case 3: return .workingDirectoryChanged(try r.string())
        case 4: return .notification(title: try r.string(), body: try r.string())
        case 5:
            switch try r.u8() {
            case 0: return .progress(.cleared)
            case 1: return .progress(.normal(percent: Int(try r.optionalI32() ?? 0)))
            case 2: return .progress(.error(percent: try r.optionalI32().map(Int.init)))
            case 3: return .progress(.indeterminate)
            case 4: return .progress(.paused(percent: try r.optionalI32().map(Int.init)))
            default: throw .invalid("progress state")
            }
        case 6:
            let selection = try r.string()
            let count = try r.count(elementSize: 1)
            return .clipboardWrite(selection: selection, contents: try r.take(count))
        case 7:
            let mark: PromptMark
            switch try r.u8() {
            case 0: mark = .promptStart
            case 1: mark = .commandStart
            case 2: mark = .outputStart
            case 3: mark = .commandEnd(exitCode: try r.optionalI32())
            default: throw .invalid("prompt mark")
            }
            return .promptMark(mark, rowID: try r.u64())
        case 8: return .colorsChanged
        case 9: return .screenReplaced
        default: throw .invalid("event")
        }
    }
}

// MARK: - Bytes

struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func bool(_ v: Bool) { bytes.append(v ? 1 : 0) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }

    mutating func optionalI32(_ v: Int32?) {
        bool(v != nil)
        if let v { u32(UInt32(bitPattern: v)) }
    }

    mutating func string(_ s: String) {
        u32(UInt32(s.utf8.count))
        bytes.append(contentsOf: s.utf8)
    }

    mutating func rgb(_ c: RGB) {
        bytes.append(contentsOf: [c.red, c.green, c.blue])
    }
}

struct ByteReader {
    let bytes: [UInt8]
    private(set) var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { index == bytes.count }
    var remaining: Int { bytes.count - index }

    mutating func take(_ n: Int) throws(DeltaCodec.DecodeError) -> [UInt8] {
        guard n >= 0, n <= remaining else { throw .truncated }
        defer { index += n }
        return Array(bytes[index..<(index + n)])
    }

    mutating func u8() throws(DeltaCodec.DecodeError) -> UInt8 {
        guard remaining >= 1 else { throw .truncated }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func bool() throws(DeltaCodec.DecodeError) -> Bool {
        switch try u8() {
        case 0: return false
        case 1: return true
        default: throw .invalid("boolean")
        }
    }

    private mutating func integer<T: FixedWidthInteger>(_: T.Type) throws(DeltaCodec.DecodeError) -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw .truncated }
        var value: T = 0
        for offset in 0..<size { value |= T(bytes[index + offset]) << (8 * offset) }
        index += size
        return value
    }

    mutating func u16() throws(DeltaCodec.DecodeError) -> UInt16 { try integer(UInt16.self) }
    mutating func u32() throws(DeltaCodec.DecodeError) -> UInt32 { try integer(UInt32.self) }
    mutating func u64() throws(DeltaCodec.DecodeError) -> UInt64 { try integer(UInt64.self) }

    /// A count of elements that each take at least `elementSize` bytes, checked against what
    /// remains so a forged count cannot make the decoder allocate.
    mutating func count(elementSize: Int) throws(DeltaCodec.DecodeError) -> Int {
        let n = Int(try u32())
        guard n <= remaining / max(elementSize, 1) else { throw .truncated }
        return n
    }

    mutating func optionalI32() throws(DeltaCodec.DecodeError) -> Int32? {
        try bool() ? Int32(bitPattern: try u32()) : nil
    }

    mutating func string() throws(DeltaCodec.DecodeError) -> String {
        let n = try count(elementSize: 1)
        return String(decoding: try take(n), as: UTF8.self)
    }

    mutating func rgb() throws(DeltaCodec.DecodeError) -> RGB {
        RGB(try u8(), try u8(), try u8())
    }

    mutating func color() throws(DeltaCodec.DecodeError) -> TerminalColor {
        let raw = try u32()
        switch raw >> 24 {
        case 0 where raw == 0, 2: break  // default, RGB
        case 1 where raw & 0x00FF_FF00 == 0: break  // indexed
        default: throw .invalid("color")
        }
        return TerminalColor(raw: raw)
    }

    /// A Unicode scalar value, or 0 for none.
    static func isValidScalar(_ value: UInt32) -> Bool {
        value <= 0x10_FFFF && !(0xD800...0xDFFF).contains(value)
    }
}
