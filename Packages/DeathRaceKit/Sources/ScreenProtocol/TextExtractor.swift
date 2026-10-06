import VTCore

/// A place in a session's text: a line number (see `Terminal.linesScrolledOff`) and a
/// column. Line numbers stay with their lines as output scrolls, so a selection made of
/// points keeps holding the same text until the screen is replaced.
public struct TextPoint: Sendable, Hashable, Comparable {
    public var line: UInt64
    public var column: Int

    public init(line: UInt64, column: Int) {
        self.line = line
        self.column = column
    }

    public static func < (a: TextPoint, b: TextPoint) -> Bool {
        (a.line, a.column) < (b.line, b.column)
    }
}

/// Text between two points, both included: running from one to the other through the
/// lines between, or, when rectangular, the same columns on every line. (Not "TextRange":
/// on macOS, Foundation brings in a Carbon struct of that name.)
public struct TextRegion: Sendable, Hashable {
    public var start: TextPoint
    public var end: TextPoint
    public var isRectangular: Bool

    /// The range between `a` and `b`, in whichever order they come.
    public init(_ a: TextPoint, _ b: TextPoint, rectangular: Bool = false) {
        isRectangular = rectangular
        if rectangular {
            start = TextPoint(line: min(a.line, b.line), column: min(a.column, b.column))
            end = TextPoint(line: max(a.line, b.line), column: max(a.column, b.column))
        } else {
            start = min(a, b)
            end = max(a, b)
        }
    }

    public var lines: ClosedRange<UInt64> { start.line...end.line }

    /// The columns selected on `line`, before clipping to its width.
    public func columns(on line: UInt64, width: Int) -> ClosedRange<Int>? {
        guard lines.contains(line), width > 0 else { return nil }
        if isRectangular { return start.column...end.column }
        let first = line == start.line ? start.column : 0
        let last = line == end.line ? end.column : width - 1
        return first <= last ? first...last : nil
    }

    public func contains(_ point: TextPoint) -> Bool {
        columns(on: point.line, width: Int.max)?.contains(point.column) ?? false
    }
}

/// A line of cells text can be read from: the engine's rows and the app's copies of them.
public protocol TextLine {
    var cells: ContiguousArray<Cell> { get }
    /// The line continues on the next row (a soft wrap).
    var isWrapped: Bool { get }
    func scalars(at column: Int) -> [UInt32]
}

extension Row: TextLine {}
extension RowSnapshot: TextLine {}

/// Reads the text of a range the way it was written: soft-wrapped rows join into one line,
/// each character comes once however many cells it covers, and the blanks a line ends with
/// are left out.
public enum TextExtractor {
    /// The most lines one region may be read across.
    ///
    /// A selection cannot be longer than the scrollback, which at the default budget is tens
    /// of thousands of lines. The cap is here because the line numbers can come from another
    /// process once a daemon holds the session: a region ending at `UInt64.max` would
    /// otherwise walk for ever on the thread that owns the engine, and that session's shell
    /// would never answer again. The wire refuses such a region too; this is the backstop.
    public static let longestRegion = 2_000_000

    /// The text of `range`; `line` gives the line with a number, or nil for one that is gone
    /// (trimmed from history), which then contributes nothing.
    public static func text(in range: TextRegion, line: (UInt64) -> (any TextLine)?) -> String {
        var out = ""
        var number = range.start.line
        var left = longestRegion
        while true {
            if left == 0 { break }
            left -= 1
            if let row = line(number) {
                let isLast = number == range.end.line
                let joinsNext = !range.isRectangular && !isLast && row.isWrapped
                if let columns = range.columns(on: number, width: row.cells.count) {
                    var text = self.text(of: row, columns: columns)
                    if !joinsNext || columns.upperBound < row.cells.count - 1 { trimTrailingSpaces(&text) }
                    out += text
                }
                if !isLast && !joinsNext { out += "\n" }
            }
            if number == range.end.line { break }
            number += 1
        }
        return out
    }

    /// The characters in `columns` of `row`, empty cells as spaces.
    static func text(of row: any TextLine, columns: ClosedRange<Int>) -> String {
        let cells = row.cells
        guard !cells.isEmpty else { return "" }
        var first = max(columns.lowerBound, 0)
        let last = min(columns.upperBound, cells.count - 1)
        // Starting on the right half of a wide character takes the whole character.
        if first > 0, first <= last, cells[first].width == .spacerTail { first -= 1 }
        guard first <= last else { return "" }
        var out = ""
        for column in first...last {
            switch cells[column].width {
            case .spacerTail, .spacerHead:
                continue
            case .narrow, .wide:
                let scalars = row.scalars(at: column)
                if scalars.isEmpty {
                    out.unicodeScalars.append(" ")
                } else {
                    for scalar in scalars { out.unicodeScalars.append(Unicode.Scalar(scalar) ?? "\u{FFFD}") }
                }
            }
        }
        return out
    }

    private static func trimTrailingSpaces(_ text: inout String) {
        while text.unicodeScalars.last == " " { text.unicodeScalars.removeLast() }
    }
}

extension Terminal {
    /// The row with line number `number` on the screen programs draw on: in scrollback or
    /// on the screen, or nil when it has been trimmed or has not been written yet.
    public func line(_ number: UInt64) -> Row? {
        let firstOnScreen = linesScrolledOff
        if number >= firstOnScreen {
            let y = number - firstOnScreen
            return y < UInt64(rows) ? row(Int(y)) : nil
        }
        let firstKept = firstOnScreen - UInt64(scrollbackCount)
        guard number >= firstKept else { return nil }
        return scrollbackRow(Int(number - firstKept))
    }
}

extension MirrorGrid {
    /// The viewport row with line number `number`, if it is in view.
    public func line(_ number: UInt64) -> RowSnapshot? {
        guard number >= viewportTopLine else { return nil }
        let y = number - viewportTopLine
        return y < UInt64(lines.count) ? lines[Int(y)] : nil
    }

    /// Every line the session still has, history and screen: what Select All selects. Nil
    /// before the first delta.
    public var allLines: TextRegion? {
        guard generation != nil, columns > 0, rows > 0 else { return nil }
        // Line numbers come from the session; a bad delta must not trap here.
        let scrolledOff = viewportTopLine &+ UInt64(max(viewportOffset, 0))
        let first = scrolledOff >= UInt64(scrollbackCount) ? scrolledOff - UInt64(scrollbackCount) : 0
        return TextRegion(
            TextPoint(line: first, column: 0), TextPoint(line: scrolledOff &+ UInt64(rows - 1), column: columns - 1))
    }

    /// The text of `range` if every line of it is in view; nil when some of it has to come
    /// from the session.
    public func text(in range: TextRegion) -> String? {
        guard range.start.line >= viewportTopLine, range.end.line >= viewportTopLine,
            range.end.line - viewportTopLine < UInt64(lines.count)
        else { return nil }
        return TextExtractor.text(in: range) { line($0) }
    }
}
