import AppKit
import CoreText
import SurfaceCore
import Testing

@testable import RenderKit

/// The fonts `scripts/fetch-fonts.sh` puts in build/fonts; CI fetches them before testing.
let bundledFontsFetched = FontRegistry.directory() != nil

@MainActor
@Suite struct FontRegistryTests {
    /// The family CoreText draws `scalar` from with `font`, its fallbacks included.
    func family(drawing scalar: UInt32, with font: CTFont) -> String? {
        let text = String(Character(UnicodeScalar(scalar)!)) as CFString
        guard let attributed = CFAttributedStringCreate(nil, text, [kCTFontAttributeName: font] as CFDictionary),
            let run = (CTLineGetGlyphRuns(CTLineCreateWithAttributedString(attributed)) as? [CTRun])?.first,
            let value = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String]
        else { return nil }
        return CTFontCopyFamilyName(value as! CTFont) as String
    }

    @Test(.enabled(if: bundledFontsFetched, "run scripts/fetch-fonts.sh first"))
    func theBundledFontsRegisterForThisProcess() {
        let report = FontRegistry.registerBundledFonts()
        #expect(report.failed.isEmpty, "\(report.failed)")
        #expect(report.registered.count == 9, "\(report.registered)")
        let families = Set(NSFontManager.shared.availableFontFamilies)
        for family in FontRegistry.bundledFamilies + [FontRegistry.symbolsFamily] {
            #expect(families.contains(family), "\(family) is missing")
        }
        // Once only.
        #expect(FontRegistry.registerBundledFonts() == report)
    }

    @Test(.enabled(if: bundledFontsFetched, "run scripts/fetch-fonts.sh first"))
    func neonWithRadonsItalicsAndIconsFromTheSymbols() {
        FontRegistry.registerBundledFonts()
        let fonts = FontSet(family: "Monaspace Neon", size: 13, italicFamily: "Monaspace Radon")
        #expect(!fonts.usedFallback)
        #expect(fonts.family == "Monaspace Neon")
        #expect(CTFontCopyFamilyName(fonts.regular) as String == "Monaspace Neon")
        #expect(CTFontCopyFamilyName(fonts.italic) as String == "Monaspace Radon")
        #expect(CTFontGetSymbolicTraits(fonts.italic).contains(.traitItalic))
        #expect(CTFontGetSymbolicTraits(fonts.boldItalic).contains(.traitBold))
        // nf-fa-folder, a prompt's folder icon, from the symbols font in every face.
        for face in [fonts.regular, fonts.bold, fonts.italic, fonts.boldItalic] {
            #expect(family(drawing: 0xF07B, with: face) == FontRegistry.symbolsFamily)
        }
        // Letters still come from the face itself.
        #expect(family(drawing: 0x61, with: fonts.regular) == "Monaspace Neon")
        // SF Mono gets the icons too, though CoreText does not apply a fallback list to the
        // system's monospaced font: the rasterizer draws private-use characters from the
        // symbols font itself.
        let mono = FontSet(family: "SF Mono", size: 13)
        let rasterizer = GlyphRasterizer(fonts: mono, cell: mono.cellMetrics(scale: 2))
        func drawnFrom(_ scalar: UInt32) -> String {
            CTFontCopyFamilyName(rasterizer.face(for: GlyphKey(scalar: scalar))) as String
        }
        #expect(drawnFrom(0xF07B) == FontRegistry.symbolsFamily)
        #expect(drawnFrom(0x61) != FontRegistry.symbolsFamily)
        #expect(rasterizer.rasterize(GlyphKey(scalar: 0xF07B)).pixels.contains { $0 > 128 })
    }
}
