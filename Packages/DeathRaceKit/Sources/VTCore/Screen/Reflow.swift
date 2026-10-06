/// Resizing the primary screen: soft-wrapped lines are joined and wrapped again at the new
/// width, the scrollback included, so making a window narrower never chops output and making
/// it wider un-wraps what was wrapped.
extension ScreenBuffer {
    func reflow(columns newColumnsIn: Int, rows newRowsIn: Int) {
        let newColumns = max(newColumnsIn, 1)
        let newRows = max(newRowsIn, 1)

        // Every row, oldest first: scrollback, then the active area.
        var old: [Row] = []
        old.reserveCapacity(scrollback.count + active.count)
        for index in 0..<scrollback.count { old.append(scrollback[index]) }
        let oldFirstActive = old.count
        old.append(contentsOf: active)
        let oldCursorRow = oldFirstActive + cursor.y

        var lines: [Row]
        var firstActive: Int
        var cursorRow: Int
        var cursorX: Int
        var pendingWrap: Bool
        if newColumns == columns {
            // Same width: rows keep their content and identity; only the split between
            // scrollback and the active area moves.
            lines = old
            firstActive = oldFirstActive
            cursorRow = oldCursorRow
            cursorX = cursor.x
            pendingWrap = cursor.pendingWrap
        } else {
            var writer = ReflowWriter(screen: self, columns: newColumns)
            firstActive = 0
            var index = 0
            while index < old.count {
                var end = index
                while end < old.count - 1 && old[end].isWrapped { end += 1 }
                if (index...end).contains(oldFirstActive) { firstActive = writer.rows.count }
                writer.write(
                    line: old[index...end], cursorOffset: cursorOffset(in: old, line: index...end, at: oldCursorRow))
                index = end + 1
            }
            lines = writer.rows
            (cursorRow, cursorX, pendingWrap) = writer.cursor ?? (lines.count - 1, 0, false)
            for row in old { recycle(row) }
        }

        // Too tall: blank rows below the cursor go first, so output is not pushed into
        // scrollback to make room for nothing.
        while lines.count - firstActive > newRows && lines.count - 1 > cursorRow && lines[lines.count - 1].isBlank {
            recycle(lines.removeLast())
        }

        var top: Int
        if lines.count - firstActive > newRows {
            top = lines.count - newRows  // the oldest active lines scroll into scrollback
        } else if cursorRow == lines.count - 1 {
            top = max(0, lines.count - newRows)  // anchored at the bottom: scrollback comes down to fill
        } else {
            top = firstActive  // blank space below the cursor stays; the scrollback stays put
        }
        top = min(top, cursorRow)
        top = max(top, cursorRow - newRows + 1, 0)

        var newActive = Array(lines[top..<min(lines.count, top + newRows)])
        for row in lines[min(lines.count, top + newRows)...] { recycle(row) }
        while newActive.count < newRows { newActive.append(makeRow(fill: .default, columns: newColumns)) }

        install(active: newActive, scrollback: lines[..<top], columns: newColumns)
        cursor.y = cursorRow - top
        cursor.x = min(cursorX, newColumns - 1)
        cursor.pendingWrap = pendingWrap && cursor.x == newColumns - 1
    }

    /// Where the cursor sits in a logical line, counted in cells from the line's start, or
    /// nil when it is on another line. A pending wrap counts as the cell after the last.
    private func cursorOffset(in rows: [Row], line: ClosedRange<Int>, at cursorRow: Int) -> Int? {
        guard line.contains(cursorRow) else { return nil }
        var offset = 0
        for index in line.lowerBound..<cursorRow {
            let row = rows[index]
            offset += row.cells.last?.width == .spacerHead ? row.columns - 1 : row.columns
        }
        return offset + cursor.x + (cursor.pendingWrap ? 1 : 0)
    }
}

/// Lays the cells of logical lines out in rows of a new width.
private struct ReflowWriter {
    unowned let screen: ScreenBuffer
    let columns: Int
    private(set) var rows: [Row] = []
    /// Where the cursor landed: row index in `rows`, column, pending wrap.
    private(set) var cursor: (row: Int, x: Int, pendingWrap: Bool)?

    private var x = 0
    /// Cells of the current logical line written so far; a wide character counts two.
    private var offset = 0
    private var cursorTarget: Int?

