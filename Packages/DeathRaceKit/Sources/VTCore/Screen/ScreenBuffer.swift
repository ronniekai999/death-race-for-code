/// Hands out row ids and versions. Shared by both screens of a terminal, so ids are unique
/// across them and one version counter orders every change.
final class Clock {
    private var nextID: UInt64 = 1
    private var now: UInt64 = 0

    func rowID() -> UInt64 {
        defer { nextID += 1 }
        return nextID
    }

    @inline(__always)
    func tick() -> UInt64 {
        now += 1
        return now
    }

    var current: UInt64 { now }
}

/// Character set designations (SCS): what GL maps printable ASCII to.
enum Charset: UInt8, Sendable {
    case ascii
    case decSpecialGraphics
    case british
}

struct CharsetState: Equatable, Sendable {
    var designations: (Charset, Charset, Charset, Charset) = (.ascii, .ascii, .ascii, .ascii)
    /// Which of G0...G3 is invoked into GL (SI = 0, SO = 1, LS2 = 2, LS3 = 3).
    var gl = 0
    /// A single shift (SS2/SS3) applies to the next character only.
    var singleShift: Int?

    subscript(index: Int) -> Charset {
        get {
            switch index {
            case 1: designations.1
            case 2: designations.2
            case 3: designations.3
            default: designations.0
            }
        }
        set {
            switch index {
            case 1: designations.1 = newValue
            case 2: designations.2 = newValue
            case 3: designations.3 = newValue
            default: designations.0 = newValue
            }
        }
    }

    /// True when printable ASCII prints as itself: the fast path is safe.
    var isPlainASCII: Bool { singleShift == nil && self[gl] == .ascii }

    static func == (lhs: CharsetState, rhs: CharsetState) -> Bool {
        lhs.designations == rhs.designations && lhs.gl == rhs.gl && lhs.singleShift == rhs.singleShift
    }
}

struct Cursor: Sendable {
    var x = 0
    var y = 0
    /// DECAWM's "last column flag": a character was printed in the last column and the next
    /// one wraps first.
    var pendingWrap = false
    var pen = Style.default
    var protected = false
    var charsets = CharsetState()
}

/// What DECSC saves and DECRC restores.
struct SavedCursor: Sendable {
    var x: Int
    var y: Int
    var pendingWrap: Bool
    var pen: Style
    var protected: Bool
    var originMode: Bool
    var charsets: CharsetState
}

/// One screen: the primary (with scrollback) or the alternate (without).
///
/// Coordinates are 0-based and refer to the active area: row 0 is the top visible line.
/// Scrollback rows sit above it, oldest first.
final class ScreenBuffer {
    let keepsScrollback: Bool
    private(set) var columns: Int
    private(set) var rows: Int
    var active: [Row]
    private(set) var scrollback = RingBuffer<Row>()
    private(set) var scrollbackBytes = 0
    var scrollbackLimitBytes: Int
    /// Lines ever added to scrollback, so a viewport scrolled into history can stay on the
    /// same lines while output arrives. Reflow re-adds every line; it also bumps the
    /// terminal's generation, which tells readers to start over.
    private(set) var scrollbackLinesAdded: UInt64 = 0

    var cursor = Cursor()
    var savedCursor: SavedCursor?
    /// The scroll region (DECSTBM), inclusive.
    var scrollTop = 0
    var scrollBottom: Int
    var tabStops: [Bool]

    private var spareRows: [Row] = []
    let clock: Clock

    init(columns: Int, rows: Int, keepsScrollback: Bool, scrollbackLimitBytes: Int, clock: Clock) {
        self.columns = max(columns, 1)
        self.rows = max(rows, 1)
        self.keepsScrollback = keepsScrollback
        self.scrollbackLimitBytes = scrollbackLimitBytes
        self.clock = clock
        self.scrollBottom = self.rows - 1
        self.tabStops = ScreenBuffer.defaultTabStops(columns: self.columns)
        self.active = []
        for _ in 0..<self.rows { active.append(makeRow(fill: .default)) }
    }

    static func defaultTabStops(columns: Int) -> [Bool] {
        (0..<columns).map { $0 > 0 && $0 % 8 == 0 }
    }

    // MARK: - Rows

    /// A blank row, `columns` wide (the screen's width unless given), reusing a retired one
    /// when there is one.
    func makeRow(fill: Style, columns width: Int? = nil) -> Row {
        let width = width ?? columns
        let row: Row
        if let spare = spareRows.popLast() {
            spare.reset(id: clock.rowID(), columns: width, fill: fill)
            row = spare
        } else {
            row = Row(id: clock.rowID(), columns: width, fill: fill)
        }
        row.version = clock.tick()
        return row
    }

