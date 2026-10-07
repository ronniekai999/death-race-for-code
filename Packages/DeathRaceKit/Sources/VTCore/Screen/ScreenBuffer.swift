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
    /// Lines that have ever left the top of this screen, whether scrollback kept them or not.
    /// It numbers lines for good: the active row `y` is line `linesScrolledOff + y`, and
    /// scrollback row `i` is line `linesScrolledOff - scrollback.count + i`, however much
    /// history is trimmed. A viewport scrolled into history stays on the same lines with it,
    /// and selections hold on to text by it. Reflow re-adds every line; it also bumps the
    /// terminal's generation, which tells readers to start over.
    private(set) var linesScrolledOff: UInt64 = 0

    var cursor = Cursor()
    var savedCursor: SavedCursor?
    /// The scroll region (DECSTBM), inclusive.
    var scrollTop = 0
    var scrollBottom: Int
    /// The left and right margins (DECSLRM), inclusive. The buffer only keeps them: they
    /// bound printing, scrolling and the cursor while DECLRMM (mode 69) is on, and the mode
    /// is the terminal's.
    var scrollLeft = 0
    var scrollRight: Int
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
        self.scrollRight = self.columns - 1
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

    /// True when the margins are the whole width — which is also exactly when DECLRMM is off,
    /// since the terminal puts them back as the mode goes off. So nothing below has to know
    /// about the mode, and the cheap whole-row paths stay in place for every program that
    /// never sets DECSLRM.
    var isFullWidthMargins: Bool { scrollLeft == 0 && scrollRight == columns - 1 }

    /// The last column printing and tabbing may use: the right margin, unless the cursor is
    /// already past it, in which case the screen's own edge. The same shape as the bound
    /// `cursorDown` uses against the scroll region, and it is what xterm does.
    var rightLimit: Int { cursor.x <= scrollRight ? scrollRight : columns - 1 }

    /// Where the cursor stops going left: the left margin, unless it is already left of it.
    var leftLimit: Int { cursor.x >= scrollLeft ? scrollLeft : 0 }

    /// Scrolling and the editing sequences act for a cursor between the margins and do
    /// nothing at all for one outside them.
    var cursorIsBetweenMargins: Bool { cursor.x >= scrollLeft && cursor.x <= scrollRight }

    /// Both regions back to the whole screen, which is what RIS, DECSTR, DECALN, DECCOLM and
    /// a resize all leave behind.
    func resetMargins() {
        scrollTop = 0
        scrollBottom = rows - 1
        resetLeftRightMargins()
    }

    /// Only the left and right margins: turning DECLRMM off puts these back and leaves the
    /// scroll region, which is not its business, alone.
    func resetLeftRightMargins() {
        scrollLeft = 0
        scrollRight = columns - 1
    }

    // MARK: - Scrolling

    /// Scrolls the region up: lines leave at the top, blank lines enter at the bottom.
    /// Lines leaving a region that starts at the top of the primary screen go to scrollback,
    /// as in xterm, even when the region ends above the bottom.
    func scrollUp(_ count: Int, fill: Style) {
        let height = scrollBottom - scrollTop + 1
        let n = min(max(count, 0), height)
        guard n > 0 else { return }
        guard isFullWidthMargins else {
            scrollColumnsUp(n, in: scrollTop...scrollBottom, fill: fill)
            return
        }
        for _ in 0..<n {
            let leaving = active.remove(at: scrollTop)
            if scrollTop == 0 {
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
        guard isFullWidthMargins else {
            scrollColumnsDown(n, in: scrollTop...scrollBottom, fill: fill)
            return
        }
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
        guard isFullWidthMargins else {
            scrollColumnsDown(n, in: y...scrollBottom, fill: fill)
            return
        }
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
        guard isFullWidthMargins else {
            scrollColumnsUp(n, in: y...scrollBottom, fill: fill)
            return
        }
        for _ in 0..<n {
            recycle(active.remove(at: y))
            active.insert(makeRow(fill: fill), at: scrollBottom)
        }
    }

    // MARK: - Scrolling between left and right margins

    /// With left and right margins, scrolling moves the cells *between* them from row to row
    /// rather than moving whole rows: every cell outside the margins stays exactly where it
    /// is, and nothing reaches scrollback, because a line that only partly moved is not a
    /// line that left the screen.
    private func scrollColumnsUp(_ n: Int, in rows: ClosedRange<Int>, fill: Style) {
        for y in rows {
            if y + n <= rows.upperBound {
                copyColumns(from: active[y + n], to: active[y])
            } else {
                erase(row: y, from: scrollLeft, to: scrollRight + 1, fill: fill)
            }
        }
    }

    private func scrollColumnsDown(_ n: Int, in rows: ClosedRange<Int>, fill: Style) {
        for y in rows.reversed() {
            if y - n >= rows.lowerBound {
                copyColumns(from: active[y - n], to: active[y])
            } else {
                erase(row: y, from: scrollLeft, to: scrollRight + 1, fill: fill)
            }
        }
    }

    private func copyColumns(from source: Row, to target: Row) {
        copyCells(from: source, columns: scrollLeft...scrollRight, to: target, at: scrollLeft)
    }

    /// Copies `columns` of one row into another, landing at `destination`. A cell's style and
    /// its link are indexes into the table of the row that holds it, so both are looked up
    /// again in the row the cell lands on, and a two-column character cut by either end of the
    /// window loses the half that moved rather than leaving a head with no tail.
    ///
    /// A row cannot be copied onto itself: within one row the cells overlap, and shifting them
    /// is `shiftBetweenMargins`' job. DECCRA lifts its rectangle into rows of its own first for
    /// the same reason.
    func copyCells(from source: Row, columns: ClosedRange<Int>, to target: Row, at destination: Int) {
        guard source !== target, destination >= 0 else { return }
        let width = min(columns.count, self.columns - destination)
        guard width > 0 else { return }
        let last = destination + width - 1
        splitWideCharacter(in: target, at: destination)
        splitWideCharacter(in: target, at: last + 1)
        var lastStyle: (source: UInt16, target: UInt16)?
        for offset in 0..<width {
            let from = columns.lowerBound + offset
            let to = destination + offset
            if target.cells[to].hasGrapheme { target.graphemes[to] = nil }
            var cell = source.cells[from]
            if cell.styleID != 0 {
                if let known = lastStyle, known.source == cell.styleID {
                    cell.styleID = known.target
                } else {
                    let mapped = target.styleID(for: source.style(of: cell))
                    lastStyle = (cell.styleID, mapped)
                    cell.styleID = mapped
                }
            }
            if cell.isLinked {
                cell.linkIndex = source.link(at: from).map { target.linkIndex(for: $0) } ?? 0
            }
            target.cells[to] = cell
            if cell.hasGrapheme, let scalars = source.graphemes[from] { target.graphemes[to] = scalars }
        }
        if target.cells[destination].width == .spacerTail { clearCell(target, destination) }
        if target.cells[last].width == .wide { clearCell(target, last) }
        touch(target)
    }

    /// A line leaves the top of the screen: into scrollback, if this screen keeps any.
    func pushToScrollback(_ row: consuming Row) {
        linesScrolledOff &+= 1
        guard keepsScrollback, scrollbackLimitBytes > 0 else {
            recycle(row)
            return
        }
        scrollbackBytes += row.estimatedBytes
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

    /// The top `count` rows leave the screen without entering scrollback, and blank rows
    /// enter at the bottom; the cursor and the saved cursor move up with their lines.
    /// Line numbers keep counting, so no number is ever reused.
    func discardTopRows(_ count: Int, fill: Style) {
        let n = min(max(count, 0), rows)
        guard n > 0 else { return }
        for _ in 0..<n {
            linesScrolledOff &+= 1
            recycle(active.removeFirst())
            active.append(makeRow(fill: fill))
        }
        cursor.y = max(cursor.y - n, 0)
        if let saved = savedCursor { savedCursor?.y = max(saved.y - n, 0) }
        for row in active { touch(row) }
    }

    /// Replaces scrollback wholesale; used by reflow.
    func replaceScrollback<C: Collection<Row>>(with rows: C) {
        scrollback.removeAll()
        scrollbackBytes = 0
        for row in rows { pushToScrollback(row) }
    }

    // MARK: - Cells

    /// Blanks columns `[from, to)` of row `y` in `fill`. With `sparingProtected`, the cells
    /// somebody protected survive; which erases do that is the terminal's to decide, because it
    /// depends on whether the protection came from DECSCA or from ISO 6429's SPA.
    /// `forgetting` means the whole screen is being replaced, not redrawn, so the row's prompt
    /// marks and command record go with its text.
    ///
    /// It is a flag rather than something inferred from the range, and that distinction is
    /// load-bearing. A prompt redraws itself on every single command with `\r` then ED-to-end,
    /// which erases the cursor's row from column zero to the last column — indistinguishable
    /// by range from clearing the screen. Inferring it threw away the command record of the
    /// command that had just finished, every time, because the shell writes `OSC 133;D` on
    /// exactly that row just before the prompt redraws it.
    func erase(
        row y: Int, from start: Int, to end: Int, fill: Style, sparingProtected: Bool = false,
        forgetting: Bool = false
    ) {
        let row = active[y]
        let lower = max(0, start)
        let upper = min(columns, end)
        guard lower < upper else { return }
        splitWideCharacter(in: row, at: lower)
        splitWideCharacter(in: row, at: upper)
        let blank = Cell.blank(styleID: row.styleID(for: fill))
        if !row.graphemes.isEmpty {
            for x in lower..<upper where row.cells[x].hasGrapheme {
                guard !(sparingProtected && row.cells[x].isProtected) else { continue }
                row.graphemes[x] = nil
            }
        }
        row.cells.withUnsafeMutableBufferPointer { cells in
            if sparingProtected {
                for x in lower..<upper where !cells[x].isProtected { cells[x] = blank }
            } else {
                UnsafeMutableBufferPointer(rebasing: cells[lower..<upper]).update(repeating: blank)
            }
        }
        if upper == columns { row.isWrapped = false }
        // Clearing the screen leaves no command on these rows, so the semantic marks go with
        // the text. Without it, ED 2, RIS, the 1049 clear and DECALN all left prompt marks and
        // command records on rows they had just blanked, and a block model built from those
        // marks would draw a rail around nothing.
        if forgetting, !sparingProtected {
            row.promptMarks = []
            row.command = nil
        }
        touch(row)
    }

    /// ICH: inserts blanks at `x`, shifting the rest of the line right; cells pushed past the
    /// right edge are lost.
    func insertBlanks(_ count: Int, row y: Int, at x: Int, fill: Style) {
        guard isFullWidthMargins else {
            shiftBetweenMargins(count, row: y, at: x, by: 1, fill: fill)
            return
        }
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
        guard isFullWidthMargins else {
            shiftBetweenMargins(count, row: y, at: x, by: -1, fill: fill)
            return
        }
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

    /// DECIC: blank columns pushed in at `x` in every row of the scroll region, the rows
    /// outside it left alone. What passes the right margin is dropped rather than wrapping.
    func insertColumns(_ count: Int, at x: Int, fill: Style) {
        for y in scrollTop...scrollBottom { insertBlanks(count, row: y, at: x, fill: fill) }
    }

    /// DECDC: columns pulled out at `x` in every row of the scroll region.
    func deleteColumns(_ count: Int, at x: Int, fill: Style) {
        for y in scrollTop...scrollBottom { deleteCells(count, row: y, at: x, fill: fill) }
    }

    /// ICH and DCH between the margins: the shift runs from the cursor to the right margin
    /// and leaves every cell beyond it alone, so what passes the margin is dropped rather
    /// than pushing the rest of the line along. A cursor outside the margins shifts nothing.
    /// `direction` is +1 to insert and -1 to delete.
    private func shiftBetweenMargins(_ count: Int, row y: Int, at x: Int, by direction: Int, fill: Style) {
        guard x >= scrollLeft, x <= scrollRight else { return }
        let window = x...scrollRight
        let n = min(max(count, 0), window.count)
        guard n > 0 else { return }
        let row = active[y]
        splitWideCharacter(in: row, at: x)
        splitWideCharacter(in: row, at: scrollRight + 1)
        let blank = Cell.blank(styleID: row.styleID(for: fill))
        let source = Array(row.cells[window])
        let graphemes = row.graphemes
        var updated = graphemes
        for column in window where row.cells[column].hasGrapheme { updated[column] = nil }
        for (offset, column) in window.enumerated() {
            let from = offset - n * direction
            if from >= 0 && from < source.count {
                row.cells[column] = source[from]
                if source[from].hasGrapheme { updated[column] = graphemes[x + from] }
            } else {
                row.cells[column] = blank
            }
        }
        row.graphemes = updated
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

    /// Tabs stop at the right margin, as they do on a DEC terminal (ECMA-48 says nothing
    /// about margins), and at the screen's edge for a cursor already past it.
    func nextTabStop(after x: Int) -> Int {
        let limit = x <= scrollRight ? scrollRight : columns - 1
        var column = x + 1
        while column < limit && !tabStops[column] { column += 1 }
        return min(column, limit)
    }

    /// Backward tabs, on the other hand, go past the left margin to the first column:
    /// esctest pins that asymmetry (`CBTTests.test_CBT_IgnoresRegion`), and so does xterm.
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
        resetMargins()
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
        resetMargins()
    }
}
