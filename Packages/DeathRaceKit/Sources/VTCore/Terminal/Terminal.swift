/// A terminal: the parser feeding a pair of screens.
///
/// One thread owns a terminal (a session's IO thread), so it is a plain class that is
/// deliberately not `Sendable`. Bytes go in through `feed`; what the program asked of the
/// outside world comes back as `replies` (bytes for the PTY) and `events` (for the app).
public final class Terminal {
    public struct Configuration: Sendable, Equatable {
        public var columns: Int
        public var rows: Int
        /// Scrollback budget, in bytes of cell storage. 50 MB, as in Ghostty.
        public var scrollbackLimitBytes: Int
        public var palette: Palette
        /// Answer DECRQCRA (screen checksums). esctest needs it; a real terminal must not,
        /// because a program that can checksum the screen can read it.
        public var answersChecksumRequests: Bool
        /// Reported by XTVERSION.
        public var version: String
        /// Cell size in pixels, for XTWINOPS 14 and 16; set by the renderer.
        public var cellPixelWidth: Int
        public var cellPixelHeight: Int

        public init(
            columns: Int = 80,
            rows: Int = 24,
            scrollbackLimitBytes: Int = 50 * 1024 * 1024,
            palette: Palette = .legendsNeverDie,
            answersChecksumRequests: Bool = false,
            version: String = "0.1.0",
            cellPixelWidth: Int = 0,
            cellPixelHeight: Int = 0
        ) {
            self.columns = columns
            self.rows = rows
            self.scrollbackLimitBytes = scrollbackLimitBytes
            self.palette = palette
            self.answersChecksumRequests = answersChecksumRequests
            self.version = version
            self.cellPixelWidth = cellPixelWidth
            self.cellPixelHeight = cellPixelHeight
        }
    }

    public internal(set) var configuration: Configuration
    let clock = Clock()
    let primary: ScreenBuffer
    let alternate: ScreenBuffer
    public internal(set) var isAlternateScreen = false

    public internal(set) var modes = TerminalModes()
    /// Whose protection the cells' protected bit is: DECSCA's, which only the selective erases
    /// spare, or ISO 6429's from SPA, which only the plain erases spare. One bit on the cell and
    /// one mode beside it is xterm's model, and esctest pins both halves of it.
    var protection = Protection.none

    enum Protection {
        case none
        /// DECSCA: DECSEL and DECSED leave these cells alone; ED, EL and ECH do not.
        case dec
        /// SPA and EPA: ED, EL and ECH leave these cells alone; DECSEL and DECSED do not.
        case iso
    }

    /// The erases, by what they do with a protected cell.
    enum Erase {
        /// ED, EL, ECH and DECERA.
        case plain
        /// DECSEL and DECSED.
        case selective
        /// DECSERA.
        case selectiveRectangle
    }

    /// Whether an erase leaves the cells somebody protected alone. One bit marks the cell and
    /// `protection` says who marked it; what each erase then does is a table xterm's own author
    /// settled and esctest pins every row of:
    ///
    /// - ED, EL and ECH spare what ISO 6429's SPA protected, and not what DECSCA did.
    /// - DECSEL and DECSED spare either, which xterm does "for backward compatibility" — the
    ///   reason esctest gives for filing it as xterm's own difference from the specification.
    /// - DECSERA spares only DECSCA's, which is DEC's rule for it, and is how xterm behaves
    ///   even while its DECSEL does not.
    func sparesProtected(_ erase: Erase) -> Bool {
        switch erase {
        case .plain: protection == .iso
        case .selective: protection != .none
        case .selectiveRectangle: protection == .dec
        }
    }
    /// The colors in use: the base palette (`configuration.palette`, the app's theme) with
    /// what programs changed on top.
    public internal(set) var palette: Palette
    /// The palette entries (0–255) and dynamic colors (`foregroundSlot`…`cursorSlot`) a
    /// program set (OSC 4, 10, 11, 12). A new base palette leaves them alone; their resets
    /// (OSC 104, 110, 111, 112) and RIS forget them.
    var paletteOverrides: Set<Int> = []
    /// The special colors (OSC 5, or OSC 4 past the end of the palette): in xterm's order,
    /// bold, underline, blink, reverse and italic. They are kept and reported and nothing draws
    /// with them, which is also what xterm does unless its user turns on `colorBDMode` and its
    /// siblings; a slot nobody has set reads as the foreground, which is their default.
    var specialColors = [RGB?](repeating: nil, count: Terminal.specialColorCount)
    static let specialColorCount = 5
    static let foregroundSlot = 256
    static let backgroundSlot = 257
    static let cursorSlot = 258
    public internal(set) var title = ""
    public internal(set) var iconName = ""
    var titleStack: [(title: String, iconName: String)] = []
    public internal(set) var cursorShape = CursorShape.block
    /// From DECSCUSR; nil until a program asks, so the user's preference applies.
    public internal(set) var cursorBlinks: Bool?
    public internal(set) var workingDirectory: String?

