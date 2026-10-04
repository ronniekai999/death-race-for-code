/// A font's measurements in points, as CoreText reports them. RenderKit reads them from the
/// font; everything computed from them lives here, where it is tested on Linux.
public struct FontMeasurements: Sendable, Equatable {
    /// The widest advance among the printable ASCII characters; a monospaced font's advance.
    public var advance: Double
    public var ascent: Double
    /// Below the baseline, as a positive distance.
    public var descent: Double
    public var leading: Double
    /// The top of the underline relative to the baseline; negative is below it.
    public var underlinePosition: Double
    public var underlineThickness: Double
    /// The height of lowercase letters, where strikethrough goes.
    public var xHeight: Double

    public init(
        advance: Double, ascent: Double, descent: Double, leading: Double, underlinePosition: Double,
        underlineThickness: Double, xHeight: Double
    ) {
        self.advance = advance
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
        self.underlinePosition = underlinePosition
        self.underlineThickness = underlineThickness
        self.xHeight = xHeight
    }
}

/// The terminal grid's cell, in device pixels. Every glyph, line and cursor snaps to it, so
/// box drawing joins across rows and nothing blurs between pixels.
///
/// Positions count down from the top of the cell.
public struct CellMetrics: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// Where glyphs sit.
    public var baseline: Int
    public var underlineTop: Int
    public var underlineThickness: Int
    public var strikethroughTop: Int
    public var strikethroughThickness: Int
    /// Device pixels per point.
    public var scale: Double

    public init(
        width: Int, height: Int, baseline: Int, underlineTop: Int, underlineThickness: Int, strikethroughTop: Int,
        strikethroughThickness: Int, scale: Double
    ) {
        self.width = width
        self.height = height
        self.baseline = baseline
        self.underlineTop = underlineTop
        self.underlineThickness = underlineThickness
        self.strikethroughTop = strikethroughTop
        self.strikethroughThickness = strikethroughThickness
        self.scale = scale
    }

    /// The cell for a font at a backing scale (2 on Retina displays).
    ///
    /// The width rounds the advance to whole pixels: glyph shapes are narrower than their
    /// advance, so losing a fraction of a pixel never clips them, while rounding up would
    /// spread text apart. The height rounds the line (ascent, descent and leading) up, so
    /// nothing is clipped vertically, and the baseline sits where the font puts it with the
    /// spare pixels split above and below.
    public init(_ font: FontMeasurements, scale: Double) {
        let scale = scale > 0 ? scale : 1
        let width = max(1, Int((font.advance * scale).rounded()))
        let line = (font.ascent + font.descent + font.leading) * scale
        let height = max(1, Int(line.rounded(.up)))
        let spare = Double(height) - (font.ascent + font.descent) * scale
        let baseline = min(height - 1, max(0, Int((spare / 2 + font.ascent * scale).rounded())))

        let thickness = max(1, Int((font.underlineThickness * scale).rounded()))
        let belowBaseline = max(1, Int((-font.underlinePosition * scale).rounded()))
        let underlineTop = min(height - thickness, baseline + belowBaseline)

        let halfXHeight = Int((font.xHeight * scale / 2).rounded())
        let strikethroughTop = max(0, baseline - halfXHeight - thickness / 2)

        self.init(
            width: width, height: height, baseline: baseline, underlineTop: max(0, underlineTop),
            underlineThickness: thickness, strikethroughTop: strikethroughTop, strikethroughThickness: thickness,
            scale: scale)
    }

    /// The cell in points.
    public var pointWidth: Double { Double(width) / scale }
    public var pointHeight: Double { Double(height) / scale }
}

/// Where the grid sits in a view: its size in cells and its padding, in points.
public struct GridLayout: Sendable, Equatable {
    public var columns: Int
    public var rows: Int
    /// From the view's edges to the grid, in points: at least the configured padding, plus
    /// what is left over from a view that is not a whole number of cells.
    public var left: Double
    public var top: Double

    public init(columns: Int, rows: Int, left: Double, top: Double) {
        self.columns = columns
        self.rows = rows
        self.left = left
        self.top = top
    }

    /// How many cells fit in a view of `width` × `height` points with `padding` on each side,
    /// at least 1 × 1. The grid keeps the configured padding on the left and top; any space
    /// left over goes on the right and bottom.
    public init(width: Double, height: Double, cell: CellMetrics, paddingX: Double, paddingY: Double) {
        let usableWidth = max(0, width - 2 * paddingX)
        let usableHeight = max(0, height - 2 * paddingY)
        self.init(
            columns: max(1, Int(usableWidth / cell.pointWidth)), rows: max(1, Int(usableHeight / cell.pointHeight)),
            left: paddingX, top: paddingY)
    }

    /// The view size, in points, that holds `columns` × `rows` cells with `padding` on
    /// each side.
    public static func viewSize(
        columns: Int, rows: Int, cell: CellMetrics, paddingX: Double, paddingY: Double
    ) -> (width: Double, height: Double) {
        (Double(columns) * cell.pointWidth + 2 * paddingX, Double(rows) * cell.pointHeight + 2 * paddingY)
    }
}