    /// Style ids of the source row, translated into the current row's table.
    private var styleMap: [UInt16] = []
    private var mapSource: Row?
    private var mapTarget: Row?
    /// The same for link indexes.
    private var linkMap: [UInt16] = []
    private var linkSource: Row?
    private var linkTarget: Row?

    init(screen: ScreenBuffer, columns: Int) {
        self.screen = screen
        self.columns = columns
    }

    private var current: Row { rows[rows.count - 1] }

    mutating func write(line: ArraySlice<Row>, cursorOffset: Int?) {
        let first = screen.makeRow(fill: .default, columns: columns)
        for row in line {
            first.promptMarks.formUnion(row.promptMarks)
            if let command = row.command { first.command = command }
        }
        rows.append(first)
        x = 0
        offset = 0
        cursorTarget = cursorOffset

        let last = line.endIndex - 1
        for index in line.indices {
            let row = line[index]
            let length = index == last ? row.contentLength : row.columns
            for column in 0..<length {
                let cell = row.cells[column]
                switch cell.width {
                case .spacerTail, .spacerHead: continue  // a tail travels with its head; a head only marked a wrap
                case .wide: put(cell, from: row, at: column, width: 2)
                case .narrow: put(cell, from: row, at: column, width: 1)
                }
            }
        }

        // A cursor past the end of the text keeps its place: pad up to it.
        if let target = cursorTarget {
            while offset < target { put(.empty, from: nil, at: 0, width: 1) }
            cursor = x >= columns ? (rows.count - 1, columns - 1, true) : (rows.count - 1, x, false)
            cursorTarget = nil
        }
    }

    private mutating func put(_ cell: Cell, from source: Row?, at sourceColumn: Int, width: Int) {
        if x >= columns { wrap() }
        let fits = width == 1 || columns >= 2
        if width == 2 && fits && x == columns - 1 {
            // Too wide for the last column: a spacer head, and the character starts the next row.
            current.cells[x] = Cell(scalar: 0, width: .spacerHead, styleID: 0)
            wrap()
        }
        if let target = cursorTarget, offset <= target, target < offset + width {
            cursor = (rows.count - 1, min(x + target - offset, columns - 1), false)
            cursorTarget = nil
        }

        let styleID = source.map { translate(cell.styleID, from: $0) } ?? 0
        let link = source.map { translateLink(cell.linkIndex, from: $0) } ?? 0
        var placed = cell
        placed.styleID = styleID
        placed.linkIndex = link
        if !fits { placed.width = .narrow }  // a one-column screen cannot hold a wide character
        current.cells[x] = placed
        if cell.hasGrapheme, let source, let extra = source.graphemes[sourceColumn] {
            current.graphemes[x] = extra
        }
        if width == 2 && fits {
            current.cells[x + 1] = Cell(
                scalar: 0, width: .spacerTail, styleID: styleID, protected: cell.isProtected, link: link)
            x += 2
        } else {
            x += 1
        }
        offset += width
    }

    private mutating func wrap() {
        current.isWrapped = true
        rows.append(screen.makeRow(fill: .default, columns: columns))
        x = 0
    }

    private mutating func translate(_ id: UInt16, from source: Row) -> UInt16 {
        guard id != 0 else { return 0 }
        if mapSource !== source || mapTarget !== current {
            mapSource = source
            mapTarget = current
            styleMap = [UInt16](repeating: .max, count: source.styles.count)
        }
        let index = Int(id)
        guard index < styleMap.count else { return 0 }
        if styleMap[index] == .max {
            let before = current.styles.count
            let translated = current.styleID(for: source.styles[index])
            // Compaction renumbers the row's styles; earlier translations are then stale.
            if current.styles.count < before { styleMap = [UInt16](repeating: .max, count: source.styles.count) }
            styleMap[index] = translated
        }
        return styleMap[index]
    }

    private mutating func translateLink(_ index: UInt16, from source: Row) -> UInt16 {
        guard index != 0, Int(index) <= source.links.count else { return 0 }
        if linkSource !== source || linkTarget !== current {
            linkSource = source
            linkTarget = current
            linkMap = [UInt16](repeating: .max, count: source.links.count + 1)
        }
        let slot = Int(index)
        if linkMap[slot] == .max {
            let before = current.links.count
            let translated = current.linkIndex(for: source.links[slot - 1])
            // Compaction renumbers the row's links; earlier translations are then stale.
            if current.links.count < before { linkMap = [UInt16](repeating: .max, count: source.links.count + 1) }
            linkMap[slot] = translated
        }
        return linkMap[slot]
    }
}
