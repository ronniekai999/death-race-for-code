import AppKit
import CoreText
import SurfaceCore

/// The four faces terminal text uses, at one size.
///
/// CTFont is immutable and safe to use from any thread (CoreText's documentation says so), so
/// a font set crosses threads freely.
public struct FontSet: @unchecked Sendable {
    public let regular: CTFont
    public let bold: CTFont
    public let italic: CTFont
    public let boldItalic: CTFont
    /// Points.
    public let size: CGFloat
    /// The family the faces came from: the one asked for, or SF Mono when it is not
    /// installed.
    public let family: String
    /// The family asked for was not found.
    public let usedFallback: Bool

    /// The faces of `family` at `size` points, the italics from `italicFamily` when given
    /// (Neon with Radon's italics, say). "SF Mono" (or an empty name) is the system's
    /// monospaced font, which no name reaches: CTFontCreateWithName quietly returns Helvetica
    /// for names it does not know, so families are looked up through NSFontManager instead,
    /// and a missing one falls back to SF Mono. On the main thread, where NSFontManager lives.
    ///
    /// When the bundled Symbols Nerd Font Mono is registered, it comes first in every face's
    /// fallback list, so prompts' icons (Starship, Powerlevel10k) draw from it.
    @MainActor
    public init(family: String, size: CGFloat, italicFamily: String? = nil) {
        let size = max(1, size)
        let wantsSystem = family.isEmpty || family.caseInsensitiveCompare("SF Mono") == .orderedSame
        let manager = NSFontManager.shared
        let regular: NSFont
        let bold: NSFont
        var usedFallback = false
        if !wantsSystem, let named = manager.font(withFamily: family, traits: [], weight: 5, size: size) {
            regular = named
            bold = manager.font(withFamily: family, traits: .boldFontMask, weight: 9, size: size) ?? named
        } else {
            usedFallback = !wantsSystem
            regular = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            bold = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        }
        var italic = Self.italic(of: regular as CTFont)
        var boldItalic = Self.italic(of: bold as CTFont)
        if let italicFamily, !italicFamily.isEmpty,
            let named = manager.font(withFamily: italicFamily, traits: .italicFontMask, weight: 5, size: size),
            CTFontGetSymbolicTraits(named as CTFont).contains(.traitItalic)
        {
            italic = named as CTFont
            let boldNamed = manager.font(
                withFamily: italicFamily, traits: [.italicFontMask, .boldFontMask], weight: 9, size: size)
            boldItalic = (boldNamed ?? named) as CTFont
        }
        let symbols = FontRegistry.symbolsDescriptor
        self.regular = Self.withSymbolsFirst(regular as CTFont, symbols: symbols)
        self.bold = Self.withSymbolsFirst(bold as CTFont, symbols: symbols)
        self.italic = Self.withSymbolsFirst(italic, symbols: symbols)
        self.boldItalic = Self.withSymbolsFirst(boldItalic, symbols: symbols)
        self.size = size
        self.family = usedFallback || wantsSystem ? "SF Mono" : family
        self.usedFallback = usedFallback
    }

    /// The face for a style.
    public func face(bold isBold: Bool, italic isItalic: Bool) -> CTFont {
        switch (isBold, isItalic) {
        case (false, false): regular
        case (true, false): bold
        case (false, true): italic
        case (true, true): boldItalic
        }
    }

    /// `font` with `symbols` first in its fallback list, then the system's list for the
    /// user's languages; `font` itself when there is no symbols font.
    static func withSymbolsFirst(_ font: CTFont, symbols: CTFontDescriptor?) -> CTFont {
        guard let symbols else { return font }
        let languages = Locale.preferredLanguages as CFArray
        let fallbacks = CTFontCopyDefaultCascadeListForLanguages(font, languages) as? [CTFontDescriptor] ?? []
        let cascade = CTFontDescriptorCreateWithAttributes(
            [kCTFontCascadeListAttribute: [symbols] + fallbacks] as CFDictionary)
        // Size 0 and no matrix keep the font's own: an italic made by slanting stays slanted.
        return CTFontCreateCopyWithAttributes(font, 0, nil, cascade)
    }

    /// The family's italic of `font`, or `font` slanted 12° when the family has none.
    static func italic(of font: CTFont) -> CTFont {
        if let italic = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitItalic, .traitItalic),
            CTFontGetSymbolicTraits(italic).contains(.traitItalic)
        {
            return italic
        }
        var slant = CGAffineTransform(a: 1, b: 0, c: 0.2126, d: 1, tx: 0, ty: 0)  // tan 12°
        return CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), &slant, nil)
    }

    /// The regular face's measurements: the widest printable ASCII advance and the vertical
    /// metrics.
    public var measurements: FontMeasurements {
        let characters = (0x20...0x7E).map { UniChar($0) }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        _ = CTFontGetGlyphsForCharacters(regular, characters, &glyphs, characters.count)
        var advances = [CGSize](repeating: .zero, count: characters.count)
        _ = CTFontGetAdvancesForGlyphs(regular, .horizontal, glyphs, &advances, characters.count)
        var widest: CGFloat = 0
        for (glyph, advance) in zip(glyphs, advances) where glyph != 0 {
            widest = max(widest, advance.width)
        }
        if widest == 0 { widest = size * 0.6 }
        return FontMeasurements(
            advance: Double(widest),
            ascent: Double(CTFontGetAscent(regular)),
            descent: Double(CTFontGetDescent(regular)),
            leading: Double(CTFontGetLeading(regular)),
            underlinePosition: Double(CTFontGetUnderlinePosition(regular)),
            underlineThickness: Double(CTFontGetUnderlineThickness(regular)),
            xHeight: Double(CTFontGetXHeight(regular)))
    }

    /// The grid cell these faces need at a backing scale.
    public func cellMetrics(scale: CGFloat) -> CellMetrics {
        CellMetrics(measurements, scale: Double(scale))
    }
}
