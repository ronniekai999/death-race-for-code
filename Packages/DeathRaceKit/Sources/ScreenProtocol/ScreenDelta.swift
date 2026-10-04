import VTCore

/// One row as it travels to the app: self-contained, with its own style table and the extra
/// scalars of multi-scalar characters.
public struct RowSnapshot: Sendable, Equatable {
    public var id: UInt64
    public var version: UInt64
    /// Shares storage with the engine's row until either side changes it.
    public var cells: ContiguousArray<Cell>
    public var styles: ContiguousArray<Style>
    public var graphemes: [Int: [UInt32]]
    public var isWrapped: Bool
    public var promptMarks: PromptMarks
    public var exitCode: Int32?

    public init(
        id: UInt64, version: UInt64, cells: ContiguousArray<Cell>, styles: ContiguousArray<Style> = [.default],
        graphemes: [Int: [UInt32]] = [:], isWrapped: Bool = false, promptMarks: PromptMarks = [],
        exitCode: Int32? = nil
    ) {
        self.id = id
        self.version = version
        self.cells = cells
        self.styles = styles
        self.graphemes = graphemes
        self.isWrapped = isWrapped
        self.promptMarks = promptMarks
        self.exitCode = exitCode
    }

    public init(_ row: Row) {
        self.init(
            id: row.id, version: row.version, cells: row.cells, styles: row.styles, graphemes: row.graphemes,
            isWrapped: row.isWrapped, promptMarks: row.promptMarks, exitCode: row.exitCode)
    }

    public func style(of cell: Cell) -> Style {
        let index = Int(cell.styleID)
        return index < styles.count ? styles[index] : .default
    }

    /// The scalars of the character at `column`.
    public func scalars(at column: Int) -> [UInt32] {
        let cell = cells[column]
        guard !cell.isEmpty else { return [] }
        if cell.hasGrapheme, let extra = graphemes[column] { return [cell.scalar] + extra }
        return [cell.scalar]
    }
}

public struct CursorSnapshot: Sendable, Equatable {
    /// In the active area, 0-based. The viewport may be scrolled away from it.
    public var x: Int
    public var y: Int
    public var pendingWrap: Bool
    public var visible: Bool
    public var shape: CursorShape
    /// nil until a program asks (DECSCUSR), so the user's preference applies.
    public var blinks: Bool?

    public init(
        x: Int = 0, y: Int = 0, pendingWrap: Bool = false, visible: Bool = true, shape: CursorShape = .block,
        blinks: Bool? = nil
    ) {
        self.x = x
        self.y = y
        self.pendingWrap = pendingWrap
        self.visible = visible
        self.shape = shape
        self.blinks = blinks
    }
}

/// What changed on a session's screen since the app last took a delta.
///
/// A delta is current state, not a log: a newer one replaces one the app has not taken yet,
/// with only the events carried over (see `merging(unsent:)`). It describes the viewport,
/// the rows the user is looking at, by row id; rows the app already has are not resent.
public struct ScreenDelta: Sendable, Equatable {
    /// Changes when the whole screen was replaced (resize, reflow, screen switch, reset). A
    /// delta from a generation the app does not have is always a snapshot.
    public var generation: UInt64
    /// The engine's clock when the delta was made; rows changed after it come next time.
    public var version: UInt64
    /// The version of the delta this one builds on: only a mirror holding exactly that state
    /// may apply it. Unused in a snapshot.
    public var baseVersion: UInt64
    /// Every row of the viewport is included; the app starts over from this delta.
    public var isSnapshot: Bool
    public var columns: Int
    public var rows: Int
    /// How many lines the viewport is scrolled up into scrollback; 0 follows the output.
    public var viewportOffset: Int
    public var scrollbackCount: Int
    /// The viewport's rows, top to bottom.
    public var rowIDs: [UInt64]
    /// Rows the app does not have in their current version.
    public var changedRows: [RowSnapshot]
    public var cursor: CursorSnapshot
    /// Mirrored so the app encodes keys and mouse reports without asking the session.
    public var modes: TerminalModes
    public var kittyFlags: UInt8
    public var isAlternateScreen: Bool
    public var title: String
    /// Included when it changed since the last delta the app took.
    public var palette: Palette?
    public var events: [TerminalEvent]
    /// A program is reading a password (a line with echo off, as sudo and ssh do): the app
    /// turns on Secure Keyboard Entry until it stops.
    public var readingPassword: Bool

    public init(
        generation: UInt64, version: UInt64, baseVersion: UInt64 = 0, isSnapshot: Bool, columns: Int, rows: Int,
        viewportOffset: Int,
        scrollbackCount: Int, rowIDs: [UInt64], changedRows: [RowSnapshot], cursor: CursorSnapshot,
        modes: TerminalModes, kittyFlags: UInt8, isAlternateScreen: Bool, title: String, palette: Palette?,
        events: [TerminalEvent], readingPassword: Bool = false
    ) {
        self.generation = generation
        self.version = version
        self.baseVersion = baseVersion
        self.isSnapshot = isSnapshot
        self.columns = columns
        self.rows = rows
        self.viewportOffset = viewportOffset
        self.scrollbackCount = scrollbackCount
        self.rowIDs = rowIDs
        self.changedRows = changedRows
        self.cursor = cursor
        self.modes = modes
        self.kittyFlags = kittyFlags
        self.isAlternateScreen = isAlternateScreen
        self.title = title
        self.palette = palette
        self.events = events
        self.readingPassword = readingPassword
    }

    /// This delta in place of `unsent`, which the app never took: the screen state is this
    /// one's, and `unsent`'s events come first, folded with this one's
    /// (`TerminalEvent.coalesced`) so an app that stops taking deltas holds a bounded queue.
    public func merging(unsent: ScreenDelta) -> ScreenDelta {
        var merged = self
        merged.events = TerminalEvent.coalesced(unsent.events + events)
        if merged.palette == nil { merged.palette = unsent.palette }
        return merged
    }
}
