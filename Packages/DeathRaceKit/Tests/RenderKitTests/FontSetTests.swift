import CoreText
import Testing

@testable import RenderKit

@MainActor
@Suite struct FontSetTests {
    @Test func sfMonoIsTheSystemsMonospacedFont() {
        let fonts = FontSet(family: "SF Mono", size: 13)
        #expect(!fonts.usedFallback)
        #expect(fonts.family == "SF Mono")
        let measurements = fonts.measurements
        #expect(measurements.advance > 6 && measurements.advance < 10)
        #expect(measurements.ascent > 8 && measurements.descent > 1)
        #expect(measurements.underlineThickness > 0)
        let cell = fonts.cellMetrics(scale: 2)
        #expect(cell.width >= 12 && cell.width <= 20)
        #expect(cell.height >= 24 && cell.height <= 40)
        #expect(cell.baseline > cell.height / 2 && cell.baseline < cell.height)
    }

    @Test func everyPrintableASCIICharacterHasTheSameAdvance() {
        let fonts = FontSet(family: "SF Mono", size: 13)
        let characters = (0x20...0x7E).map { UniChar($0) }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        let found = CTFontGetGlyphsForCharacters(fonts.regular, characters, &glyphs, characters.count)
        #expect(found)
        var advances = [CGSize](repeating: .zero, count: characters.count)
        _ = CTFontGetAdvancesForGlyphs(fonts.regular, .horizontal, glyphs, &advances, characters.count)
        #expect(Set(advances.map(\.width)).count == 1)
    }

    @Test func namedFamiliesHaveTheirOwnFaces() {
        let fonts = FontSet(family: "Menlo", size: 12)
        #expect(!fonts.usedFallback)
        #expect(fonts.family == "Menlo")
        let names = [fonts.regular, fonts.bold, fonts.italic, fonts.boldItalic].map {
            CTFontCopyPostScriptName($0) as String
        }
        #expect(Set(names).count == 4, "\(names)")
        #expect(CTFontGetSymbolicTraits(fonts.italic).contains(.traitItalic))
        #expect(fonts.face(bold: true, italic: true) === fonts.boldItalic)
    }

    @Test func aMissingFamilyFallsBackToSFMono() {
        let fonts = FontSet(family: "No Such Font 999", size: 13)
        #expect(fonts.usedFallback)
        #expect(fonts.family == "SF Mono")
        #expect(fonts.measurements == FontSet(family: "SF Mono", size: 13).measurements)
    }

    /// Without an italic face, italic is the upright face slanted.
    @Test func syntheticItalicSlants() {
        let upright = CTFontCreateWithName("Menlo-Regular" as CFString, 12, nil)
        let slanted = FontSet.italic(of: upright)
        let matrix = CTFontGetMatrix(slanted)
        let traits = CTFontGetSymbolicTraits(slanted)
        #expect(traits.contains(.traitItalic) || matrix.c > 0.2)
    }
}
