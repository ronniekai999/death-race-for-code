import ConfigKit
import ScreenProtocol
import VTCore

/// One glyph to draw, as the shader's `GlyphInstance` lays it out: 24 bytes.
public struct GlyphInstance: Sendable, Equatable {
    public var cellX: UInt16
    public var cellY: UInt16
    /// The bitmap in its atlas, in pixels.
    public var atlasX: UInt16
    public var atlasY: UInt16
    public var width: UInt16
    public var height: UInt16
    /// The bitmap's top-left corner relative to the cell's, in pixels.
    public var offsetX: Int16
    public var offsetY: Int16
    /// The text color; ignored for color glyphs.
    public var color: PackedColor
    /// Bit 0: the glyph is in the color atlas. Bits 1–5: the columns it covers, less one.
    ///
    /// The shader reads bit 0 and nothing else — it sizes the quad from `width` and `height`,
    /// so a bitmap wider than a cell already draws across columns with no notion of them. The
    /// span is for the frame's own later passes, which do count columns.
    ///
    /// It is the span less one, so a one-column glyph leaves these bits zero and its whole word
    /// is what it was before runs existed. A double-width character's is not: it covers two
    /// columns and now says so, which is the point — the composing-text overlay used to filter
    /// by the column a glyph *starts* on, so a wide character one column to the left painted
    /// into what was being typed.
    public var flags: UInt32

    public static let colorAtlasFlag: UInt32 = 1
    static let cellsShift: UInt32 = 1
    private static let cellsWidth: UInt32 = 0x1F

    /// The columns this glyph covers.
    public var cells: Int { Int((flags >> Self.cellsShift) & Self.cellsWidth) + 1 }

    /// `flags` for a glyph in `atlas` covering `cells` columns.
    static func flags(atlas: AtlasKind, cells: Int) -> UInt32 {
        let span = UInt32(max(0, min(cells, Int(cellsWidth) + 1) - 1)) << cellsShift
        return (atlas == .color ? colorAtlasFlag : 0) | span
    }
}

/// What a decoration instance draws.
public enum DecorationKind: UInt8, Sendable {
    case underline = 1
    case doubleUnderline = 2
    case curlyUnderline = 3
    case dottedUnderline = 4
    case dashedUnderline = 5
    case strikethrough = 6
    case overline = 7
    /// A block's rail: a thin bar down the left edge of a run of rows, `thickness` pixels wide
    /// and as tall as the run. The one kind whose pattern is measured from the run's own left
    /// edge rather than from absolute x, because horizontal geometry is whole cells and a
    /// cell-wide bar would sit on the first character of every line.
    case rail = 8
}

/// What block chrome is drawn in.
///
/// Resolved colors rather than a theme: a `FrameBuilder` knows a terminal's palette, not the
/// window's chrome, and the rail and the band are the window's. Settable on the view, so one
/// value turns the whole thing on and off.
public struct BlockColors: Sendable, Equatable {
    /// The rail of a block that went well, or has not finished. Neutral on purpose: a color on
    /// its own is not allowed to mean pass or fail (`docs/DESIGN.md` asks for a word or a ✓ / ✗
    /// beside it), and a command quick enough to need no badge has neither.
    public var rail: RGB
    /// The rail of one that failed — which always has a badge, so its ✗ is always there too.
    public var railFailed: RGB
    /// Mixed into the background of the block you are in, and no other: twenty tinted bands
    /// read as stripes, one reads as "here".
    public var band: RGB
    public var bandAmount: Double

    public init(rail: RGB, railFailed: RGB, band: RGB, bandAmount: Double = 0.35) {
        self.rail = rail
        self.railFailed = railFailed
        self.band = band
        self.bandAmount = bandAmount
    }
}

/// The blocks to draw over the grid, and the colors to draw them in.
public struct BlockChrome: Sendable, Equatable {
    public var runs: [BlockRun]
    public var colors: BlockColors

    public init(runs: [BlockRun], colors: BlockColors) {
        self.runs = runs
        self.colors = colors
    }
}

/// A line under, through or over a run of cells, as the shader's `DecorationInstance` lays
/// it out: 16 bytes. The shader draws the pattern in the box `top..<top + height` of each
/// cell, from absolute pixel positions, so dots, dashes and waves continue across cells.
public struct DecorationInstance: Sendable, Equatable {
    public var cellX: UInt16
    public var cellY: UInt16
    public var cellCount: UInt16
    public var kind: UInt8
    /// Line thickness in pixels.
    public var thickness: UInt8
    /// The box, in pixels from the cell's top.
    public var top: Int16
    public var height: Int16
    public var color: PackedColor
}