    /// Kitty keyboard protocol flags, one stack per screen; the last element is current.
    var kittyFlagsPrimary: [UInt8] = [0]
    var kittyFlagsAlternate: [UInt8] = [0]

    /// Bytes to write back to the program (device attributes, cursor reports…).
    public internal(set) var replies: [UInt8] = []
    public internal(set) var events: [TerminalEvent] = []
    /// Bumped when everything must be redrawn: a screen switch, a resize, a reset.
    public internal(set) var generation: UInt64 = 0

    /// The last printed character, for REP.
    var lastGraphic: UInt32?
    /// The command line from `OSC 633;E`, waiting for the `OSC 133;D` that ends that command.
    /// Cleared when it is used, so one command's text can never label the next one.
    var pendingCommandText: String?
    /// The OSC 8 link characters print into, until the program closes it.
    public internal(set) var currentLink: Hyperlink?
    /// Links opened without an id, numbered so each is its own.
    var anonymousLinks: UInt64 = 0
    /// DEC private modes saved by XTSAVE, for XTRESTORE.
    var savedPrivateModes: [UInt16: Bool] = [:]
    /// Mode 40 (xterm): the program may switch between 80 and 132 columns. The width never
    /// changes here, but DECCOLM then has its other effects.
    var allowsColumnSwitch = false
    /// DECNCSM (95): DECCOLM leaves the screen as it is.
    var keepsScreenOnColumnSwitch = false
    /// Inert modes that are set (see `Terminal.inertANSIModes`); DEC modes are offset by
    /// 0x10000.
    var inertModes: Set<UInt32> = []
    private var parser = VTParser()

    public init(_ configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.palette = configuration.palette
        primary = ScreenBuffer(
            columns: configuration.columns, rows: configuration.rows, keepsScrollback: true,
            scrollbackLimitBytes: configuration.scrollbackLimitBytes, clock: clock)
        alternate = ScreenBuffer(
            columns: configuration.columns, rows: configuration.rows, keepsScrollback: false,
            scrollbackLimitBytes: 0, clock: clock)
    }

    /// The screen programs are drawing on.
    @inline(__always)
    var screen: ScreenBuffer { isAlternateScreen ? alternate : primary }

    public var columns: Int { screen.columns }
    public var rows: Int { screen.rows }

    // MARK: - Input

