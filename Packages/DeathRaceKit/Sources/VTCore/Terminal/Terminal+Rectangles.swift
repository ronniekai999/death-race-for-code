extension Terminal {
    /// The rectangle a `$`-intermediate sequence names, as 0-based inclusive ranges.
    ///
    /// On the wire it is 1-based and inclusive, counted from the margins' own corner in origin
    /// mode, and clipped to the screen. A rectangle that is inside out is nil, which is DEC's
    /// rule that such a request does nothing — and what keeps esctest's "invalid rectangle does
    /// nothing" tests passing now that the sequences exist.
    func rectangle(_ p: Params, from index: Int) -> (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? {
        let s = screen
        let originRow = modes.origin ? s.scrollTop : 0
        let originColumn = modes.origin ? s.scrollLeft : 0
        let top = originRow + Int(p.value(at: index, default: 1)) - 1
        let left = originColumn + Int(p.value(at: index + 1, default: 1)) - 1
        let bottom = min(originRow + Int(p.value(at: index + 2, default: UInt16(clamping: s.rows))) - 1, s.rows - 1)
        let right = min(
            originColumn + Int(p.value(at: index + 3, default: UInt16(clamping: s.columns))) - 1, s.columns - 1)
        guard top >= 0, left >= 0, top <= bottom, left <= right else { return nil }
        return (top...bottom, left...right)
    }

    /// DECFRA `CSI Pch ; Pt ; Pl ; Pb ; Pr $ x`. DEC allows the printable Latin-1 characters
    /// and nothing else, so anything outside those two ranges is not a fill request at all.
    func fillRectangle(_ p: Params) {
        let scalar = UInt32(p.value(at: 0, default: 32))
        guard (32...126).contains(scalar) || (160...255).contains(scalar) else { return }
        guard let area = rectangle(p, from: 1) else { return }
        screen.fillRectangle(scalar, rows: area.rows, columns: area.columns, pen: screen.cursor.pen)
    }

    /// DECERA `CSI Pt ; Pl ; Pb ; Pr $ z` and DECSERA `… $ {`.
    func eraseRectangle(_ p: Params, selective: Bool) {
        guard let area = rectangle(p, from: 0) else { return }
        screen.eraseRectangle(
            rows: area.rows, columns: area.columns, fill: screen.cursor.pen.erasing,
            sparingProtected: sparesProtected(selective ? .selectiveRectangle : .plain))
    }

    /// DECCRA `CSI Pts ; Pls ; Pbs ; Prs ; Pps ; Ptd ; Pld ; Ppd $ v`.
    ///
    /// The page numbers are read and ignored: this terminal has one page, so a copy between
    /// pages is a copy on the only page there is, which is what a VT420 with one page does.
    func copyRectangle(_ p: Params) {
        let s = screen
        guard let source = rectangle(p, from: 0) else { return }
        let originRow = modes.origin ? s.scrollTop : 0
        let originColumn = modes.origin ? s.scrollLeft : 0
        let row = originRow + Int(p.value(at: 5, default: 1)) - 1
        let column = originColumn + Int(p.value(at: 6, default: 1)) - 1
        guard row < s.rows, column < s.columns else { return }
        s.copyRectangle(
            rows: source.rows, columns: source.columns, toRow: row, column: column, fill: s.cursor.pen.erasing)
    }
}
