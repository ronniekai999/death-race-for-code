import Testing

@testable import SurfaceCore

/// A `GlyphKey` that covers several columns, for the runs a font draws as one glyph.
///
/// The first test is the important one: it pins the bits every other kind of key packs into, so
/// the claim that shaping off leaves the frame exactly as it was is a claim about numbers rather
/// than about care — and so the next person to take a free bit cannot move these by accident.
@Suite struct GlyphKeyRunTests {
    @Test func theBitsEveryOtherKindOfKeyPacksAreUnchanged() {
        #expect(GlyphKey(scalar: 0x41).packed == 0x41)
        #expect(GlyphKey(scalar: 0x41, bold: true).packed == 0x41 | 1 << 21)
        #expect(GlyphKey(scalar: 0x41, italic: true).packed == 0x41 | 1 << 22)
        #expect(GlyphKey(scalar: 0x4F60, wide: true).packed == 0x4F60 | 1 << 23)
        // A cluster's scalars live beside the word, so only the cluster bit is set in it.
        #expect(GlyphKey(scalars: [0x65, 0x301], bold: false, italic: false, wide: false).packed == 1 << 24)
        // And the run bits are zero on all of them, which is what `cells` falls back from.
        for key in [
            GlyphKey(scalar: 0x41), GlyphKey(scalar: 0x41, bold: true), GlyphKey(scalar: 0x4F60, wide: true),
            GlyphKey(scalars: [0x65, 0x301], bold: false, italic: false, wide: false),
        ] {
            #expect(!key.isRun)
        }
    }

    @Test func aRunCountsItsColumns() {
        let two = GlyphKey(run: Array("!=".unicodeScalars.map(\.value)), bold: false, italic: false)
        #expect(two.isRun)
        #expect(two.cells == 2)
        #expect(two.string == "!=")
        let three = GlyphKey(run: Array("===".unicodeScalars.map(\.value)), bold: false, italic: false)
        #expect(three.cells == 3)
        #expect(three.string == "===")
        let eight = GlyphKey(run: Array(repeating: UInt32(0x2D), count: 8), bold: false, italic: false)
        #expect(eight.cells == 8)
    }

    @Test func aRunIsNeverAlsoWide() {
        // The alphabet is one-column characters, so the two cannot both be true; a caller that
        // asks for both gets a run, because that is what decides the width.
        let key = GlyphKey(scalars: [0x21, 0x3D], bold: false, italic: false, wide: true, runCells: 2)
        #expect(key.isRun)
        #expect(!key.isWide)
        #expect(key.cells == 2)
    }

    /// Five bits hold 32, and a caller asking for more gets 32 rather than a wrapped-around
    /// span that would read as a one-cell glyph.
    @Test func theSpanIsClampedRatherThanWrapped() {
        let scalars = Array(repeating: UInt32(0x2D), count: 40)
        let key = GlyphKey(run: scalars, bold: false, italic: false)
        #expect(key.cells == GlyphKey.maxRunCells)
        #expect(key.isRun)
    }

    /// A run of two scalars and a grapheme cluster of the same two are different glyphs, and
    /// the cache must not answer one with the other.
    @Test func aRunAndAClusterOverTheSameScalarsAreDifferentKeys() {
        let scalars: [UInt32] = [0x65, 0x301]
        let run = GlyphKey(run: scalars, bold: false, italic: false)
        let cluster = GlyphKey(scalars: scalars, bold: false, italic: false, wide: false)
        #expect(run != cluster)
        #expect(run.packed != cluster.packed)
        #expect(cluster.cells == 1)
        #expect(run.cells == 2)
    }

    /// Fewer than two columns is not a run: one character shaped alone is the ordinary path,
    /// and giving it run bits would make a second cache entry for the same glyph.
    ///
    /// The `runCells >= 2` floor in the initializer reads as that intent but is not separately
    /// provable — a span is stored less one, so 1 writes the same zero that 0 does. What is
    /// provable, and what this pins, is the outcome: neither count makes a run, and both pack
    /// to the very bits a plain key packs.
    @Test func neitherZeroNorOneColumnsMakeARun() {
        for count in [0, 1] {
            let key = GlyphKey(scalars: [0x41], bold: false, italic: false, wide: false, runCells: count)
            #expect(!key.isRun, "runCells \(count)")
            #expect(key.cells == 1, "runCells \(count)")
            #expect(key.packed == GlyphKey(scalar: 0x41).packed, "runCells \(count)")
        }
    }

    @Test func aRunKeepsItsFaceAndItsText() {
        let key = GlyphKey(run: Array("=>".unicodeScalars.map(\.value)), bold: true, italic: true)
        #expect(key.bold)
        #expect(key.italic)
        #expect(key.scalars == Array("=>".unicodeScalars.map(\.value)))
        #expect(key.cells == 2)
    }
}
