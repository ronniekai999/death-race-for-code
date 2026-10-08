import CoreGraphics
import CoreText
import Foundation
import SurfaceCore

/// Draws glyphs with CoreText, one at a time, at the cell's pixel size.
///
/// - Text is laid out as a CTLine, so CoreText shapes clusters (combining marks, emoji
///   sequences) and falls back to other fonts for characters the font lacks, preferring the
///   ones for the user's language (Japanese and Chinese draw Han characters differently).
/// - Coverage is drawn white on black in a gray bitmap: no font smoothing unless
///   `thicken`, which makes strokes heavier.
/// - Color glyphs (emoji) are drawn in color, scaled down to fit their cells; wide glyphs
///   too. Other glyphs keep their size and may overhang their cell, as in other terminals.
/// - Box drawing and block elements come from `SpriteRasterizer`, at exactly the cell size.
public struct GlyphRasterizer: GlyphRasterizing, Sendable {
    public let fonts: FontSet
    public let cell: CellMetrics
    public let thicken: Bool
    let language: String?
    /// The four faces with the run features on, in `FontSet.face(bold:italic:)`'s order.
    ///
    /// Built once here rather than per question. The scanner asks about every candidate in
    /// every row it rebuilds, and each question used to make a feature-settings array, a font
    /// descriptor and a font copy — thousands of them in one frame on a screen of punctuation,
    /// all recomputing four values that depend on nothing but the faces.
    private let runFaces: [CTFont]

    public init(fonts: FontSet, cell: CellMetrics, thicken: Bool = false, language: String? = nil) {
        self.fonts = fonts
        self.cell = cell
        self.thicken = thicken
        self.language = language ?? Locale.preferredLanguages.first
        runFaces = [
            Self.shaping(fonts.regular), Self.shaping(fonts.bold), Self.shaping(fonts.italic),
            Self.shaping(fonts.boldItalic),
        ]
    }

    /// The run-shaping face for a style, in the same order `FontSet.face(bold:italic:)` uses.
    ///
    /// A run is never a private-use character, so unlike `face(for:)` this needs no symbols
    /// font: the alphabet is punctuation, which every monospaced face has.
    func runFace(bold: Bool, italic: Bool) -> CTFont {
        runFaces[(bold ? 1 : 0) + (italic ? 2 : 0)]
    }

    public func rasterize(_ key: GlyphKey) -> RasterizedGlyph {
        let scalars = key.scalars
        if scalars.count == 1, SpriteRasterizer.handles(scalars[0]),
            let pixels = SpriteRasterizer.rasterize(scalars[0], width: cell.width, height: cell.height)
        {
            return RasterizedGlyph(
                atlas: .mask, width: cell.width, height: cell.height, offsetX: 0, offsetY: 0, pixels: pixels)
        }
        return drawText(key)
    }

    /// The font a glyph is drawn from before CoreText's own fallbacks: the style's face, or
    /// for private-use characters (a prompt's icons) Symbols Nerd Font Mono when it has them.
    /// The faces' fallback lists also put it first, but CoreText does not apply such a list
    /// to the system's own monospaced font, SF Mono.
    public func face(for key: GlyphKey) -> CTFont {
        let face = fonts.face(bold: key.bold, italic: key.italic)
        let scalars = key.scalars
        guard let symbols = fonts.symbols, !scalars.isEmpty, scalars.allSatisfy(Self.isPrivateUse) else { return face }
        var characters: [UniChar] = []
        for scalar in scalars {
            guard let value = Unicode.Scalar(scalar) else { return face }
            characters.append(contentsOf: Character(value).utf16)
        }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(symbols, characters, &glyphs, characters.count) ? symbols : face
    }

    /// The Private Use Areas, where icon fonts put their icons.
    static func isPrivateUse(_ scalar: UInt32) -> Bool {
        (0xE000...0xF8FF).contains(scalar) || (0xF_0000...0xF_FFFD).contains(scalar)
            || (0x10_0000...0x10_FFFD).contains(scalar)
    }

    /// The OpenType features a run is shaped with — and only a run.
    ///
    /// Read from the bundled fonts' own `GSUB` tables rather than from anyone's documentation,
    /// by applying each feature's lookups to every pair and triple of the run alphabet. In
    /// Monaspace Neon and Radon: `calt` draws 36 punctuation pairs differently and ligates
    /// none of them — that is texture healing — `liga` ligates four (`!!`, `!=`, `//`, `||`),
    /// and every operator anyone would name is in a stylistic set instead, one family each:
    /// `!= ===` in `ss01`, `<= >=` in `ss02`, `-> <- -->` in `ss03`, `</ />` in `ss04`, `|>`
    /// in `ss05`, `&& ++` in `ss06`, `::` in `ss07`, `...` in `ss08`, `=> << >>` in `ss09`.
    /// `ss10` changes nothing in this alphabet, so it is not here.
    ///
    /// Two consequences worth stating. `liga` and `calt` alone would leave the font this app
    /// bundles and offers by name looking as though the setting did nothing — which is the
    /// mistake this list exists to avoid. And `calt` is here all the same, because fonts like
    /// Fira Code put every ligature they have in it and no stylistic set at all.
    static let runFeatures = [
        "liga", "calt", "ss01", "ss02", "ss03", "ss04", "ss05", "ss06", "ss07", "ss08", "ss09",
    ]