/// Everything the renderer draws for one frame, in the layout the GPU takes.
public struct Frame: Sendable {
    public var columns: Int
    public var rows: Int
    /// The padding around the grid.
    public var clearColor: PackedColor
    /// One per cell, row by row.
    public var backgrounds: [PackedColor]
    public var glyphs: [GlyphInstance]
    public var decorations: [DecorationInstance]
    /// False when some glyph was not ready: draw again on the next tick.
    public var isComplete: Bool
}

/// Builds frames from a mirror, redoing only the rows that changed.
///
/// Rows are cached by row id: a row that only moved (scrolling) is reused as it is, and its
/// cached instances are placed at its new position. Everything is rebuilt when the colors,
/// the cell size or the glyph atlas epoch change.
public final class FrameBuilder {
    private struct Inputs: Equatable {
        var palette: Palette
        var theme: Theme
        var reverseVideo: Bool
        var cell: CellMetrics
        var epoch: UInt64
        var starfield: Bool
        /// Whether runs are being shaped. Without it, turning the setting on or off would
        /// leave every cached row as it was drawn under the old answer.
        var shaping: Bool
    }

    /// The alpha byte that marks a background as starry: a row's empty end, where the
    /// background shader may draw a faint star. Everything else is opaque (0xFF).
    public static let starryAlpha: UInt32 = 0xFE

    private struct CachedRow {
        var version: UInt64
        var selection: ClosedRange<Int>?
        /// The columns composing text covers on this row, which runs are kept out of, so the
        /// row is built again when composition moves rather than keeping a stale answer.
        var preedit: Range<Int>?
        var backgrounds: [PackedColor]
        var glyphs: [GlyphInstance]
        var decorations: [DecorationInstance]
        var shelves: [UInt16]
        var complete: Bool
    }

    private var inputs: Inputs?
    private var cache: [UInt64: CachedRow] = [:]

    /// Every cached row is thrown away.
    ///
    /// `Inputs` identifies the glyph source by its `epoch` alone, and a brand-new source starts
    /// at zero — so replacing one (new faces, a new cell, thicker strokes) can leave the tuple
    /// unchanged while every cached row still holds coordinates into the atlas that was just
    /// discarded. Whoever replaces the source says so by calling this.
    public func forgetRows() {
        cache.removeAll(keepingCapacity: true)
        inputs = nil
    }
    /// Rows rebuilt by the last `build`, for tests and measurement.
    public private(set) var rebuiltRows = 0

    public init() {}

    /// The frame for `mirror` drawn with `theme` at `cell`, with `selection` highlighted and
    /// an input method's composing text (`preedit`) drawn over the cells it covers, underlined.
    /// With `starfield`, each row's empty end is marked for the shader's stars. `link`, the
    /// one ⌘ is held over, is underlined. `blocks` draws a rail beside each command and a band
    /// behind the one you are in.
    public func build(
        mirror: MirrorGrid, theme: Theme, cell: CellMetrics, selection: TextRegion?, glyphs: any GlyphSource,
        preedit: PreeditLayout? = nil, starfield: Bool = false, link: LinkHit? = nil,
        blocks: BlockChrome? = nil, shaper: (any RunShaping)? = nil
    ) -> Frame {
        let current = Inputs(
            palette: mirror.palette, theme: theme, reverseVideo: mirror.modes.reverseVideo, cell: cell,
            epoch: glyphs.epoch, starfield: starfield, shaping: shaper != nil)
        if current != inputs {
            cache.removeAll(keepingCapacity: true)
            inputs = current
        }
        let resolver = ColorResolver(palette: mirror.palette, theme: theme, reverseVideo: mirror.modes.reverseVideo)
        let columns = mirror.columns
        var frame = Frame(
            columns: columns, rows: mirror.lines.count, clearColor: resolver.clearColor.packed,
            backgrounds: [], glyphs: [], decorations: [], isComplete: true)
        frame.backgrounds.reserveCapacity(columns * mirror.lines.count)
        var shelves = Set<UInt16>()
        var visible = Set<UInt64>()
        rebuiltRows = 0

        for (y, row) in mirror.lines.enumerated() {
            let line = mirror.viewportTopLine &+ UInt64(y)
            let selected = selection?.columns(on: line, width: columns)
            // A run may not straddle the composing text: `overlay` takes out whatever reaches
            // into it, and one bitmap cannot be drawn for only part of its columns — so the
            // columns outside would be left blank. Kept out here instead, where they fall back
            // to drawing one at a time, which is what composition wants anyway.
            let composing = preedit.flatMap { $0.row == y ? $0.columns : nil }
            var cached = cache[row.id]
            if cached == nil || cached!.version != row.version || cached!.selection != selected
                || cached!.preedit != composing || !cached!.complete
            {
                cached = buildRow(
                    row, columns: columns, selected: selected, resolver: resolver, cell: cell, glyphs: glyphs,
                    starfield: starfield, shaper: shaper, composing: composing)
                cache[row.id] = cached
                rebuiltRows += 1
            }
            let rowData = cached!
            visible.insert(row.id)
            frame.isComplete = frame.isComplete && rowData.complete
            frame.backgrounds += rowData.backgrounds
            let cellY = UInt16(clamping: y)
            for var glyph in rowData.glyphs {
                glyph.cellY = cellY
                frame.glyphs.append(glyph)
            }
            for var decoration in rowData.decorations {
                decoration.cellY = cellY
                frame.decorations.append(decoration)
            }
            shelves.formUnion(rowData.shelves)
        }
        // Rows that scrolled out of view are not kept.
        if cache.count > visible.count { cache = cache.filter { visible.contains($0.key) } }
        // Before the composing text and the hovered link, so a band never tints over them.
        if let blocks { chrome(blocks, on: &frame, mirror: mirror, cell: cell) }
        if let preedit {
            overlay(preedit, on: &frame, resolver: resolver, cell: cell, glyphs: glyphs, shelves: &shelves)
        }
        if let link { underline(link, on: &frame, mirror: mirror, resolver: resolver, cell: cell) }
        glyphs.markUsed(shelves: Array(shelves))
        return frame
    }

