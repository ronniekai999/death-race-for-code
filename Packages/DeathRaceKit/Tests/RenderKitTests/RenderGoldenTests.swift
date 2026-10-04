import ConfigKit
import CoreGraphics
import Foundation
import ImageIO
import Metal
import SurfaceCore
import Testing
import VTCore

@testable import RenderKit

// Outside the suite: its traits cannot refer to the type they are attached to.
private let comparingRenders = ProcessInfo.processInfo.environment["DEATHRACE_RENDER_GOLDENS"] == "1"
private let renderPreviewDirectory = ProcessInfo.processInfo.environment["DEATHRACE_RENDER_PREVIEW"]

/// `make test-render`: recorded programs' last screens (Tests/Fixtures/corpus) drawn by the
/// GPU in SF Mono 13 at 2x, compared with the PNGs in Tests/Fixtures/render.
///
/// A channel may differ by 2/255, and at most 0.1% of pixels by more: antialiasing differs a
/// little between GPUs and macOS releases. A missing golden is written and the test fails,
/// so a new one gets looked at before it is committed. These run only when asked
/// (`DEATHRACE_RENDER_GOLDENS=1`), on a Mac with a GPU. With `DEATHRACE_RENDER_PREVIEW=dir`
/// the renders are written to `dir` instead, unchecked: CI keeps them for review.
@MainActor
@Suite(
    .enabled(
        if: (comparingRenders || renderPreviewDirectory != nil) && MTLCreateSystemDefaultDevice() != nil,
        "set DEATHRACE_RENDER_GOLDENS=1 (make test-render) on a Mac with a GPU"))
struct RenderGoldenTests {
    nonisolated static let fixtures: String = {
        var path = #filePath
        while let last = path.last, last != "/" { path.removeLast() }
        return path + "../Fixtures/"
    }()

    nonisolated static let names = ["htop", "vim-syntax", "tmux-split", "less-search", "vttest-colors"]
    /// Where to stop playing a recording, when its last screen is not the telling one: vttest
    /// ends on its menu, so it stops on the color test pattern.
    nonisolated static let stopAt = ["vttest-colors": 7877]
    nonisolated static let tolerance = 2
    nonisolated static let allowedFraction = 0.001

    @Test(arguments: names)
    func screensMatchGoldens(_ name: String) throws {
        let recording = try #require(FileManager.default.contents(atPath: Self.fixtures + "corpus/\(name).bin"))
        let theme = Theme.legendsNeverDie
        let session = ReplaySession(Terminal.Configuration(columns: 80, rows: 24, palette: theme.palette))
        let model = SurfaceModel(session: session)
        let bytes = [UInt8](recording)
        session.feed(Array(bytes[..<min(Self.stopAt[name] ?? bytes.count, bytes.count)]))
        _ = model.drain()

        let fonts = FontSet(family: "SF Mono", size: 13)
        let cell = fonts.cellMetrics(scale: 2)
        let glyphs = GlyphCache(rasterizer: GlyphRasterizer(fonts: fonts, cell: cell, language: "en"))
        let built = FrameBuilder().buildComplete(
            mirror: model.mirror, theme: theme, cell: cell, selection: nil, glyphs: glyphs)
        #expect(built.frame.isComplete)
        let layout = PixelLayout(
            width: 80 * cell.width + 32, height: 24 * cell.height + 24, originX: 16, originY: 12)
        let image = try OffscreenRenderer().render(built.frame, cell: cell, layout: layout, glyphs: glyphs)
        let png = try #require(image.pngData())
        if let directory = renderPreviewDirectory {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            return
        }

        let goldenPath = Self.fixtures + "render/\(name).png"
        guard let golden = Self.decode(goldenPath) else {
            try FileManager.default.createDirectory(
                atPath: Self.fixtures + "render", withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: goldenPath))
            Issue.record(
                "\(name): there was no golden, so this render was written to \(goldenPath). Look at it, then commit it."
            )
            return
        }
        try #require(
            golden.width == image.width && golden.height == image.height,
            "\(name): \(image.width)×\(image.height), the golden is \(golden.width)×\(golden.height)")

        var differing = 0
        var first: (x: Int, y: Int)?
        for index in stride(from: 0, to: image.bgra.count, by: 4) {
            let off = (0..<4).contains {
                abs(Int(image.bgra[index + $0]) - Int(golden.bgra[index + $0])) > Self.tolerance
            }
            guard off else { continue }
            differing += 1
            if first == nil { first = ((index / 4) % image.width, (index / 4) / image.width) }
        }
        let allowed = Int(Double(image.width * image.height) * Self.allowedFraction)
        guard differing > allowed, let first else { return }
        let actualPath = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).actual.png")
        try? png.write(to: actualPath)
        Issue.record(
            "\(name): \(differing) pixels differ from the golden (at most \(allowed) may), the first at \(first.x),\(first.y). This render is at \(actualPath.path)."
        )
    }

    /// A PNG's pixels as premultiplied BGRA, top row first, as `RenderedImage` holds them.
    static func decode(_ path: String) -> (width: Int, height: Int, bgra: [UInt8])? {
        guard let data = FileManager.default.contents(atPath: path),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let width = image.width
        let height = image.height
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bgra.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (width, height, bgra) : nil
    }
}
