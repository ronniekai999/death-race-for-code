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

    public init(fonts: FontSet, cell: CellMetrics, thicken: Bool = false, language: String? = nil) {
        self.fonts = fonts
        self.cell = cell
        self.thicken = thicken
        self.language = language ?? Locale.preferredLanguages.first
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

    private func drawText(_ key: GlyphKey) -> RasterizedGlyph {
        let font = fonts.face(bold: key.bold, italic: key.italic)
        var attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: true,
        ]
        if let language { attributes[kCTLanguageAttributeName] = language as CFString }
        guard
            let attributed = CFAttributedStringCreate(
                kCFAllocatorDefault, key.string as CFString, attributes as CFDictionary)
        else { return .empty }
        let line = CTLineCreateWithAttributedString(attributed)
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
        guard width > 0, height > 0, width <= 1024, height <= 1024 else { return .empty }

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
