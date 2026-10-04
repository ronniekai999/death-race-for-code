import ConfigKit
import Testing
import VTCore

@testable import SurfaceCore

/// Draws every glyph as a solid block of a fixed size; emoji (above U+1F000) in color.
private final class BlockRasterizer: GlyphRasterizing {
    var calls = 0
    var size = (width: 6, height: 10)

    func rasterize(_ key: GlyphKey) -> RasterizedGlyph {
        calls += 1
        if key.scalars == [0x20] { return .empty }
        let color = key.scalars[0] >= 0x1F000
        let bytes = color ? 4 : 1
        let value = UInt8(truncatingIfNeeded: key.scalars[0])
        return RasterizedGlyph(
            atlas: color ? .color : .mask, width: size.width, height: size.height, offsetX: 1, offsetY: 2,
            pixels: [UInt8](repeating: value, count: size.width * size.height * bytes))
    }
}

@Suite struct GlyphCacheTests {
    /// For tests that place several glyphs in one frame and aren't about the budget: it's
    /// wall-clock time, which a loaded machine could spend on the first glyph alone.
    static let unhurried: Duration = .seconds(60)

    @Test func glyphsAreRasterizedOnceAndPlacedInTheirAtlas() {
        let rasterizer = BlockRasterizer()
        let cache = GlyphCache(rasterizer: rasterizer, budget: Self.unhurried, maskSize: 64, colorSize: 64)
        cache.beginFrame()
        let a = cache.placement(for: GlyphKey(scalar: 0x41))
        let again = cache.placement(for: GlyphKey(scalar: 0x41))
        let emoji = cache.placement(for: GlyphKey(scalar: 0x1F389, wide: true))
        #expect(rasterizer.calls == 2)
        #expect(a == again)
        #expect(a?.atlas == .mask && emoji?.atlas == .color)
        #expect(a?.offsetX == 1 && a?.offsetY == 2 && a?.width == 6 && a?.height == 10)
        #expect(emoji.map { $0.shelf & GlyphCache.colorShelfBit } == GlyphCache.colorShelfBit)
        // The bitmap is in the atlas where the placement says.
        let x = Int(a!.x)
        let y = Int(a!.y)
        #expect(cache.mask.pixels[y * 64 + x] == 0x41)
        #expect(cache.mask.pixels[(y + 9) * 64 + x + 5] == 0x41)
        #expect(cache.color.pixels[(Int(emoji!.y) * 64 + Int(emoji!.x)) * 4] == 0x89)
        #expect(cache.mask.takeDirtyRows() == 0..<10)
        #expect(cache.mask.takeDirtyRows() == nil)
    }

    @Test func glyphsThatDrawNothingAreRemembered() {
        let rasterizer = BlockRasterizer()
        let cache = GlyphCache(rasterizer: rasterizer)
        cache.beginFrame()
        #expect(cache.placement(for: GlyphKey(scalar: 0x20))?.isEmpty == true)
        #expect(cache.placement(for: GlyphKey(scalar: 0x20))?.isEmpty == true)
        #expect(rasterizer.calls == 1)
    }

    @Test func theAtlasGrowsKeepingItsGlyphs() {
        let rasterizer = BlockRasterizer()
        let cache = GlyphCache(rasterizer: rasterizer, budget: Self.unhurried, maskSize: 16, maskMaxSize: 64)
        cache.beginFrame()
        let first = cache.placement(for: GlyphKey(scalar: 0x41))!
        _ = cache.takeDirty()
        // 16 × 16 holds two 7 × 11 slots side by side and no second shelf.
        _ = cache.placement(for: GlyphKey(scalar: 0x42))
        let third = cache.placement(for: GlyphKey(scalar: 0x43))
        #expect(third != nil)
        #expect(cache.mask.size == 32)
        #expect(cache.mask.sizeGeneration == 1)
        #expect(cache.mask.pixels[Int(first.y) * 32 + Int(first.x)] == 0x41)
        #expect(cache.mask.takeDirtyRows() == 0..<32)
        #expect(cache.epoch == 0)
    }

