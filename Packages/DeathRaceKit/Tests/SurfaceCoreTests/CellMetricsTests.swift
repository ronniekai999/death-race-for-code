import Testing

@testable import SurfaceCore

@Suite struct CellMetricsTests {
    /// SF Mono at 13 points, as CoreText measures it (units per em 2048: ascender 1950,
    /// descender 494, no line gap, advance 1266, underline -150 thick 100, x-height 1100).
    static let sfMono13 = FontMeasurements(
        advance: 13 * 1266 / 2048, ascent: 13 * 1950 / 2048, descent: 13 * 494 / 2048, leading: 0,
        underlinePosition: 13 * -150 / 2048, underlineThickness: 13 * 100 / 2048, xHeight: 13 * 1100 / 2048)

    @Test func retinaCellForSFMono() {
        let cell = CellMetrics(Self.sfMono13, scale: 2)
        // advance 8.04 pt → 16 px; line 15.51 pt → 31.03 px, rounded up to 32.
        #expect(cell.width == 16)
        #expect(cell.height == 32)
        // ascent 24.76 px plus half the spare 0.97 px.
        #expect(cell.baseline == 25)
        #expect(cell.underlineThickness == 1)
        #expect(cell.underlineTop == 27)
        #expect(cell.strikethroughTop == 18)
        #expect(cell.pointWidth == 8)
        #expect(cell.pointHeight == 16)
    }

    @Test func standardResolutionCell() {
        let cell = CellMetrics(Self.sfMono13, scale: 1)
        #expect(cell.width == 8)
        #expect(cell.height == 16)
        #expect(cell.baseline == 13)
        #expect(cell.underlineTop == 14)
    }

    @Test func everythingStaysInsideTheCell() {
        for size in stride(from: 6.0, through: 144, by: 0.5) {
            for scale in [1.0, 1.5, 2, 3] {
                var font = Self.sfMono13
                let factor = size / 13
                font.advance *= factor
                font.ascent *= factor
                font.descent *= factor
                font.underlinePosition *= factor
                font.underlineThickness *= factor
                font.xHeight *= factor
                let cell = CellMetrics(font, scale: scale)
                #expect(cell.width >= 1 && cell.height >= 1)
                #expect(cell.baseline >= 0 && cell.baseline < cell.height)
                #expect(cell.underlineTop >= 0 && cell.underlineTop + cell.underlineThickness <= cell.height)
                #expect(cell.strikethroughTop >= 0 && cell.strikethroughTop < cell.baseline)
            }
        }
    }

    /// A font with a huge underline offset or a degenerate scale cannot push lines out.
    @Test func oddFontsAreClamped() {
        let odd = FontMeasurements(
            advance: 0.1, ascent: 10, descent: 2, leading: 1, underlinePosition: -40, underlineThickness: 0.1,
            xHeight: 30)
        let cell = CellMetrics(odd, scale: 0)
        #expect(cell.scale == 1)
        #expect(cell.width == 1)
        #expect(cell.height == 13)
        #expect(cell.underlineTop == cell.height - cell.underlineThickness)
        #expect(cell.strikethroughTop == 0)
    }

    @Test func gridLayoutFitsWholeCells() {
        let cell = CellMetrics(Self.sfMono13, scale: 2)
        let size = GridLayout.viewSize(columns: 100, rows: 30, cell: cell, paddingX: 8, paddingY: 6)
        #expect(size.width == 816)
        #expect(size.height == 492)
        let layout = GridLayout(width: size.width, height: size.height, cell: cell, paddingX: 8, paddingY: 6)
        #expect(layout == GridLayout(columns: 100, rows: 30, left: 8, top: 6))
        // A little short of a cell loses it; a sliver of a view keeps one cell.
        #expect(GridLayout(width: 815, height: 491, cell: cell, paddingX: 8, paddingY: 6).columns == 99)
        #expect(GridLayout(width: 815, height: 491, cell: cell, paddingX: 8, paddingY: 6).rows == 29)
        #expect(GridLayout(width: 3, height: 3, cell: cell, paddingX: 8, paddingY: 6).columns == 1)
        #expect(GridLayout(width: 3, height: 3, cell: cell, paddingX: 8, paddingY: 6).rows == 1)
    }
}