    /// A block's rail and the current block's band. Added to the frame each time, like
    /// composing text and the hovered link, so a block appearing or the cursor moving between
    /// two of them rebuilds no rows at all.
    private func chrome(_ blocks: BlockChrome, on frame: inout Frame, mirror: MirrorGrid, cell: CellMetrics) {
        guard frame.rows > 0, frame.columns > 0 else { return }
        let top = mirror.viewportTopLine
        for run in blocks.runs {
            // Clipped to what is on screen. `Blocks.runs` only makes runs that are in view, but
            // this is public, and a run past either edge must not index past the buffers.
            guard run.lines.upperBound >= top else { continue }
            let lowerInView = run.lines.lowerBound > top ? Int(run.lines.lowerBound - top) : 0
            let upperInView = min(Int(run.lines.upperBound - top), frame.rows - 1)
            guard lowerInView <= upperInView, lowerInView < frame.rows else { continue }
            if run.isCurrent {
                band(blocks.colors, rows: lowerInView...upperInView, on: &frame)
            }
            frame.decorations.append(
                DecorationInstance(
                    cellX: 0, cellY: UInt16(clamping: lowerInView), cellCount: 1,
                    kind: DecorationKind.rail.rawValue, thickness: UInt8(clamping: cell.underlineThickness),
                    top: 0, height: Int16(clamping: (upperInView - lowerInView + 1) * cell.height),
                    color: (run.failed == true ? blocks.colors.railFailed : blocks.colors.rail).packed))
        }
    }

    /// The band, mixed into the backgrounds the rows already built.
    ///
    /// Each cell's own alpha byte is kept rather than written: `starryAlpha` is that byte, so a
    /// constant would put out every star the band covers, and a hand-packed one could make a
    /// tinted cell starry. The stars are hashed from the pixel, so they stay where they were
    /// and come back mixed from the tinted color instead of the plain one.
    private func band(_ colors: BlockColors, rows: ClosedRange<Int>, on frame: inout Frame) {
        for row in rows {
            for column in 0..<frame.columns {
                let index = row * frame.columns + column
                guard index >= 0, index < frame.backgrounds.count else { continue }
                let was = frame.backgrounds[index]
                let tinted = RGB(
                    UInt8(truncatingIfNeeded: was), UInt8(truncatingIfNeeded: was >> 8),
                    UInt8(truncatingIfNeeded: was >> 16)
                ).mixed(with: colors.band, amount: colors.bandAmount)
                frame.backgrounds[index] = (tinted.packed & 0x00FF_FFFF) | (was & 0xFF00_0000)
            }
        }
    }