    /// The descriptor that turns the run features on: the same every time, so made once.
    private static let runDescriptor: CTFontDescriptor = {
        let settings: [[String: Any]] = runFeatures.map {
            [kCTFontOpenTypeFeatureTag as String: $0, kCTFontOpenTypeFeatureValue as String: 1]
        }
        return CTFontDescriptorCreateWithAttributes(
            [kCTFontFeatureSettingsAttribute: settings] as CFDictionary)
    }()

    /// `font` with the run features on. Size 0 and no matrix keep the font's own, as the
    /// cascade-list copy in `FontSet` does, so a face slanted into an italic stays slanted.
    static func shaping(_ font: CTFont) -> CTFont {
        CTFontCreateCopyWithAttributes(font, 0, nil, runDescriptor)
    }

    /// The shaped line for a key.
    ///
    /// The one place an attributed string is built, so that "does this face draw these
    /// characters differently as a unit" and the bitmap that answer leads to are asked of the
    /// same line. Two of them could differ by one attribute and the result would be text that
    /// looks unligated while being spaced as though it were — with nothing failing anywhere,
    /// on any platform that can run the tests.
    func line(for key: GlyphKey) -> CTLine? {
        let font = key.isRun ? runFace(bold: key.bold, italic: key.italic) : face(for: key)
        var attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: true,
        ]
        if let language { attributes[kCTLanguageAttributeName] = language as CFString }
        guard
            let attributed = CFAttributedStringCreate(
                kCFAllocatorDefault, key.string as CFString, attributes as CFDictionary)
        else { return nil }
        return CTLineCreateWithAttributedString(attributed)
    }

    /// Whether this face draws these characters differently as a unit, with every one of them
    /// still exactly one cell wide.
    ///
    /// **Not fewer glyphs than characters**, which is the obvious test and the wrong one. Every
    /// ligature in both bundled families is N glyphs in and N glyphs *out* — the font keeps one
    /// glyph per column precisely so the advance stays monospaced, and puts the connected shape
    /// across them. Measured, not assumed: of 2,128 punctuation sequences, 1,096 shape
    /// differently and **not one** changes its glyph count. A count test would have answered
    /// "no" to every ligature this app ships with, and only a Mac would ever have said so.
    ///
    /// Comparing the glyphs instead costs nothing and covers both styles: a font that really
    /// does substitute N glyphs for one answers yes here too, since one glyph is not the N it
    /// started with, and the advance check below is what makes that safe to draw.
    ///
    /// The advance is checked rather than trusted because nothing downstream can save us from a
    /// font that does not keep it: the shrink-to-fit in `drawText` is for colour and
    /// double-width glyphs, a run is neither, and so a run's bitmap is drawn at the font's own
    /// advance and would simply lie across the cells beside it.
    public func shapesAsOne(_ scalars: [UInt32], bold: Bool, italic: Bool) -> Bool {
        guard scalars.count >= 2 else { return false }
        let key = GlyphKey(run: scalars, bold: bold, italic: italic)
        let plain = face(for: key)
        var characters: [UniChar] = []
        for scalar in scalars {
            guard let value = Unicode.Scalar(scalar), value.value < 0x1_0000 else { return false }
            characters.append(UniChar(value.value))
        }
        // The glyphs these characters have on their own, in this face. False here means the
        // face is missing one of them, so the line would be drawn by a fallback font.
        var alone = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(plain, characters, &alone, characters.count) else { return false }
        guard let line = line(for: key), let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return false }
        let name = CTFontCopyPostScriptName(plain) as String
        var shaped: [CGGlyph] = []
        for run in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName as String] else { return false }
            // A run CoreText drew from another font is a fallback rather than a ligature, and
            // its glyph numbers are another font's: they mean nothing beside ours.
            guard CTFontCopyPostScriptName(value as! CTFont) as String == name else { return false }
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            shaped.append(contentsOf: glyphs)
        }
        guard shaped != alone else { return false }
        var advances = [CGSize](repeating: .zero, count: alone.count)
        let apart = CTFontGetAdvancesForGlyphs(plain, .horizontal, alone, &advances, alone.count)
        let together = CTLineGetTypographicBounds(line, nil, nil, nil)
        return apart > 0 && abs(together - apart) < 0.5
    }

    private func drawText(_ key: GlyphKey) -> RasterizedGlyph {
        guard let line = line(for: key) else { return .empty }
        let isColor = Self.usesColorFont(line)

        let scale = CGFloat(cell.scale)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard !bounds.isNull, !bounds.isEmpty, bounds.width.isFinite, bounds.height.isFinite else { return .empty }

        // Emoji and wide glyphs shrink to fit their cells; the rest keep their size.
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let boxWidth = CGFloat(cell.width * key.cells)
        let boxHeight = CGFloat(cell.height)
        var fit: CGFloat = 1
        if isColor || key.isWide {
            if advance * scale > boxWidth { fit = min(fit, boxWidth / (advance * scale)) }
            if isColor, (ascent + descent) * scale > boxHeight {
                fit = min(fit, boxHeight / ((ascent + descent) * scale))
            }
        }
        let drawScale = scale * fit
        // A shrunk glyph is centred in its box; a color glyph also vertically, on its own
        // ascent and descent.
        let shiftX = fit < 1 ? (boxWidth - advance * drawScale) / 2 : 0
        var shiftY: CGFloat = 0
        if isColor {
            let glyphHeight = (ascent + descent) * drawScale
            let baselineFromTop = (boxHeight - glyphHeight) / 2 + ascent * drawScale
            shiftY = CGFloat(cell.baseline) - baselineFromTop
        }

        // The bitmap: the glyph's pixel bounds, plus a pixel of room for antialiasing.
        let pixelBounds = CGRect(
            x: bounds.minX * drawScale + shiftX, y: bounds.minY * drawScale + shiftY,
            width: bounds.width * drawScale, height: bounds.height * drawScale
        ).integral.insetBy(dx: -1, dy: -1)
        let width = Int(pixelBounds.width)
        let height = Int(pixelBounds.height)
        let bound = GlyphKey.maxRunPixels
        guard width > 0, height > 0, width <= bound, height <= bound else { return .empty }

        let bytesPerPixel = isColor ? 4 : 1
        let context: CGContext?
        if isColor {
            context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        } else {
            context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }
        guard let context else { return .empty }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(thicken)
        context.setShouldSmoothFonts(thicken)
        context.setAllowsFontSubpixelPositioning(false)
        context.setShouldSubpixelPositionFonts(false)
        context.setAllowsFontSubpixelQuantization(false)
        context.setShouldSubpixelQuantizeFonts(false)
        if !isColor { context.setFillColor(gray: 1, alpha: 1) }
        // Pixel space with the glyph's origin where its pixel bounds put it, then points.
        context.translateBy(x: -pixelBounds.minX + shiftX, y: -pixelBounds.minY + shiftY)
        context.scaleBy(x: drawScale, y: drawScale)
        context.textPosition = .zero
        CTLineDraw(line, context)

        guard let data = context.data else { return .empty }
        let count = width * height * bytesPerPixel
        let pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: count))
        // Rows run top-down in memory: the bitmap's top row is the glyph's highest pixels.
        return RasterizedGlyph(
            atlas: isColor ? .color : .mask, width: width, height: height, offsetX: Int(pixelBounds.minX),
            offsetY: cell.baseline - Int(pixelBounds.maxY), pixels: pixels)
    }

    /// Whether CoreText drew any part of the line with a color font (an emoji font).
    static func usesColorFont(_ line: CTLine) -> Bool {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return false }
        for run in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName as String] else { continue }
            let font = value as! CTFont
            if CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) { return true }
        }
        return false
    }
}

/// The oracle `RunScanner` asks, answered by the rasterizer that will draw the answer.
///
/// `RunShaping` is a class protocol because a conformer memoizes, and `GlyphRasterizer` is a
/// `Sendable` value that must not. So the conformance lives here: a reference a view can hold,
/// which shapes nothing itself and asks the rasterizer instead. That is the whole point of it.
/// A shaper that built its own line could answer "these ligate" while the rasterizer drew them
/// unligated into a bitmap still N cells wide, and the result — text that looks unligated and
/// is spaced as though it were — fails no test on any machine that can run the tests.
public final class RunShaper: RunShaping {
    private let rasterizer: GlyphRasterizer

    public init(_ rasterizer: GlyphRasterizer) { self.rasterizer = rasterizer }

    public func shapesAsOne(_ scalars: [UInt32], bold: Bool, italic: Bool) -> Bool {
        rasterizer.shapesAsOne(scalars, bold: bold, italic: italic)
    }
}