    @inline(__always)
    func touch(_ row: Row) {
        row.version = clock.tick()
    }

    @inline(__always)
    func touch(_ y: Int) {
        active[y].version = clock.tick()
    }

    func recycle(_ row: consuming Row) {
        if spareRows.count < 64 { spareRows.append(row) }
    }

    var isFullScreenRegion: Bool { scrollTop == 0 && scrollBottom == rows - 1 }

    // MARK: - Scrolling

    /// Scrolls the region up: lines leave at the top, blank lines enter at the bottom.
    /// Lines leaving a region that starts at the top of the primary screen go to scrollback,
    /// as in xterm, even when the region ends above the bottom.
    func scrollUp(_ count: Int, fill: Style) {
        let height = scrollBottom - scrollTop + 1
        let n = min(max(count, 0), height)
        guard n > 0 else { return }
        for _ in 0..<n {
            let leaving = active.remove(at: scrollTop)
            if keepsScrollback && scrollTop == 0 {
                pushToScrollback(leaving)
            } else {
                recycle(leaving)
            }
            active.insert(makeRow(fill: fill), at: scrollBottom)
        }
    }

    /// Scrolls the region down: lines leave at the bottom, blank lines enter at the top.
    func scrollDown(_ count: Int, fill: Style) {
        let height = scrollBottom - scrollTop + 1
        let n = min(max(count, 0), height)
        guard n > 0 else { return }
        for _ in 0..<n {
            recycle(active.remove(at: scrollBottom))
            active.insert(makeRow(fill: fill), at: scrollTop)
        }
    }

    /// IL: inserts blank lines at `y`, pushing the rest of the region down.
    func insertLines(_ count: Int, at y: Int, fill: Style) {
        guard y >= scrollTop && y <= scrollBottom else { return }
        let n = min(max(count, 0), scrollBottom - y + 1)
        guard n > 0 else { return }
        for _ in 0..<n {
            recycle(active.remove(at: scrollBottom))
            active.insert(makeRow(fill: fill), at: y)
        }
    }

    /// DL: deletes lines at `y`, pulling the rest of the region up.
    func deleteLines(_ count: Int, at y: Int, fill: Style) {
        guard y >= scrollTop && y <= scrollBottom else { return }
        let n = min(max(count, 0), scrollBottom - y + 1)
        guard n > 0 else { return }
        for _ in 0..<n {
            recycle(active.remove(at: y))
            active.insert(makeRow(fill: fill), at: scrollBottom)
        }
    }

    func pushToScrollback(_ row: consuming Row) {
        guard keepsScrollback, scrollbackLimitBytes > 0 else {
            recycle(row)
            return
        }
        scrollbackBytes += row.estimatedBytes
        scrollbackLinesAdded &+= 1
        scrollback.append(row)
        while scrollbackBytes > scrollbackLimitBytes, !scrollback.isEmpty {
            let oldest = scrollback.removeFirst()
            scrollbackBytes -= oldest.estimatedBytes
            recycle(oldest)
        }
    }

    func clearScrollback() {
        while !scrollback.isEmpty { recycle(scrollback.removeFirst()) }
        scrollbackBytes = 0
    }

    /// Replaces scrollback wholesale; used by reflow.
    func replaceScrollback<C: Collection<Row>>(with rows: C) {
        scrollback.removeAll()
        scrollbackBytes = 0
        for row in rows { pushToScrollback(row) }
    }

    // MARK: - Cells

    /// Blanks columns `[from, to)` of row `y` in `fill`. With `selective`, protected cells
    /// survive (DECSED / DECSEL).
    func erase(row y: Int, from start: Int, to end: Int, fill: Style, selective: Bool = false) {
        let row = active[y]
        let lower = max(0, start)
        let upper = min(columns, end)
        guard lower < upper else { return }
        splitWideCharacter(in: row, at: lower)
        splitWideCharacter(in: row, at: upper)
        let blank = Cell.blank(styleID: row.styleID(for: fill))
        if !row.graphemes.isEmpty {
            for x in lower..<upper where row.cells[x].hasGrapheme && !(selective && row.cells[x].isProtected) {
                row.graphemes[x] = nil
            }
        }
        row.cells.withUnsafeMutableBufferPointer { cells in
            if selective {
                for x in lower..<upper where !cells[x].isProtected { cells[x] = blank }
            } else {
                UnsafeMutableBufferPointer(rebasing: cells[lower..<upper]).update(repeating: blank)
            }
        }
        if upper == columns { row.isWrapped = false }
        touch(row)
    }

