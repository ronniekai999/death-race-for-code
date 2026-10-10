import VTCore

/// Builds the deltas one client needs, on the session thread that owns the terminal.
///
/// It remembers what the client has (the last delta it took): rows whose version moved
/// since then, or that were not in its viewport, are sent; the rest travel by id. It also
/// owns the client's viewport, so scrolling back through history keeps the same lines in
/// view while output arrives below.
public struct DeltaBuilder {
    private struct Delivered {
        var generation: UInt64
        var version: UInt64
        var rowIDs: Set<UInt64>
        var palette: Palette?
        var graphicsRevision: UInt64
    }

    private var delivered: Delivered?
    /// Lines the viewport is scrolled up from the bottom; 0 follows the output.
    public private(set) var viewportOffset = 0
    private var linesAddedSeen: UInt64 = 0
    private var generationSeen: UInt64?

    public init() {}

    /// The delta that brings the client up to date from the last delta it took. `events` are
    /// the terminal's events since the last delta was built (`Terminal.takeEvents()`).
    public mutating func makeDelta(from terminal: Terminal, events: [TerminalEvent]) -> ScreenDelta {
        followScrollback(terminal)

        let rowIDs = viewportRows(of: terminal)
        let snapshot = delivered == nil || delivered?.generation != terminal.generation
        var changed: [RowSnapshot] = []
        for row in rowIDs.rows {
            if snapshot || row.version > delivered!.version || !delivered!.rowIDs.contains(row.id) {
                changed.append(RowSnapshot(row))
            }
        }
        let cursor = terminal.cursor
        return ScreenDelta(
            generation: terminal.generation,
            version: terminal.currentVersion,
            baseVersion: snapshot ? 0 : delivered!.version,
            isSnapshot: snapshot,
            columns: terminal.columns,
            rows: terminal.rows,
            viewportOffset: viewportOffset,
            scrollbackCount: terminal.scrollbackCount,
            viewportTopLine: terminal.linesScrolledOff &- UInt64(viewportOffset),
            rowIDs: rowIDs.ids,
            changedRows: changed,
            cursor: CursorSnapshot(
                x: cursor.x, y: cursor.y, pendingWrap: cursor.pendingWrap, visible: cursor.visible,
                shape: cursor.shape, blinks: terminal.cursorBlinks),
            modes: terminal.modes,
            kittyFlags: terminal.kittyKeyboardFlags,
            isAlternateScreen: terminal.isAlternateScreen,
            title: terminal.title,
            palette: snapshot || delivered?.palette != terminal.palette ? terminal.palette : nil,
            events: events, graphicsRevision: terminal.inlineGraphics.revision,
            images: snapshot || delivered?.graphicsRevision != terminal.inlineGraphics.revision
                ? terminal.inlineGraphics.images.values.sorted { $0.id < $1.id } : nil,
            placements: terminal.inlineGraphics.placements.values.sorted { $0.key < $1.key })
    }

    /// The client took `delta`; the next one is relative to it.
    public mutating func didDeliver(_ delta: ScreenDelta) {
        delivered = Delivered(
            generation: delta.generation, version: delta.version, rowIDs: Set(delta.rowIDs),
            palette: delta.palette ?? delivered?.palette, graphicsRevision: delta.graphicsRevision)
    }

    /// Forgets what the client has: the next delta is a snapshot.
    public mutating func reset() {
        delivered = nil
    }

    /// Scrolls the viewport `lines` up into history (negative: down toward the output).
    public mutating func scroll(by lines: Int, in terminal: Terminal) {
        followScrollback(terminal)
        viewportOffset = min(max(viewportOffset + lines, 0), terminal.scrollbackCount)
    }

    public mutating func scrollToBottom() {
        viewportOffset = 0
    }

    // MARK: - Viewport

    /// Keeps a scrolled-back viewport on the same lines as new ones arrive, and drops it back
    /// to the bottom when the screen is replaced.
    private mutating func followScrollback(_ terminal: Terminal) {
        let added = terminal.linesScrolledOff
        if generationSeen != terminal.generation || terminal.isAlternateScreen {
            viewportOffset = 0
        } else if viewportOffset > 0 {
            viewportOffset += Int(added &- linesAddedSeen)
        }
        generationSeen = terminal.generation
        linesAddedSeen = added
        viewportOffset = min(viewportOffset, terminal.scrollbackCount)
    }

    private func viewportRows(of terminal: Terminal) -> (rows: [Row], ids: [UInt64]) {
        let count = terminal.rows
        let scrollback = terminal.scrollbackCount
        var rows: [Row] = []
        rows.reserveCapacity(count)
        for index in 0..<count {
            let line = index - viewportOffset
            rows.append(line < 0 ? terminal.scrollbackRow(scrollback + line) : terminal.row(line))
        }
        return (rows, rows.map(\.id))
    }
}
