/// The rectangular-area operations: DECFRA, DECERA, DECSERA and DECCRA.
///
/// They address the page rather than the scroll region, so the margins have nothing to do with
/// them beyond origin mode's own offset, which the terminal applies before the ranges arrive
/// here. Every range is 0-based and inclusive, already clipped to the screen.
extension ScreenBuffer {
    /// DECFRA: every cell of the rectangle becomes one character in `pen`.
    func fillRectangle(_ scalar: UInt32, rows: ClosedRange<Int>, columns: ClosedRange<Int>, pen: Style) {
        for y in rows {
            let row = active[y]
            splitWideCharacter(in: row, at: columns.lowerBound)
            splitWideCharacter(in: row, at: columns.upperBound + 1)
            let styleID = row.styleID(for: pen)
            for x in columns {
                if row.cells[x].hasGrapheme { row.graphemes[x] = nil }
                row.cells[x] = Cell(scalar: scalar, styleID: styleID, protected: cursor.protected)
            }
            touch(row)
        }
    }

    /// DECERA and DECSERA: the rectangle erased, the selective form sparing protected cells.
    /// The rows keep their prompt marks and command records: a rectangle is a program drawing,
    /// not a screen being replaced, and the text outside it is still about the same command.
    func eraseRectangle(rows: ClosedRange<Int>, columns: ClosedRange<Int>, fill: Style, selective: Bool) {
        for y in rows {
            erase(row: y, from: columns.lowerBound, to: columns.upperBound + 1, fill: fill, selective: selective)
        }
    }

    /// DECCRA: the rectangle copied so that its top-left lands on `row` and `column`, truncated
    /// where the screen ends.
    ///
    /// The source is lifted into rows of its own first, which is what makes a destination that
    /// overlaps it come out right: DEC describes the copy as if the rectangle were taken off the
    /// page whole and put back down, and copying in place would read cells it had just written.
    func copyRectangle(
        rows: ClosedRange<Int>, columns: ClosedRange<Int>, toRow row: Int, column: Int, fill: Style
    ) {
        let height = min(rows.count, self.rows - row)
        let width = min(columns.count, self.columns - column)
        guard height > 0, width > 0, row >= 0, column >= 0 else { return }
        let window = columns.lowerBound...(columns.lowerBound + width - 1)
        var lifted: [Row] = []
        lifted.reserveCapacity(height)
        for offset in 0..<height {
            let copy = makeRow(fill: fill)
            copyCells(from: active[rows.lowerBound + offset], columns: window, to: copy, at: window.lowerBound)
            lifted.append(copy)
        }
        for (offset, copy) in lifted.enumerated() {
            copyCells(from: copy, columns: window, to: active[row + offset], at: column)
            recycle(copy)
        }
    }
}