    /// The hovered link's underline, in each span's text color. Added to the frame each
    /// time, like composing text, so hovering rebuilds no rows.
    private func underline(
        _ link: LinkHit, on frame: inout Frame, mirror: MirrorGrid, resolver: ColorResolver, cell: CellMetrics
    ) {
        let thickness = cell.underlineThickness
        for span in link.spans where span.row >= 0 && span.row < frame.rows {
            let columns = span.columns.clamped(to: 0..<frame.columns)
            guard !columns.isEmpty else { continue }
            let line = mirror.lines[span.row]
            let first = line.cells.indices.contains(columns.lowerBound) ? line.cells[columns.lowerBound] : Cell.empty
            frame.decorations.append(
                DecorationInstance(
                    cellX: UInt16(clamping: columns.lowerBound), cellY: UInt16(clamping: span.row),
                    cellCount: UInt16(clamping: columns.count), kind: DecorationKind.underline.rawValue,
                    thickness: UInt8(clamping: thickness),
                    top: Int16(clamping: min(cell.underlineTop, cell.height - thickness)),
                    height: Int16(clamping: thickness),
                    color: resolver.resolve(line.style(of: first)).foreground.packed))
        }
    }

    /// Composing text, drawn fresh each frame (it is never cached with the rows): the
    /// default colors, and one underline under all of it.
    private func overlay(
        _ preedit: PreeditLayout, on frame: inout Frame, resolver: ColorResolver, cell: CellMetrics,
        glyphs: any GlyphSource, shelves: inout Set<UInt16>
    ) {
        guard preedit.row >= 0, preedit.row < frame.rows, !preedit.cells.isEmpty else { return }
        let plain = resolver.resolve(.default)
        let cellY = UInt16(clamping: preedit.row)
        for item in preedit.cells {
            let span = item.isWide ? 2 : 1
            guard item.column >= 0, item.column + span <= frame.columns else { continue }
            // What the row drew under the composing text goes — counting the columns each
            // glyph covers, not just the one it starts on. A run that begins to the left of
            // the composing text reaches into it, and filtering by the first column alone
            // would leave its other half painting over what is being typed.
            let covered = item.column..<(item.column + span)
            frame.glyphs.removeAll { glyph in
                guard glyph.cellY == cellY else { return false }
                let start = Int(glyph.cellX)
                return (start..<(start + glyph.cells)).overlaps(covered)
            }
            for column in item.column..<(item.column + span) {
                frame.backgrounds[preedit.row * frame.columns + column] = plain.background.packed
            }
            let key = GlyphKey(scalars: item.scalars, bold: false, italic: false, wide: item.isWide)
            guard let placement = glyphs.placement(for: key) else {
                frame.isComplete = false
                continue
            }
            if !placement.isEmpty {
                frame.glyphs.append(
                    GlyphInstance(
                        cellX: UInt16(clamping: item.column), cellY: cellY, atlasX: placement.x, atlasY: placement.y,
                        width: placement.width, height: placement.height, offsetX: placement.offsetX,
                        offsetY: placement.offsetY, color: plain.foreground.packed,
                        flags: GlyphInstance.flags(atlas: placement.atlas, cells: span)))
                shelves.insert(placement.shelf)
            }
        }
        guard let first = preedit.cells.first, let last = preedit.cells.last else { return }
        let end = last.column + (last.isWide ? 2 : 1)
        frame.decorations.removeAll {
            $0.cellY == cellY && Int($0.cellX) < end && Int($0.cellX + $0.cellCount) > first.column
        }
        let thickness = cell.underlineThickness
        frame.decorations.append(
            DecorationInstance(
                cellX: UInt16(clamping: first.column), cellY: cellY, cellCount: UInt16(clamping: end - first.column),
                kind: DecorationKind.underline.rawValue, thickness: UInt8(clamping: thickness),
                top: Int16(clamping: min(cell.underlineTop, cell.height - thickness)),
                height: Int16(clamping: thickness),
                color: plain.foreground.packed))
    }

