import ScreenProtocol

/// Runs of cells a font draws as one glyph: `!=`, `=>`, `===`.
///
/// The work splits in two, and the split is the point. *Where a run could be* — leftmost-longest
/// munch, style boundaries, selection edges, double-width cells, the row's end, the length a
/// bitmap may reach — is text and width arithmetic, so it lives here, portable and tested on
/// every push. *Whether a face actually draws these characters differently as a unit* is a
/// question only the font can answer, so it is one protocol method, implemented with CoreText
/// where CoreText exists and with a table in tests.
///
/// The scope is deliberately punctuation, not words. Letter-side contextual alternates — the
/// texture healing Monaspace advertises — would need whole words shaped and the atlas keyed by
/// shaped run; `GlyphCache` has no eviction for glyph keys, only for the shelves under them, so
/// a key space that grows with the words someone types is a leak rather than a feature.

/// A run of columns drawn as one bitmap spanning all of them.
public struct GlyphRun: Sendable, Equatable {
    /// The run's first column.
    public var column: Int
    /// How many columns it covers; always at least two.
    public var cells: Int
    public var scalars: [UInt32]

    public init(column: Int, cells: Int, scalars: [UInt32]) {
        self.column = column
        self.cells = cells
        self.scalars = scalars
    }
}

/// Whether a face draws a run of characters differently from the same characters drawn one at a
/// time. CoreText answers it in RenderKit; a table answers it in tests.
///
/// It is not `Sendable` and it is a class, as `GlyphSource` is: answers are memoized, and the
/// whole drawing path is one thread's.
public protocol RunShaping: AnyObject {
    func shapesAsOne(_ scalars: [UInt32], bold: Bool, italic: Bool) -> Bool
}

/// Finds the runs a row would draw as single bitmaps.
public struct RunScanner: Sendable {
    /// The characters a run may be built from: the punctuation programming ligatures are made
    /// of, every one of them a single column in every monospaced face.
    public static let alphabet: Set<UInt32> = Set(
        "!#$%&*+-./:<=>?@\\^|~".unicodeScalars.map(\.value))

    /// How many columns one run may cover.
    public let maxCells: Int

    public init(maxCells: Int = 8) {
        self.maxCells = max(2, min(maxCells, GlyphKey.maxRunCells))
    }

    /// The cap that keeps a run's bitmap inside what the rasterizer will draw.
    ///
    /// This is not tidiness, it is liveness, and both failures are silent. A rasterizer that is
    /// handed a bitmap wider than its limit answers "draws nothing", and that answer is cached
    /// for as long as the atlas holds it — so an over-long run at a large font size would turn
    /// into blank space and stay blank. And a bitmap too wide for the atlas to place at all
    /// leaves the row incomplete, which means the row is rebuilt and re-asked on every frame,
    /// for ever, with no progress. Deriving the cap from the cell keeps us out of both.
    ///
    /// `limit` is the rasterizer's own bound, and a run's bitmap is wider than the columns it
    /// covers: a pixel of room for antialiasing on each side, whole-pixel rounding outwards,
    /// and — for a face with no italic of its own, which is slanted instead — ink leaning past
    /// the last column by the slant times the cell's height. So the cap is taken against the
    /// limit less that slack, not against the limit itself. A quarter of the cell's height
    /// covers a 12° slant with room to spare, which is the steepest `FontSet` applies.
    public init(cell: CellMetrics, maxCells: Int = 8, limit: Int = 1024) {
        let slack = 4 + cell.height / 4
        let byWidth = (limit - slack) / max(cell.width, 1)
        self.init(maxCells: min(maxCells, byWidth))
    }

