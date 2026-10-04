import ScreenProtocol
import VTCore

/// Where points in the view fall on the grid. Points are the view's, origin top-left, y down.
public struct CellGeometry: Sendable, Equatable {
    public var cell: CellMetrics
    public var layout: GridLayout

    public init(cell: CellMetrics, layout: GridLayout) {
        self.cell = cell
        self.layout = layout
    }

    /// The column under `x`, clamped to the grid.
    public func column(atX x: Double) -> Int {
        min(max(Int(((x - layout.left) / cell.pointWidth).rounded(.down)), 0), layout.columns - 1)
    }

    /// The row under `y`, not clamped: negative above the grid and `rows` or more below it,
    /// so a drag past the edges can scroll.
    public func row(atY y: Double) -> Int {
        Int(((y - layout.top) / cell.pointHeight).rounded(.down))
    }

    /// The boundary between cells nearest `x`, from 0 (before the first cell) to `columns`
    /// (after the last). Selections run between boundaries: a press in the left half of a
    /// cell starts before it, in the right half after it.
    public func boundary(atX x: Double) -> Int {
        min(max(Int(((x - layout.left) / cell.pointWidth).rounded()), 0), layout.columns)
    }

    /// Device-pixel coordinates inside the grid, for SGR-Pixels mouse reports (mode 1016).
    public func pixel(atX x: Double, y: Double) -> (x: Int, y: Int) {
        let px = Int(((x - layout.left) * cell.scale).rounded(.down))
        let py = Int(((y - layout.top) * cell.scale).rounded(.down))
        return (
            min(max(px, 0), layout.columns * cell.width - 1), min(max(py, 0), layout.rows * cell.height - 1)
        )
    }

    /// A cell's rectangle in points, `cells` wide.
    public func rect(column: Int, row: Int, cells: Int = 1) -> (x: Double, y: Double, width: Double, height: Double) {
        (
            layout.left + Double(column) * cell.pointWidth, layout.top + Double(row) * cell.pointHeight,
            Double(cells) * cell.pointWidth, cell.pointHeight
        )
    }
}

/// What double-clicking selects: a run of word characters (letters, digits and the
/// punctuation inside paths, URLs and e-mail addresses), a run of blanks, or one other
/// character.
public enum WordRules {
    /// Characters that end a word.
    static let separators: Set<UInt32> = Set("\"'`()[]{}<>|│,;".unicodeScalars.map(\.value))

    enum Class: Equatable {
        case blank, word, separator(UInt32)
    }

    static func classify(_ scalars: [UInt32]) -> Class {
        guard let first = scalars.first, first != 0x20, first != 0x09 else { return .blank }
        return separators.contains(first) ? .separator(first) : .word
    }

    /// The columns of the word at `column`.
    public static func word(in row: any TextLine, at column: Int) -> ClosedRange<Int> {
        let cells = row.cells
        guard !cells.isEmpty else { return 0...0 }
        var column = min(max(column, 0), cells.count - 1)
        if cells[column].width == .spacerTail, column > 0 { column -= 1 }
        let kind = classify(row.scalars(at: column))
        if case .separator = kind { return column...(cells[column].width == .wide ? column + 1 : column) }
        func sameKind(_ x: Int) -> Bool {
            if cells[x].width == .spacerTail { return true }
            return classify(row.scalars(at: x)) == kind
        }
        var start = column
        while start > 0, sameKind(start - 1) { start -= 1 }
        var end = column
        while end + 1 < cells.count, sameKind(end + 1) { end += 1 }
        // A word never starts on the right half of a wide character.
        if cells[start].width == .spacerTail { start += 1 }
        return start...end
    }
}

/// A selection being made with the mouse, and the text range it covers.
///
/// Points are text points (line numbers, see `TextPoint`), so the selection stays on its
/// text as output scrolls. Character selections run between cell boundaries; word and line
/// selections grow by whole words and lines from where they started; rectangles take the
/// same columns from every line.
public struct Selection: Sendable, Equatable {
    public enum Granularity: Sendable, Equatable {
        case character, word, line
    }

    /// Where the pointer is: a line, the cell under it, and the boundary nearest it.
    public struct Point: Sendable, Equatable {
        public var line: UInt64
        public var column: Int
        public var boundary: Int

        public init(line: UInt64, column: Int, boundary: Int) {
            self.line = line
            self.column = column
            self.boundary = boundary
        }
    }

    public private(set) var granularity: Granularity
    public private(set) var isRectangular: Bool
    /// The unit the selection started on: a boundary for characters (start == end), a word
    /// or a line.
    private var anchorStart: TextPoint
    private var anchorEnd: TextPoint
    private var head: TextPoint
    private var headEnd: TextPoint
    public private(set) var range: TextRange?

    /// Starts a selection at `point`. `line` gives the rows words and lines are read from.
    public init(
        at point: Point, granularity: Granularity, rectangular: Bool, columns: Int, line: (UInt64) -> (any TextLine)?
    ) {
        self.granularity = rectangular ? .character : granularity
        isRectangular = rectangular
        let unit = Self.unit(
            at: point, granularity: self.granularity, rectangular: rectangular, columns: columns, line: line)
        anchorStart = unit.start
        anchorEnd = unit.end
        head = unit.start
        headEnd = unit.end
        range = nil
        updateRange()
    }

    /// The pointer moved to `point`.
    public mutating func extend(to point: Point, columns: Int, line: (UInt64) -> (any TextLine)?) {
        let unit = Self.unit(
            at: point, granularity: granularity, rectangular: isRectangular, columns: columns, line: line)
        head = unit.start
        headEnd = unit.end
        updateRange()
    }

    private mutating func updateRange() {
        if isRectangular {
            range = TextRange(anchorStart, head, rectangular: true)
            return
        }
        switch granularity {
        case .character:
            // Between boundaries: nothing until the pointer leaves the boundary it started on.
            let a = anchorStart
            let b = head
            guard a != b else {
                range = nil
                return
            }
            let (from, to) = a < b ? (a, b) : (b, a)
            range = TextRange(from, TextPoint(line: to.line, column: to.column - 1))
        case .word, .line:
            let from = min(anchorStart, head)
            let to = max(anchorEnd, headEnd)
            range = TextRange(from, to)
        }
    }

    /// The unit at a point: for characters a boundary (start and end the same), for a
    /// rectangle the cell, for a word its columns, for a line all of it across soft wraps.
    private static func unit(
        at point: Point, granularity: Granularity, rectangular: Bool, columns: Int, line: (UInt64) -> (any TextLine)?
    ) -> (start: TextPoint, end: TextPoint) {
        if rectangular {
            let cell = TextPoint(line: point.line, column: point.column)
            return (cell, cell)
        }
        switch granularity {
        case .character:
            let boundary = TextPoint(line: point.line, column: point.boundary)
            return (boundary, boundary)
        case .word:
            guard let row = line(point.line) else {
                let cell = TextPoint(line: point.line, column: point.column)
                return (cell, cell)
            }
            let word = WordRules.word(in: row, at: point.column)
            return (
                TextPoint(line: point.line, column: word.lowerBound),
                TextPoint(line: point.line, column: word.upperBound)
            )
        case .line:
            var first = point.line
            while first > 0, let previous = line(first - 1), previous.isWrapped { first -= 1 }
            var last = point.line
            while let row = line(last), row.isWrapped, line(last + 1) != nil { last += 1 }
            return (TextPoint(line: first, column: 0), TextPoint(line: last, column: max(columns - 1, 0)))
        }
    }
}
