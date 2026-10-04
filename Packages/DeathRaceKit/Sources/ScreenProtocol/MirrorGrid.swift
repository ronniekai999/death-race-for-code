import VTCore

/// The app's copy of a session's screen: the viewport rows and the state needed to draw them
/// and to encode input. The renderer draws from it; it changes only by applying deltas.
public struct MirrorGrid: Sendable {
    public enum ApplyError: Error, Equatable {
        /// The delta builds on a state or rows this mirror does not have (another generation,
        /// or a delta it never applied); ask the session for a snapshot.
        case needsSnapshot
    }

    public private(set) var generation: UInt64?
    public private(set) var version: UInt64 = 0
    public private(set) var columns = 0
    public private(set) var rows = 0
    /// The viewport, top to bottom.
    public private(set) var lines: [RowSnapshot] = []
    public private(set) var cursor = CursorSnapshot()
    public private(set) var modes = TerminalModes()
    public private(set) var kittyFlags: UInt8 = 0
    public private(set) var isAlternateScreen = false
    public private(set) var title = ""
    public private(set) var palette = Palette.legendsNeverDie
    public private(set) var viewportOffset = 0
    public private(set) var scrollbackCount = 0
    /// The line number of `lines[0]`; `lines[y]` is line `viewportTopLine + y`.
    public private(set) var viewportTopLine: UInt64 = 0
    public private(set) var readingPassword = false

    public init() {}

    /// The OSC 8 link at a viewport cell.
    public func link(column: Int, row: Int) -> Hyperlink? {
        lines.indices.contains(row) ? lines[row].link(at: column) : nil
    }

    /// Applies `delta` and returns the viewport rows whose content or position changed. On
    /// error the mirror is unchanged.
    @discardableResult
    public mutating func apply(_ delta: ScreenDelta) throws(ApplyError) -> [Int] {
        guard delta.isSnapshot || (delta.generation == generation && delta.baseVersion == version) else {
            throw .needsSnapshot
        }

        var byID: [UInt64: RowSnapshot] = [:]
        byID.reserveCapacity(lines.count + delta.changedRows.count)
        if !delta.isSnapshot {
            for line in lines { byID[line.id] = line }
        }
        for row in delta.changedRows { byID[row.id] = row }

        var newLines: [RowSnapshot] = []
        newLines.reserveCapacity(delta.rowIDs.count)
        var changed: [Int] = []
        for (y, id) in delta.rowIDs.enumerated() {
            guard let row = byID[id] else { throw .needsSnapshot }
            if delta.isSnapshot || y >= lines.count || lines[y].id != id || lines[y].version != row.version {
                changed.append(y)
            }
            newLines.append(row)
        }

        lines = newLines
        generation = delta.generation
        version = delta.version
        columns = delta.columns
        rows = delta.rows
        cursor = delta.cursor
        modes = delta.modes
        kittyFlags = delta.kittyFlags
        isAlternateScreen = delta.isAlternateScreen
        title = delta.title
        if let newPalette = delta.palette { palette = newPalette }
        viewportOffset = delta.viewportOffset
        scrollbackCount = delta.scrollbackCount
        viewportTopLine = delta.viewportTopLine
        readingPassword = delta.readingPassword
        return changed
    }
}