    /// The runs in a row, sorted by column and never overlapping.
    ///
    /// A run is bounded by everything that would make one bitmap the wrong answer for the cells
    /// under it: a character outside the alphabet, a cell that is not a single column, a change
    /// of style, and a change of whether the cell is selected. The last two are what make a run
    /// safe to draw as one instance — the whole run then shares one foreground, one underline
    /// and one highlight, so a decoration crosses it unbroken and a selection edge inside it
    /// falls back to drawing its cells one by one, with the exact geometry selection needs.
    /// `face` gives the bold and italic of a column, which only a resolved style knows — so the
    /// scanner stays free of the color resolver, and a test keeps total control of the answer.
    /// It is asked once per candidate, at the run's first column, which is sound because a run
    /// never crosses a change of style.
    public func runs(
        in row: RowSnapshot, columns: Int, selected: ClosedRange<Int>?,
        face: (Int) -> (bold: Bool, italic: Bool), shaper: any RunShaping
    ) -> [GlyphRun] {
        guard maxCells >= 2 else { return [] }
        let limit = min(columns, row.cells.count)
        var found: [GlyphRun] = []
        var x = 0
        while x < limit {
            guard let head = candidate(in: row, at: x, selected: selected) else {
                x += 1
                continue
            }
            // Leftmost-longest: `===` is one run of three, not `==` and a stray `=`.
            var scalars: [UInt32] = [head]
            var end = x
            while end + 1 < limit, scalars.count < maxCells,
                sameRun(in: row, from: x, to: end + 1, selected: selected),
                let next = candidate(in: row, at: end + 1, selected: selected)
            {
                scalars.append(next)
                end += 1
            }
            let (bold, italic) = face(x)
            var best: GlyphRun?
            var count = scalars.count
            while count >= 2 {
                let run = Array(scalars[0..<count])
                if shaper.shapesAsOne(run, bold: bold, italic: italic) {
                    best = GlyphRun(column: x, cells: count, scalars: run)
                    break
                }
                count -= 1
            }
            if let best {
                found.append(best)
                x = best.column + best.cells
            } else {
                x += 1
            }
        }
        return found
    }

    /// The scalar at a column, if that column could be part of a run at all.
    private func candidate(in row: RowSnapshot, at x: Int, selected: ClosedRange<Int>?) -> UInt32? {
        let cell = row.cells[x]
        // A run is single-column characters only: a double-width character and the halves of
        // one carry VT width semantics that drive the cursor, selection and reflow, and those
        // are not ours to reinterpret.
        guard cell.width == .narrow else { return nil }
        let scalars = row.scalars(at: x)
        guard scalars.count == 1, Self.alphabet.contains(scalars[0]) else { return nil }
        return scalars[0]
    }

    /// Whether two columns may share one run: the same style, and the same selectedness.
    private func sameRun(in row: RowSnapshot, from: Int, to: Int, selected: ClosedRange<Int>?) -> Bool {
        guard row.cells[from].styleID == row.cells[to].styleID else { return false }
        return (selected?.contains(from) ?? false) == (selected?.contains(to) ?? false)
    }
}

/// Asks a shaper once for each distinct run and remembers what it said.
///
/// The scanner asks about every candidate in every row it rebuilds. Shaping a candidate with
/// CoreText costs far more than drawing it, so without this the feature would cost more than
/// it is worth on the first frame of every screenful of punctuation.
public final class MemoizedRunShaping: RunShaping {
    private let base: any RunShaping
    private let limit: Int
    private var answers: [GlyphKey: Bool] = [:]

    public init(_ base: any RunShaping, limit: Int = 4096) {
        self.base = base
        self.limit = limit
    }

    public func shapesAsOne(_ scalars: [UInt32], bold: Bool, italic: Bool) -> Bool {
        let key = GlyphKey(run: scalars, bold: bold, italic: italic)
        if let known = answers[key] { return known }
        let answer = base.shapesAsOne(scalars, bold: bold, italic: italic)
        // Past the bound the memo stops growing rather than evicting: the alphabet and the cell
        // cap make the real number of distinct runs a few hundred, so reaching the bound means
        // something unexpected is asking, and paying the shaper is better than unbounded memory.
        if answers.count < limit { answers[key] = answer }
        return answer
    }

    /// A new face or a new cell size: every answer was about the old one.
    public func forgetAll() { answers.removeAll(keepingCapacity: true) }

    /// How many answers are held, for tests and for measuring.
    public var count: Int { answers.count }
}
