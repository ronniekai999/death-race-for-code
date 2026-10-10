import ConfigKit
import CoreText
import Foundation
import Metal
import ScreenProtocol
import SurfaceCore
import Testing
import VTCore

@testable import RenderKit

@MainActor
@Suite struct GlyphRasterizerTests {
    let fonts = FontSet(family: "SF Mono", size: 13)

    var rasterizer: GlyphRasterizer {
        GlyphRasterizer(fonts: fonts, cell: fonts.cellMetrics(scale: 2), language: "en")
    }

    @Test func letterIsCoverageInsideItsCell() {
        let cell = fonts.cellMetrics(scale: 2)
        let glyph = rasterizer.rasterize(GlyphKey(scalar: 0x61))
        #expect(glyph.atlas == .mask)
        #expect(glyph.width > 4 && glyph.width <= cell.width + 2)
        #expect(glyph.height > 4 && glyph.height < cell.height)
        // An x-height letter sits above the baseline, below the top.
        #expect(glyph.offsetY > 0 && glyph.offsetY + glyph.height <= cell.baseline + 2)
        #expect(glyph.pixels.count == glyph.width * glyph.height)
        #expect((glyph.pixels.max() ?? 0) >= 200)
    }

    @Test func boldIsHeavier() {
        let regular = rasterizer.rasterize(GlyphKey(scalar: 0x6D))
        let bold = rasterizer.rasterize(GlyphKey(scalar: 0x6D, bold: true))
        let ink = { (glyph: RasterizedGlyph) in glyph.pixels.reduce(0) { $0 + Int($1) } }
        #expect(ink(bold) > ink(regular))
    }

    @Test func emojiAreColorAndFitTwoCells() {
        let cell = fonts.cellMetrics(scale: 2)
        let glyph = rasterizer.rasterize(GlyphKey(scalar: 0x1F389, wide: true))
        #expect(glyph.atlas == .color)
        // Rounding out to whole pixels and a pixel of room for antialiasing on each side.
        #expect(glyph.width <= 2 * cell.width + 4)
        #expect(glyph.height <= cell.height + 4)
        #expect(glyph.pixels.count == glyph.width * glyph.height * 4)
        // Some pixels are opaque.
        #expect(stride(from: 3, to: glyph.pixels.count, by: 4).contains { glyph.pixels[$0] > 200 })
    }

    @Test func hanCharactersSpanTwoCells() {
        let cell = fonts.cellMetrics(scale: 2)
        let glyph = rasterizer.rasterize(GlyphKey(scalar: 0x4F60, wide: true))
        #expect(glyph.atlas == .mask)
        #expect(glyph.width > cell.width && glyph.width <= 2 * cell.width + 4)
    }

    @Test func boxDrawingComesFromSprites() {
        let cell = fonts.cellMetrics(scale: 2)
        let glyph = rasterizer.rasterize(GlyphKey(scalar: 0x2502))
        #expect(glyph.width == cell.width && glyph.height == cell.height)
        #expect(glyph.offsetX == 0 && glyph.offsetY == 0)
        #expect(glyph.pixels == SpriteRasterizer.rasterize(0x2502, width: cell.width, height: cell.height))
    }

    @Test func spacesDrawNothing() {
        #expect(rasterizer.rasterize(GlyphKey(scalar: 0x20)).isEmpty)
    }

    @Test func clustersAreShapedTogether() {
        let glyph = rasterizer.rasterize(GlyphKey(scalars: [0x65, 0x301], bold: false, italic: false, wide: false))
        let plain = rasterizer.rasterize(GlyphKey(scalar: 0x65))
        // The accent adds ink above the e.
        #expect(glyph.offsetY < plain.offsetY)
    }
}

