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
    /// Bit 0: the glyph is in the color atlas.
    public var flags: UInt32

    public static let colorAtlasFlag: UInt32 = 1
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
    }

    /// The alpha byte that marks a background as starry: a row's empty end, where the
    /// background shader may draw a faint star. Everything else is opaque (0xFF).
    public static let starryAlpha: UInt32 = 0xFE

    private struct CachedRow {
        var version: UInt64
        var selection: ClosedRange<Int>?
        var backgrounds: [PackedColor]
        var glyphs: [GlyphInstance]
        var decorations: [DecorationInstance]
        var shelves: [UInt16]
        var complete: Bool
    }

    private var inputs: Inputs?
    private var cache: [UInt64: CachedRow] = [:]
    /// Rows rebuilt by the last `build`, for tests and measurement.
    public private(set) var rebuiltRows = 0

    public init() {}

    /// The frame for `mirror` drawn with `theme` at `cell`, with `selection` highlighted and
    /// an input method's composing text (`preedit`) drawn over the cells it covers, underlined.
    /// With `starfield`, each row's empty end is marked for the shader's stars.
    public func build(
        mirror: MirrorGrid, theme: Theme, cell: CellMetrics, selection: TextRegion?, glyphs: any GlyphSource,
        preedit: PreeditLayout? = nil, starfield: Bool = false
    ) -> Frame {
        let current = Inputs(
            palette: mirror.palette, theme: theme, reverseVideo: mirror.modes.reverseVideo, cell: cell,
            epoch: glyphs.epoch, starfield: starfield)
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
            var cached = cache[row.id]
            if cached == nil || cached!.version != row.version || cached!.selection != selected || !cached!.complete {
                cached = buildRow(
                    row, columns: columns, selected: selected, resolver: resolver, cell: cell, glyphs: glyphs,
                    starfield: starfield)
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
        if let preedit {
            overlay(preedit, on: &frame, resolver: resolver, cell: cell, glyphs: glyphs, shelves: &shelves)
        }
        glyphs.markUsed(shelves: Array(shelves))
        return frame
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
            // What the row drew under the composing text goes.
            frame.glyphs.removeAll { $0.cellY == cellY && (item.column..<(item.column + span)).contains(Int($0.cellX)) }
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
                        flags: placement.atlas == .color ? GlyphInstance.colorAtlasFlag : 0))
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
        glyphs: any GlyphSource, starfield: Bool
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
            version: row.version, selection: selected, backgrounds: [], glyphs: [], decorations: [], shelves: [],
            complete: true)
        out.backgrounds.reserveCapacity(columns)
        var shelves = Set<UInt16>()
        var decorations = DecorationRuns(cell: cell)
        let clear = resolver.clearColor.packed
        /// The last column with anything on it: a glyph, a line, a background of its own.
        var lastInk = -1

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
                let span = cellValue.width == .wide ? 2 : 1
                decorations.add(resolved, column: x, cells: span)
                if resolved.underline != .none || resolved.strikethrough || resolved.overline {
                    lastInk = max(lastInk, x + span - 1)
                }
                let scalars = row.scalars(at: x)
                if !scalars.isEmpty && !(scalars.count == 1 && scalars[0] == 0x20) {
                    lastInk = max(lastInk, x + span - 1)
                    let key = GlyphKey(
                        scalars: scalars, bold: resolved.bold, italic: resolved.italic, wide: cellValue.width == .wide)
                    if let placement = glyphs.placement(for: key) {
                        if !placement.isEmpty {
                            out.glyphs.append(
                                GlyphInstance(
                                    cellX: UInt16(clamping: x), cellY: 0, atlasX: placement.x, atlasY: placement.y,
                                    width: placement.width, height: placement.height, offsetX: placement.offsetX,
                                    offsetY: placement.offsetY, color: resolved.foreground.packed,
                                    flags: placement.atlas == .color ? GlyphInstance.colorAtlasFlag : 0))
                            shelves.insert(placement.shelf)
                        }
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