    private func buildRow(
        _ row: RowSnapshot, columns: Int, selected: ClosedRange<Int>?, resolver: ColorResolver, cell: CellMetrics,
        glyphs: any GlyphSource, starfield: Bool, shaper: (any RunShaping)? = nil,
        composing: Range<Int>? = nil
    ) -> CachedRow {
        var plain: [ResolvedStyle?] = Array(repeating: nil, count: row.styles.count)
        var highlighted: [ResolvedStyle?] = Array(repeating: nil, count: row.styles.count)
        func style(_ id: Int, selected: Bool) -> ResolvedStyle {
            if selected {
                if let style = highlighted[id] { return style }
                let style = resolver.resolve(row.styles[id], selected: true)
                highlighted[id] = style
                return style
            }
            if let style = plain[id] { return style }
            let style = resolver.resolve(row.styles[id])
            plain[id] = style
            return style
        }

        var out = CachedRow(
            version: row.version, selection: selected, preedit: composing, backgrounds: [], glyphs: [],
            decorations: [], shelves: [], complete: true)
        out.backgrounds.reserveCapacity(columns)
        var shelves = Set<UInt16>()
        var decorations = DecorationRuns(cell: cell)
        let clear = resolver.clearColor.packed
        /// The last column with anything on it: a glyph, a line, a background of its own.
        var lastInk = -1

        // Scanned here rather than in `build`, because `buildRow` runs only for rows that are
        // dirty: scanning in `build` would walk every row on screen every frame and quietly
        // undo the row cache.
        let runs: [GlyphRun] =
            shaper.map {
                RunScanner(cell: cell).runs(
                    in: row, columns: columns, selected: selected,
                    face: { x in
                        let id = Int(row.cells[x].styleID) < row.styles.count ? Int(row.cells[x].styleID) : 0
                        let resolved = style(id, selected: selected?.contains(x) ?? false)
                        return (resolved.bold, resolved.italic)
                    }, shaper: $0
                )
                .filter { composing == nil || !($0.column..<($0.column + $0.cells)).overlaps(composing!) }
            } ?? []
        func emit(_ placement: GlyphPlacement, at x: Int, cells: Int, _ resolved: ResolvedStyle) {
            out.glyphs.append(
                GlyphInstance(
                    cellX: UInt16(clamping: x), cellY: 0, atlasX: placement.x, atlasY: placement.y,
                    width: placement.width, height: placement.height, offsetX: placement.offsetX,
                    offsetY: placement.offsetY, color: resolved.foreground.packed,
                    flags: GlyphInstance.flags(atlas: placement.atlas, cells: cells)))
            shelves.insert(placement.shelf)
        }
        var nextRun = runs.startIndex
        // The last column of a run already drawn, so its other columns emit no glyph of their
        // own; -1 while there is none.
        var runEnd = -1

        for x in 0..<columns {
            guard x < row.cells.count else {
                out.backgrounds.append(clear)
                continue
            }
            let cellValue = row.cells[x]
            let styleID = Int(cellValue.styleID) < row.styles.count ? Int(cellValue.styleID) : 0
            let isSelected = selected?.contains(x) ?? false
            let resolved = style(styleID, selected: isSelected)
            out.backgrounds.append(resolved.background.packed)
            if resolved.background.packed != clear { lastInk = x }
            guard cellValue.width != .spacerTail, cellValue.width != .spacerHead else { continue }

            if !resolved.invisible {
                while nextRun < runs.endIndex, runs[nextRun].column < x { nextRun += 1 }
                // A column a run already covers: its background is appended above, as every
                // column's is, and the run's one instance has already been emitted.
                if x <= runEnd { continue }
                var span = cellValue.width == .wide ? 2 : 1
                // A run is taken only if the atlas actually has a bitmap for it. An empty
                // placement for a run means the rasterizer refused it — its bitmap is wider
                // than it will draw — and since the alphabet is visible punctuation, empty is
                // unambiguously a failure there rather than a space. Falling back to the cells
                // one at a time keeps the characters on screen instead of blanking them for as
                // long as the atlas holds that answer.
                var run: GlyphRun?
                if nextRun < runs.endIndex, runs[nextRun].column == x {
                    let candidate = runs[nextRun]
                    nextRun += 1
                    let key = GlyphKey(run: candidate.scalars, bold: resolved.bold, italic: resolved.italic)
                    if let placement = glyphs.placement(for: key) {
                        if !placement.isEmpty {
                            run = candidate
                            span = candidate.cells
                            runEnd = x + candidate.cells - 1
                            emit(placement, at: x, cells: candidate.cells, resolved)
                        }
                    } else {
                        // Nil is the other answer, and it means something else entirely: not
                        // refused but *not ready yet*, so the row has to be asked again. The
                        // cells below still draw this frame, which is why forgetting this is
                        // invisible — the characters are all on screen, the row is cached as
                        // the whole answer, and the ligature never appears for as long as that
                        // row lives.
                        out.complete = false
                    }
                }
                decorations.add(resolved, column: x, cells: span)
                if resolved.underline != .none || resolved.strikethrough || resolved.overline {
                    lastInk = max(lastInk, x + span - 1)
                }
                if run != nil {
                    lastInk = max(lastInk, x + span - 1)
                    continue
                }
                let scalars = row.scalars(at: x)
                if !scalars.isEmpty && !(scalars.count == 1 && scalars[0] == 0x20) {
                    lastInk = max(lastInk, x + span - 1)
                    let key = GlyphKey(
                        scalars: scalars, bold: resolved.bold, italic: resolved.italic,
                        wide: cellValue.width == .wide)
                    if let placement = glyphs.placement(for: key) {
                        if !placement.isEmpty { emit(placement, at: x, cells: span, resolved) }
                    } else {
                        out.complete = false
                    }
                }
            } else {
                decorations.breakRuns()
            }
        }
        out.decorations = decorations.finish()
        out.shelves = Array(shelves)
        // Past the last ink, the row's plain background may hold a star: never under text,
        // so a star cannot pass for punctuation.
        if starfield, lastInk + 1 < columns {
            let starry = (clear & 0x00FF_FFFF) | (Self.starryAlpha << 24)
            for x in (lastInk + 1)..<columns where out.backgrounds[x] == clear {
                out.backgrounds[x] = starry
            }
        }
        return out
    }
}

