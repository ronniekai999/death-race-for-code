import ConfigKit
import Metal
import ScreenProtocol
import SurfaceCore
import Testing
import VTCore

@testable import RenderKit

/// The one claim about `Uniforms` the Mac can check without a GPU, and the one the file's own
/// header has been making since Phase 2 without it being true: `GlyphInstance` and
/// `DecorationInstance` have had `MemoryLayout` pins in SurfaceCoreTests all along, and
/// `Uniforms` could not, because it is internal to RenderKit and that suite cannot see it.
@Suite struct UniformsLayoutTests {
    @Test func theLayoutIsWhatTheShadersAssert() {
        #expect(MemoryLayout<Uniforms>.size == 48)
        #expect(MemoryLayout<Uniforms>.stride == 48)
        #expect(MemoryLayout<Uniforms>.alignment == 8)
        // `setVertexBytes` sends the stride, so size and stride have to be equal or the shader
        // reads bytes this side never wrote. That is what `reserved` is for.
        #expect(MemoryLayout<Uniforms>.size == MemoryLayout<Uniforms>.stride)
        #expect(MemoryLayout<Uniforms>.offset(of: \.clearColor) == 32)
        #expect(MemoryLayout<Uniforms>.offset(of: \.dim) == 36)
        #expect(MemoryLayout<Uniforms>.offset(of: \.glow) == 40)
        #expect(MemoryLayout<Uniforms>.offset(of: \.reserved) == 44)
    }
}

/// A fake rasterizer, so a test can choose what lands in the atlas and in what order. The real
/// one draws whatever CoreText draws, which is the wrong tool for a question about atlas
/// neighbours.
private final class ChosenBitmaps: GlyphRasterizing {
    /// Scalar to (width, height, atlas).
    var shapes: [UInt32: (Int, Int, AtlasKind)] = [:]

    func rasterize(_ key: GlyphKey) -> RasterizedGlyph {
        guard let scalar = key.scalars.first, let shape = shapes[scalar] else { return .empty }
        let (width, height, atlas) = shape
        let bytes = atlas == .color ? 4 : 1
        // Solid: coverage 255 everywhere, or premultiplied opaque cyan.
        var pixels = [UInt8](repeating: 0xFF, count: width * height * bytes)
        if atlas == .color {
            for index in stride(from: 0, to: pixels.count, by: 4) {
                pixels[index] = 0xFF  // blue
                pixels[index + 1] = 0xC8  // green
                pixels[index + 2] = 0x5C  // red
            }
        }
        return RasterizedGlyph(atlas: atlas, width: width, height: height, offsetX: 2, offsetY: 5, pixels: pixels)
    }
}