    public func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
        // Take the parser out while it runs so its string buffer stays uniquely owned (no
        // copy-on-write) and no access to `self.parser` overlaps the handler's.
        var running = VTParser()
        swap(&running, &parser)
        defer { swap(&running, &parser) }
        var dispatcher = Dispatcher(terminal: self)
        running.feed(bytes, into: &dispatcher)
    }

    public func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { feed($0) }
    }

    public func feed(_ text: String) {
        feed(Array(text.utf8))
    }

    /// Hands over the replies queued since the last call.
    public func takeReplies() -> [UInt8] {
        defer { replies.removeAll(keepingCapacity: true) }
        return replies
    }

    /// Hands over the events queued since the last call.
    public func takeEvents() -> [TerminalEvent] {
        defer { events.removeAll(keepingCapacity: true) }
        return events
    }

    // MARK: - Theme

    /// Installs a new base palette (the app's theme changed). Colors a program set keep its
    /// values; the rest take the new ones, and OSC 104/110–112 now reset to them.
    public func setBasePalette(_ base: Palette) {
        configuration.palette = base
        for index in 0..<256 where !paletteOverrides.contains(index) {
            palette.colors[index] = base.colors[index]
        }
        if !paletteOverrides.contains(Self.foregroundSlot) { palette.foreground = base.foreground }
        if !paletteOverrides.contains(Self.backgroundSlot) { palette.background = base.background }
        if !paletteOverrides.contains(Self.cursorSlot) { palette.cursor = base.cursor }
        emit(.colorsChanged)
    }

    // MARK: - Clearing

    public enum ClearKind: Sendable, Equatable {
        /// Terminal's Clear to Start (⌘K): the cursor's line, the prompt, moves to the top;
        /// the lines above it and the history go.
        case toStart
        /// Clear Scrollback (⌥⌘K): only the history goes.
        case scrollback
    }

    /// Clears for the user (⌘K, ⌥⌘K). The alternate screen is left alone: clearing under a
    /// full-screen program would leave its idea of the screen wrong until it redraws.
    /// False when there was nothing to do.
    @discardableResult
    public func clear(_ kind: ClearKind) -> Bool {
        guard !isAlternateScreen else { return false }
        let s = primary
        var changed = !s.scrollback.isEmpty
        s.clearScrollback()
        if kind == .toStart {
            // The whole logical line stays: a long command wraps onto the cursor's row from
            // the rows above it.
            var top = s.cursor.y
            while top > 0 && s.active[top - 1].isWrapped { top -= 1 }
            if top > 0 {
                s.discardTopRows(top, fill: .default)
                changed = true
            }
        }
        guard changed else { return false }
        lastGraphic = nil
        bumpGeneration()
        return true
    }

    // MARK: - Resize

    /// Resizes both screens. The primary reflows: soft-wrapped lines are wrapped again at the
    /// new width, scrollback included. The alternate screen is cropped or padded, because the
    /// programs that use it redraw when the size changes.
    public func resize(columns: Int, rows: Int) {
        let columns = max(columns, 1)
        let rows = max(rows, 1)
        guard columns != primary.columns || rows != primary.rows else { return }
        primary.reflow(columns: columns, rows: rows)
        alternate.resizeWithoutReflow(columns: columns, rows: rows, fill: .default)
        configuration.columns = columns
        configuration.rows = rows
        lastGraphic = nil
        bumpGeneration()
    }

    // MARK: - Inspection

    public struct CursorState: Equatable, Sendable {
        public var x: Int
        public var y: Int
        public var pendingWrap: Bool
        public var visible: Bool
        public var shape: CursorShape
    }

    public var cursor: CursorState {
        let c = screen.cursor
        return CursorState(x: c.x, y: c.y, pendingWrap: c.pendingWrap, visible: modes.cursorVisible, shape: cursorShape)
    }

    /// The pen SGR sets: the style new characters get.
    public var currentStyle: Style { screen.cursor.pen }

    /// A row of the active area, 0 at the top.
    public func row(_ y: Int) -> Row { screen.active[y] }

    public var scrollbackCount: Int { screen.scrollback.count }

    /// Lines that have ever left the top of the screen programs draw on, kept or not. The
    /// active row `y` is line `linesScrolledOff + y` and scrollback row `i` is line
    /// `linesScrolledOff - scrollbackCount + i`: numbers that stay with their lines while
    /// output scrolls and history is trimmed, until the generation changes.
    public var linesScrolledOff: UInt64 { screen.linesScrolledOff }

    /// A scrollback row, 0 being the oldest kept.
    public func scrollbackRow(_ index: Int) -> Row { screen.scrollback[index] }

    /// The highest row version handed out; rows changed since `version` have a larger one.
    public var currentVersion: UInt64 { clock.current }

    public var scrollRegion: ClosedRange<Int> { screen.scrollTop...screen.scrollBottom }

    /// The left and right margins (DECSLRM), inclusive. They bound nothing unless
    /// `modes.leftRightMargins` is on, and turning that off puts them back to the full width.
    public var columnMargins: ClosedRange<Int> { screen.scrollLeft...screen.scrollRight }

    public var kittyKeyboardFlags: UInt8 {
        (isAlternateScreen ? kittyFlagsAlternate : kittyFlagsPrimary).last ?? 0
    }

    // MARK: - Helpers for the dispatch extensions

    func reply(_ text: String) {
        replies.append(contentsOf: text.utf8)
    }

    func emit(_ event: TerminalEvent) {
        events.append(event)
        // Programs can emit events far faster than anyone takes them; folding the queue now
        // and then keeps it small (it never holds more than this plus what folding keeps).
        if events.count >= Self.eventFoldThreshold { events = TerminalEvent.coalesced(events) }
    }

    static let eventFoldThreshold = 256

    func bumpGeneration() {
        generation &+= 1
        emit(.screenReplaced)
    }
}

/// Bridges the parser's generic handler to the terminal. The reference is strong on
/// purpose: calls through an `unowned(unsafe)` one retain and release the terminal every
/// time, which measured slower than one retain per `feed`.
struct Dispatcher: VTHandler {
    let terminal: Terminal

    @inline(__always)
    mutating func printASCII(_ bytes: UnsafeBufferPointer<UInt8>) { terminal.printASCII(bytes) }
    @inline(__always)
    mutating func print(_ scalar: UInt32) { terminal.printScalar(scalar) }
    mutating func execute(_ control: UInt8) { terminal.execute(control) }
    mutating func escapeDispatch(_ sequence: EscapeSequence) { terminal.escapeDispatch(sequence) }
    mutating func controlSequenceDispatch(_ sequence: ControlSequence) { terminal.controlSequence(sequence) }
    mutating func operatingSystemCommand(_ payload: UnsafeBufferPointer<UInt8>, terminatedByBEL: Bool) {
        terminal.operatingSystemCommand(payload, terminatedByBEL: terminatedByBEL)
    }
    mutating func deviceControlString(_ header: DeviceControlHeader, data: UnsafeBufferPointer<UInt8>) {
        terminal.deviceControlString(header, data: data)
    }
    mutating func applicationProgramCommand(_ payload: UnsafeBufferPointer<UInt8>) {
        // Kitty graphics arrives here (Phase 9).
    }
}
