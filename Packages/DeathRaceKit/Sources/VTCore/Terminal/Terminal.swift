/// A terminal: the parser feeding a pair of screens.
///
/// One thread owns a terminal (a session's IO thread), so it is a plain class that is
/// deliberately not `Sendable`. Bytes go in through `feed`; what the program asked of the
/// outside world comes back as `replies` (bytes for the PTY) and `events` (for the app).
public final class Terminal {
    public struct Configuration: Sendable {
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
    public internal(set) var palette: Palette
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
    /// DEC private modes saved by XTSAVE, for XTRESTORE.
    var savedPrivateModes: [UInt16: Bool] = [:]
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

    /// Lines ever added to this screen's scrollback; see `ScreenBuffer.scrollbackLinesAdded`.
    public var scrollbackLinesAdded: UInt64 { screen.scrollbackLinesAdded }

    /// A scrollback row, 0 being the oldest kept.
    public func scrollbackRow(_ index: Int) -> Row { screen.scrollback[index] }

    /// The highest row version handed out; rows changed since `version` have a larger one.
    public var currentVersion: UInt64 { clock.current }

    public var scrollRegion: ClosedRange<Int> { screen.scrollTop...screen.scrollBottom }

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