/// Collects decorations into runs: neighbouring cells with the same line in the same color
/// make one instance.
private struct DecorationRuns {
    let cell: CellMetrics
    var done: [DecorationInstance] = []
    var open: [DecorationKind: DecorationInstance] = [:]

    init(cell: CellMetrics) {
        self.cell = cell
    }

    mutating func add(_ style: ResolvedStyle, column: Int, cells: Int) {
        var wanted: [DecorationKind: PackedColor] = [:]
        switch style.underline {
        case .none: break
        case .single: wanted[.underline] = style.underlineColor.packed
        case .double: wanted[.doubleUnderline] = style.underlineColor.packed
        case .curly: wanted[.curlyUnderline] = style.underlineColor.packed
        case .dotted: wanted[.dottedUnderline] = style.underlineColor.packed
        case .dashed: wanted[.dashedUnderline] = style.underlineColor.packed
        }
        if style.strikethrough { wanted[.strikethrough] = style.foreground.packed }
        if style.overline { wanted[.overline] = style.foreground.packed }

        for (kind, run) in open where wanted[kind] != run.color || Int(run.cellX) + Int(run.cellCount) != column {
            done.append(run)
            open[kind] = nil
        }
        for (kind, color) in wanted {
            if var run = open[kind] {
                run.cellCount += UInt16(cells)
                open[kind] = run
            } else {
                open[kind] = instance(kind, color: color, column: column, cells: cells)
            }
        }
    }

    /// A cell that draws no lines ends every run.
    mutating func breakRuns() {
        done += open.values
        open.removeAll()
    }

    mutating func finish() -> [DecorationInstance] {
        breakRuns()
        return done.sorted { ($0.cellX, $0.kind) < ($1.cellX, $1.kind) }
    }

    private func instance(_ kind: DecorationKind, color: PackedColor, column: Int, cells: Int) -> DecorationInstance {
        let thickness = cell.underlineThickness
        var top: Int
        var height: Int
        switch kind {
        case .underline:
            (top, height) = (cell.underlineTop, thickness)
        case .doubleUnderline:
            height = 3 * thickness
            top = cell.underlineTop
        case .curlyUnderline:
            height = 4 * thickness
            top = cell.underlineTop - thickness
        case .dottedUnderline, .dashedUnderline:
            (top, height) = (cell.underlineTop, thickness)
        case .strikethrough:
            (top, height) = (cell.strikethroughTop, cell.strikethroughThickness)
        case .overline:
            (top, height) = (0, thickness)
        case .rail:
            // Not reached: a rail is a block's, appended whole by `chrome`, and no style
            // produces one. The arm is here so this switch stays exhaustive and checked — one
            // cell's worth is the right answer if a rail ever did arrive as a run.
            (top, height) = (0, cell.height)
        }
        // Keep the box inside the cell.
        height = min(height, cell.height)
        top = min(max(top, 0), cell.height - height)
        return DecorationInstance(
            cellX: UInt16(clamping: column), cellY: 0, cellCount: UInt16(clamping: cells), kind: kind.rawValue,
            thickness: UInt8(clamping: thickness), top: Int16(clamping: top), height: Int16(clamping: height),
            color: color)
    }
}