    @Test func quietShelvesAreReusedAndTheirGlyphsForgotten() {
        let rasterizer = BlockRasterizer()
        let cache = GlyphCache(rasterizer: rasterizer, budget: Self.unhurried, maskSize: 16, maskMaxSize: 16)
        cache.beginFrame()
        let a = cache.placement(for: GlyphKey(scalar: 0x41))!
        _ = cache.placement(for: GlyphKey(scalar: 0x42))
        // Full, and the only shelf was used this frame.
        #expect(cache.placement(for: GlyphKey(scalar: 0x43)) == nil)
        for _ in 0..<3 { cache.beginFrame() }
        let c = cache.placement(for: GlyphKey(scalar: 0x43))
        #expect(c != nil)
        #expect(c?.x == a.x && c?.y == a.y)
        #expect(cache.epoch == 1)
        // A and B were on the reused shelf: asking again rasterizes again.
        let calls = rasterizer.calls
        cache.beginFrame()
        _ = cache.placement(for: GlyphKey(scalar: 0x41))
        #expect(rasterizer.calls == calls + 1)
    }

    @Test func shelvesInUseAreNotReused() {
        let rasterizer = BlockRasterizer()
        let cache = GlyphCache(rasterizer: rasterizer, budget: Self.unhurried, maskSize: 16, maskMaxSize: 16)
        cache.beginFrame()
        let a = cache.placement(for: GlyphKey(scalar: 0x41))!
        _ = cache.placement(for: GlyphKey(scalar: 0x42))
        for _ in 0..<5 {
            cache.beginFrame()
            cache.markUsed(shelves: [a.shelf])
        }
        #expect(cache.placement(for: GlyphKey(scalar: 0x43)) == nil)
        #expect(cache.epoch == 0)
    }

    @Test func rasterizingStopsWhenTheFramesBudgetIsSpent() {
        let rasterizer = BlockRasterizer()
        let cache = GlyphCache(rasterizer: rasterizer, budget: .zero)
        cache.beginFrame()
        // The first glyph of a frame always comes; with no budget, the next waits.
        #expect(cache.placement(for: GlyphKey(scalar: 0x41)) != nil)
        #expect(cache.placement(for: GlyphKey(scalar: 0x42)) == nil)
        // Known glyphs need no budget.
        #expect(cache.placement(for: GlyphKey(scalar: 0x41)) != nil)
        cache.beginFrame()
        #expect(cache.placement(for: GlyphKey(scalar: 0x42)) != nil)
    }

    /// A frame of new glyphs past the budget fills in over a few frames.
    @Test func framesFillInUntilComplete() {
        let rasterizer = BlockRasterizer()
        let cache = GlyphCache(rasterizer: rasterizer, budget: .zero)
        let session = ReplaySession(Terminal.Configuration(columns: 4, rows: 1))
        let model = SurfaceModel(session: session)
        session.feed("abcd")
        _ = model.drain()
        let cell = CellMetrics(
            width: 6, height: 10, baseline: 8, underlineTop: 9, underlineThickness: 1, strikethroughTop: 5,
            strikethroughThickness: 1, scale: 1)
        let (frame, frames) = FrameBuilder().buildComplete(
            mirror: model.mirror, theme: .legendsNeverDie, cell: cell, selection: nil, glyphs: cache)
        #expect(frame.isComplete)
        #expect(frames == 4)
        #expect(frame.glyphs.count == 4)
    }

    /// The real box-drawing sprites through the cache and the frame builder.
    @Test func spritesFillTheirCells() {
        final class Sprites: GlyphRasterizing {
            func rasterize(_ key: GlyphKey) -> RasterizedGlyph {
                let pixels = SpriteRasterizer.rasterize(key.scalars[0], width: 8, height: 16) ?? []
                return RasterizedGlyph(atlas: .mask, width: 8, height: 16, offsetX: 0, offsetY: 0, pixels: pixels)
            }
        }
        let cache = GlyphCache(rasterizer: Sprites(), maskSize: 64)
        cache.beginFrame()
        let line = cache.placement(for: GlyphKey(scalar: 0x2500))!
        #expect(line.width == 8 && line.height == 16)
        // ─'s light line is row 7 of the sprite.
        let row = Int(line.y) + 7
        #expect((0..<8).allSatisfy { cache.mask.pixels[row * 64 + Int(line.x) + $0] == 255 })
    }
}

extension GlyphCache {
    /// Clears both atlases' dirty rows, as an upload does.
    func takeDirty() -> (Range<Int>?, Range<Int>?) {
        (mask.takeDirtyRows(), color.takeDirtyRows())
    }
}