@MainActor
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct RendererTests {
    @Test func theShadersCompile() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        _ = try RenderPipelines(device: device)
        _ = try RenderPipelines(device: device, pixelFormat: .rgba16Float)
    }

    @Test func rawAndPNGImagesDrawWithTheSameOrientationAndSurviveIDReuse() throws {
        let renderer = try OffscreenRenderer()
        let fonts = FontSet(family: "SF Mono", size: 13)
        let cell = fonts.cellMetrics(scale: 2)
        let session = ReplaySession(Terminal.Configuration(columns: 4, rows: 4))
        let model = SurfaceModel(session: session)
        let rgb: [UInt8] = [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255]
        let png = try #require(
            RenderedImage(
                width: 2, height: 2,
                bgra: [
                    0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255,
                ]
            ).pngData())
        for (format, payload) in [(24, Data(rgb)), (100, png)] {
            session.feed(
                "\u{1B}c\u{1B}_Ga=T,f=\(format),s=2,v=2,i=7,c=2,r=2,C=1;\(payload.base64EncodedString())\u{1B}\\")
            _ = model.drain()
            let glyphs = GlyphCache(rasterizer: GlyphRasterizer(fonts: fonts, cell: cell))
            let frame = FrameBuilder().buildComplete(
                mirror: model.mirror, theme: .legendsNeverDie, cell: cell, selection: nil, glyphs: glyphs
            ).frame
            let layout = PixelLayout(width: 4 * cell.width, height: 4 * cell.height, originX: 0, originY: 0)
            let image = try renderer.render(frame, cell: cell, layout: layout, glyphs: glyphs, mirror: model.mirror)
            let upperLeft = image.pixel(x: cell.width / 2, y: cell.height / 2)
            let upperRight = image.pixel(x: cell.width + cell.width / 2, y: cell.height / 2)
            let lowerLeft = image.pixel(x: cell.width / 2, y: cell.height + cell.height / 2)
            #expect(upperLeft.red > 240 && upperLeft.green < 15 && upperLeft.blue < 15)
            #expect(upperRight.green > 240 && upperRight.red < 15 && upperRight.blue < 15)
            #expect(lowerLeft.blue > 240 && lowerLeft.red < 15 && lowerLeft.green < 15)
        }
    }

    /// Text, a background and an underline drawn by the GPU, checked pixel by pixel.
    @Test func aFrameDrawsItsColors() throws {
        let renderer = try OffscreenRenderer()
        let fonts = FontSet(family: "SF Mono", size: 13)
        let cell = fonts.cellMetrics(scale: 2)
        let session = ReplaySession(Terminal.Configuration(columns: 10, rows: 3))
        let model = SurfaceModel(session: session)
        // Row 1: "HI" red on blue, then an underlined "u" in the default colors.
        session.feed("\r\n\u{1B}[31;44mHI\u{1B}[0m \u{1B}[4mu\u{1B}[0m")
        _ = model.drain()
        let glyphs = GlyphCache(rasterizer: GlyphRasterizer(fonts: fonts, cell: cell))
        let frame = FrameBuilder().buildComplete(
            mirror: model.mirror, theme: .legendsNeverDie, cell: cell, selection: nil, glyphs: glyphs
        ).frame
        #expect(frame.isComplete)
        let layout = PixelLayout(
            width: 10 * cell.width + 20, height: 3 * cell.height + 20, originX: 10, originY: 10)
        let image = try renderer.render(frame, cell: cell, layout: layout, glyphs: glyphs)
        let palette = model.mirror.palette

        func near(_ x: Int, _ y: Int, _ color: RGB, within: Int = 2) -> Bool {
            let pixel = image.pixel(x: x, y: y)
            return abs(Int(pixel.red) - Int(color.red)) <= within && abs(Int(pixel.green) - Int(color.green)) <= within
                && abs(Int(pixel.blue) - Int(color.blue)) <= within && pixel.alpha == 255
        }
        // Padding and row 0 are the background.
        #expect(near(2, 2, palette.background))
        #expect(near(10 + cell.width / 2, 10 + cell.height / 2, palette.background))
        // The cell under H has a blue background at its corner, and red ink inside.
        let top = 10 + cell.height
        #expect(near(10, top, palette.colors[4]))
        let redInk = (top..<(top + cell.height)).contains { y in
            (10..<(10 + cell.width)).contains { x in near(x, y, palette.colors[1], within: 24) }
        }
        #expect(redInk)
        // The underline under u is the text color, across the whole cell.
        let underlineY = top + cell.underlineTop
        let uLeft = 10 + 3 * cell.width
        #expect((uLeft..<(uLeft + cell.width)).allSatisfy { near($0, underlineY, palette.foreground, within: 8) })
        // Nothing is drawn below the last row's text: the bottom padding is background.
        #expect(near(layout.width - 3, layout.height - 3, palette.background))
        #expect(image.pngData()?.isEmpty == false)
    }
}
