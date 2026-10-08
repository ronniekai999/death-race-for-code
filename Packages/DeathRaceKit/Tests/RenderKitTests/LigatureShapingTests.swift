import CoreText
import ScreenProtocol
import SurfaceCore
import Testing

@testable import RenderKit

/// What only a Mac can judge: whether the font actually draws a run differently, and whether
/// the bitmap it produces stays inside the columns the frame reserved for it.
///
/// The Linux tests prove where a run could be and what the frame does with one. They cannot
/// prove that CoreText applies the features, because there is no CoreText — and the whole
/// feature is inert if it does not. So every assertion here is about a real font's real output.
@MainActor
@Suite struct LigatureShapingTests {
    func neon() -> FontSet {
        FontRegistry.registerBundledFonts()
        return FontSet(family: "Monaspace Neon", size: 13, italicFamily: "Monaspace Radon")
    }

    func rasterizer(_ fonts: FontSet) -> GlyphRasterizer {
        GlyphRasterizer(fonts: fonts, cell: fonts.cellMetrics(scale: 2), language: "en")
    }

    func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }

    @Test(.enabled(if: bundledFontsFetched, "run scripts/fetch-fonts.sh first"))
    func monaspaceDrawsTheOperatorsAsOne() {
        let shaper = RunShaper(rasterizer(neon()))
        // Read out of the font's own GSUB before this was written: `!=` and `===` come from
        // ss01, `<=` from ss02, `->` from ss03, `|>` from ss05, `::` from ss07, `=>` from ss09,
        // `//` from liga. If any of these is false, the feature list is the thing that is wrong.
        for text in ["!=", "===", "<=", "->", "|>", "::", "=>", "//", "<!--"] {
            #expect(shaper.shapesAsOne(scalars(text), bold: false, italic: false), "\(text)")
        }
    }

    @Test(.enabled(if: bundledFontsFetched, "run scripts/fetch-fonts.sh first"))
    func aSequenceTheFontLeavesAloneIsNotARun() {
        let shaper = RunShaper(rasterizer(neon()))
        // Monaspace ligates a great deal, and not these: measured, not guessed. Without a
        // negative the suite above would pass for a shaper that answered yes to everything.
        for text in ["/*", "*/", "#!", "$$", "@@"] {
            #expect(!shaper.shapesAsOne(scalars(text), bold: false, italic: false), "\(text)")
        }
    }

    @Test(.enabled(if: bundledFontsFetched, "run scripts/fetch-fonts.sh first"))
    func bothItalicFacesAnswerForThemselves() {
        let shaper = RunShaper(rasterizer(neon()))
        // The italic of this pairing is Radon, a different family; the bold is Neon's own. A
        // run carries one style, so each face is asked separately and each must answer.
        for (bold, italic) in [(true, false), (false, true), (true, true)] {
            #expect(shaper.shapesAsOne(scalars("!="), bold: bold, italic: italic), "\(bold) \(italic)")
        }
    }

    @Test func sfMonoHasNoLigaturesAndSaysSo() {
        let shaper = RunShaper(rasterizer(FontSet(family: "SF Mono", size: 13)))
        // The default font, and the reason the setting's help says what it does: with no
        // ligatures in the face, every run is refused and the frame is what it always was.
        for text in ["!=", "=>", "->", "===", "::"] {
            #expect(!shaper.shapesAsOne(scalars(text), bold: false, italic: false), "\(text)")
        }
    }

    @Test func aSingleCharacterIsNeverARun() {
        let shaper = RunShaper(rasterizer(FontSet(family: "SF Mono", size: 13)))
        #expect(!shaper.shapesAsOne([0x3D], bold: false, italic: false))
        #expect(!shaper.shapesAsOne([], bold: false, italic: false))
    }

    /// The assertion the rest of this change rests on: the features reach the *bitmap*, not
    /// just the oracle. Both keys hold the same two characters; only one of them is a run, and
    /// only a run is shaped with the ligature features. Identical bitmaps would mean the
    /// oracle is answering yes about a line the rasterizer never draws.
    @Test(.enabled(if: bundledFontsFetched, "run scripts/fetch-fonts.sh first"))
    func theFeaturesReachTheBitmapAndNotJustTheAnswer() {
        let raster = rasterizer(neon())
        let characters = scalars("!=")
        let run = raster.rasterize(GlyphKey(run: characters, bold: false, italic: false))
        let plain = raster.rasterize(GlyphKey(scalars: characters, bold: false, italic: false, wide: false))
        #expect(!run.isEmpty)
        #expect(!plain.isEmpty)
        #expect(
            run.width != plain.width || run.offsetX != plain.offsetX || run.pixels != plain.pixels,
            "the run and the unshaped pair came out identical: the features did not reach the line")
    }

    /// A run keeps the font's own advance, and nothing downstream stretches or shrinks it — the
    /// shrink-to-fit in `drawText` is for colour and double-width glyphs only. So the bitmap has
    /// to stay inside the columns the frame gave it, and this is where that is found out.
    @Test(.enabled(if: bundledFontsFetched, "run scripts/fetch-fonts.sh first"))
    func aRunsBitmapStaysInsideItsColumns() {
        let fonts = neon()
        let cell = fonts.cellMetrics(scale: 2)
        let raster = rasterizer(fonts)
        for text in ["!=", "===", "<!--"] {
            let cells = text.unicodeScalars.count
            let glyph = raster.rasterize(GlyphKey(run: scalars(text), bold: false, italic: false))
            #expect(!glyph.isEmpty, "\(text)")
            // A pixel of room for antialiasing on each side, and whole-pixel rounding outwards.
            #expect(glyph.width <= cells * cell.width + 4, "\(text): \(glyph.width) over \(cells) columns")
            #expect(glyph.offsetX >= -2, "\(text): starts \(glyph.offsetX) left of its first column")
            #expect(glyph.height <= cell.height + 4, "\(text)")
            // Wider than one column: a run that drew in a single cell would not be a ligature.
            #expect(glyph.width > cell.width, "\(text)")
        }
    }

    @Test(.enabled(if: bundledFontsFetched, "run scripts/fetch-fonts.sh first"))
    func theMemoAsksTheFontOnceForEachRun() {
        let memo = MemoizedRunShaping(RunShaper(rasterizer(neon())))
        #expect(memo.shapesAsOne(scalars("!="), bold: false, italic: false))
        #expect(memo.shapesAsOne(scalars("!="), bold: false, italic: false))
        #expect(!memo.shapesAsOne(scalars("/*"), bold: false, italic: false))
        #expect(memo.count == 2, "one answer per distinct run, kept whichever way it went")
    }
}