    /// ICH: inserts blanks at `x`, shifting the rest of the line right; cells pushed past the
    /// right edge are lost.
    func insertBlanks(_ count: Int, row y: Int, at x: Int, fill: Style) {
        let row = active[y]
        guard x < columns else { return }
        let n = min(max(count, 0), columns - x)
        guard n > 0 else { return }
        splitWideCharacter(in: row, at: x)
        splitWideCharacter(in: row, at: columns - n)
        let blank = Cell.blank(styleID: row.styleID(for: fill))
        row.cells.removeLast(n)
        row.cells.insert(contentsOf: repeatElement(blank, count: n), at: x)
        shiftGraphemes(in: row, from: x, by: n)
        touch(row)
    }

    /// DCH: deletes cells at `x`, shifting the rest of the line left and filling the right
    /// edge with blanks.
    func deleteCells(_ count: Int, row y: Int, at x: Int, fill: Style) {
        let row = active[y]
        guard x < columns else { return }
        let n = min(max(count, 0), columns - x)
        guard n > 0 else { return }
        splitWideCharacter(in: row, at: x)
        splitWideCharacter(in: row, at: x + n)
        let blank = Cell.blank(styleID: row.styleID(for: fill))
        row.cells.removeSubrange(x..<(x + n))
        row.cells.append(contentsOf: repeatElement(blank, count: n))
        shiftGraphemes(in: row, from: x, by: -n)
        touch(row)
    }

    private func shiftGraphemes(in row: Row, from x: Int, by delta: Int) {
        guard !row.graphemes.isEmpty else { return }
        var moved: [Int: [UInt32]] = [:]
        for (column, scalars) in row.graphemes {
            if column < x {
                moved[column] = scalars
            } else if delta < 0 && column < x - delta {
                continue  // deleted
            } else {
                let target = column + delta
                if target >= 0 && target < columns && row.cells[target].hasGrapheme { moved[target] = scalars }
            }
        }
        row.graphemes = moved
    }

    /// If `x` falls between the halves of a wide character, blanks both halves, so an edit
    /// boundary never leaves half a character behind.
    func splitWideCharacter(in row: Row, at x: Int) {
        guard x > 0 && x < columns else { return }
        if row.cells[x].width == .spacerTail && row.cells[x - 1].width == .wide {
            clearCell(row, x - 1)
            clearCell(row, x)
        }
    }

    @inline(__always)
    func clearCell(_ row: Row, _ x: Int) {
        if row.cells[x].hasGrapheme { row.graphemes[x] = nil }
        row.cells[x] = .blank(styleID: row.cells[x].styleID)
    }

    // MARK: - Tabs

    func nextTabStop(after x: Int) -> Int {
        var column = x + 1
        while column < columns - 1 && !tabStops[column] { column += 1 }
        return min(column, columns - 1)
    }

    func previousTabStop(before x: Int) -> Int {
        var column = x - 1
        while column > 0 && !tabStops[column] { column -= 1 }
        return max(column, 0)
    }

    // MARK: - Resize without reflow

    /// Changes the size by cropping or padding rows and columns; the alternate screen and
    /// programs that redraw anyway use this. The primary screen reflows instead (Reflow.swift).
    func resizeWithoutReflow(columns newColumns: Int, rows newRows: Int, fill: Style) {
        let newColumns = max(newColumns, 1)
        let newRows = max(newRows, 1)
        if newColumns != columns {
            columns = newColumns
            for row in active {
                row.setColumns(newColumns)
                touch(row)
            }
            tabStops = ScreenBuffer.defaultTabStops(columns: newColumns)
        }
        if newRows < rows {
            // Drop lines from the bottom below the cursor first, then from the top.
            var excess = rows - newRows
            while excess > 0 && active.count - 1 > cursor.y {
                recycle(active.removeLast())
                excess -= 1
            }
            while excess > 0 {
                pushToScrollback(active.removeFirst())
                cursor.y -= 1
                excess -= 1
            }
        } else if newRows > rows {
            for _ in rows..<newRows { active.append(makeRow(fill: fill)) }
        }
        rows = newRows
        columns = newColumns
        scrollTop = 0
        scrollBottom = newRows - 1
        cursor.x = min(cursor.x, newColumns - 1)
        cursor.y = min(max(cursor.y, 0), newRows - 1)
        cursor.pendingWrap = false
    }

    /// Installs resized content (see Reflow.swift): the new active rows and scrollback.
    func install(active newActive: [Row], scrollback newScrollback: ArraySlice<Row>, columns newColumns: Int) {
        if newColumns != columns { tabStops = ScreenBuffer.defaultTabStops(columns: newColumns) }
        columns = newColumns
        rows = newActive.count
        active = newActive
        for row in active { touch(row) }
        replaceScrollback(with: newScrollback)
        scrollTop = 0
        scrollBottom = rows - 1
    }
}