@MainActor
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct GlowRenderTests {
    /// Strong enough that a missed exclusion could not hide in the antialiasing noise.
    static let strong: PackedColor = Glow(strength: 1).packed

    /// One renderer for the suite. `makeLibrary(source:)` compiles the whole shader library and
    /// `Shaders.swift`'s own header puts that at a few tens of milliseconds, "done once per
    /// device" — one per `image(...)` call would be nine or ten compilations added to the macOS
    /// Test step for this suite alone.
    ///
    /// Sharing it means sharing its atlas *texture*, which these tests do not all share a
    /// `GlyphCache` with — and `SurfaceRenderer` keys that texture on `sizeGeneration` alone, so
    /// a second cache of the same size does not get a new one. That is safe here, and by an
    /// argument rather than by luck: each `render` uploads the full width of whatever rows its
    /// own cache dirtied, and every glyph a render draws was placed by that cache in that frame,
    /// so it lies inside those rows. The texture can be stale only *outside* the box
    /// `glowFragment` clamps its taps to. What would break it is rendering a cache that has no
    /// dirty rows left after a different cache has uploaded — which no test here does.
    static let shared: OffscreenRenderer? = try? OffscreenRenderer()

    static let cell = CellMetrics(
        width: 16, height: 32, baseline: 24, underlineTop: 27, underlineThickness: 2, strikethroughTop: 16,
        strikethroughThickness: 2, scale: 2)

    /// A one-row frame holding `text`, with the glyphs `rasterizer` chooses.
    func frame(
        _ text: String, columns: Int = 6, rasterizer: any GlyphRasterizing
    ) -> (Frame, GlyphCache, PixelLayout) {
        let session = ReplaySession(Terminal.Configuration(columns: columns, rows: 1))
        let model = SurfaceModel(session: session)
        session.feed(text)
        _ = model.drain()
        let glyphs = GlyphCache(rasterizer: rasterizer)
        let built = FrameBuilder().buildComplete(
            mirror: model.mirror, theme: .legendsNeverDie, cell: Self.cell, selection: nil, glyphs: glyphs)
        let layout = PixelLayout(
            width: columns * Self.cell.width + 16, height: Self.cell.height + 16, originX: 8, originY: 8)
        return (built.frame, glyphs, layout)
    }

    func image(
        _ text: String, glow: PackedColor, dim: PackedColor = 0, rasterizer: (any GlyphRasterizing)? = nil
    ) throws -> RenderedImage {
        let renderer = try #require(Self.shared)
        let raster = rasterizer ?? GlyphRasterizer(fonts: FontSet(family: "SF Mono", size: 13), cell: Self.cell)
        let (built, glyphs, layout) = frame(text, rasterizer: raster)
        #expect(built.isComplete)
        return try renderer.render(built, cell: Self.cell, layout: layout, glyphs: glyphs, dim: dim, glow: glow)
    }

    /// The whole promise of "bright colours only", as a byte comparison rather than as a claim:
    /// a screen of ordinary output is the same frame with the glow on as with it off. This is
    /// what the vertex-stage cull buys — no fragment runs for a glyph that does not emit.
    @Test func ordinaryTextIsBitIdenticalWithTheGlowOn() throws {
        let off = try image("hello", glow: 0)
        let on = try image("hello", glow: Self.strong)
        #expect(off.bgra == on.bgra)
    }

    @Test func aBrightColourAddsLight() throws {
        let off = try image("\u{1B}[36mX", glow: 0)
        let on = try image("\u{1B}[36mX", glow: Self.strong)
        #expect(off.bgra != on.bgra)
        // Added, never taken away: every channel of every pixel is at least what it was, and the
        // alpha the glyph draw blends against is untouched — that is the RGB-only write mask.
        var brighter = 0
        for index in off.bgra.indices {
            if index % 4 == 3 {
                #expect(on.bgra[index] == off.bgra[index], "alpha moved at byte \(index)")
            } else {
                #expect(on.bgra[index] >= off.bgra[index], "a channel darkened at byte \(index)")
                if on.bgra[index] > off.bgra[index] { brighter += 1 }
            }
        }
        #expect(brighter > 20, "only \(brighter) channels brightened, which is not a halo")
    }

    /// Where "only the pane you are working in glows" comes from: no new condition, just the
    /// fade an inactive pane already carries.
    @Test func aDimmedPaneNeverGlows() throws {
        let dim = Dimming(color: RGB(hex: 0x160C2E), amount: 0.14).packed
        let off = try image("\u{1B}[36mX", glow: 0, dim: dim)
        let on = try image("\u{1B}[36mX", glow: Self.strong, dim: dim)
        #expect(off.bgra == on.bgra)
    }

    /// An emoji carries its own colour, and the scatter reads the mask atlas only — so a colour
    /// glyph would glow from whatever the mask happened to hold at those coordinates. The flag
    /// is what stops it, and the glyph's own colour word here is a saturated cyan, so nothing
    /// else could be.
    @Test func aColourGlyphNeverGlows() throws {
        let rasterizer = ChosenBitmaps()
        rasterizer.shapes[0x43] = (8, 12, .color)
        let off = try image("\u{1B}[36mC", glow: 0, rasterizer: rasterizer)
        let on = try image("\u{1B}[36mC", glow: Self.strong, rasterizer: rasterizer)
        #expect(off.bgra == on.bgra)
    }

    /// The highest-probability real bug in the whole change, and the one thing no amount of
    /// reading catches: `access::read` returns zero outside the *texture*, and `ShelfAtlas` pads
    /// a glyph by one pixel — so a tap three pixels out lands squarely in whatever was packed
    /// next to it on the same shelf.
    ///
    /// Two bitmaps of the same height go on the same shelf, in order: a wide solid block, then a
    /// two-pixel sliver. Only the sliver is drawn, and brightly. Its halo has to be as bright on
    /// the side facing the block as on the side facing nothing; without the clamp the block's
    /// solid ink pours into one side of it.
    @Test func aGlowReadsOnlyItsOwnGlyph() throws {
        let rasterizer = ChosenBitmaps()
        rasterizer.shapes[0x41] = (8, 12, .mask)
        rasterizer.shapes[0x42] = (2, 12, .mask)
        let glyphs = GlyphCache(rasterizer: rasterizer)
        // Insert the block first, so the sliver lands beside it rather than at the shelf's start.
        // `beginFrame()` before each, as every real caller does: a frame has a rasterizing
        // budget and only its *first* glyph is drawn unconditionally, so two bare calls on a
        // busy runner get a nil for the second and nothing says why.
        glyphs.beginFrame()
        let block = try #require(glyphs.placement(for: GlyphKey(scalar: 0x41)))
        glyphs.beginFrame()
        let sliver = try #require(glyphs.placement(for: GlyphKey(scalar: 0x42)))
        // The premise, asserted rather than assumed: if the packer ever stops putting these two
        // side by side, this test proves nothing and should say so instead of passing.
        #expect(block.y == sliver.y, "the two bitmaps are not on one shelf")
        #expect(sliver.x > block.x && Int(sliver.x) - Int(block.x + block.width) <= 2, "they are not adjacent")

        let session = ReplaySession(Terminal.Configuration(columns: 6, rows: 1))
        let model = SurfaceModel(session: session)
        session.feed("\u{1B}[36m\u{0042}")
        _ = model.drain()
        let built = FrameBuilder().buildComplete(
            mirror: model.mirror, theme: .legendsNeverDie, cell: Self.cell, selection: nil, glyphs: glyphs)
        #expect(built.frame.isComplete)
        let layout = PixelLayout(
            width: 6 * Self.cell.width + 16, height: Self.cell.height + 16, originX: 8, originY: 8)
        let renderer = try #require(Self.shared)
        let off = try renderer.render(built.frame, cell: Self.cell, layout: layout, glyphs: glyphs)
        let on = try renderer.render(
            built.frame, cell: Self.cell, layout: layout, glyphs: glyphs, glow: Self.strong)

        // The sliver on screen: cell 0 plus the rasterizer's own offset.
        let inkLeft = layout.originX + 2
        let inkTop = layout.originY + 5
        func light(_ columns: Range<Int>) -> Int {
            var total = 0
            for y in inkTop..<(inkTop + 12) {
                for x in columns {
                    let before = off.pixel(x: x, y: y)
                    let after = on.pixel(x: x, y: y)
                    total += Int(after.red) - Int(before.red)
                    total += Int(after.green) - Int(before.green)
                    total += Int(after.blue) - Int(before.blue)
                }
            }
            return total
        }
        let towardTheBlock = light((inkLeft - 4)..<inkLeft)
        let towardNothing = light((inkLeft + 2)..<(inkLeft + 6))
        #expect(towardNothing > 0, "the sliver threw no light at all, so this proves nothing")
        #expect(
            towardTheBlock <= towardNothing * 3 / 2,
            "the halo is \(towardTheBlock) toward the neighbouring glyph and \(towardNothing) away from it")
    }
}
