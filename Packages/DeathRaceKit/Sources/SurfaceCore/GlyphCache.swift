import ConfigKit
import ScreenProtocol

/// A glyph's bitmap, ready to go into an atlas.
public struct RasterizedGlyph: Sendable, Equatable {
    public var atlas: AtlasKind
    public var width: Int
    public var height: Int
    /// The bitmap's top-left corner relative to its cell's, in pixels.
    public var offsetX: Int
    public var offsetY: Int
    /// Coverage, one byte a pixel (mask), or premultiplied BGRA (color); top row first.
    public var pixels: [UInt8]

    public init(atlas: AtlasKind, width: Int, height: Int, offsetX: Int, offsetY: Int, pixels: [UInt8]) {
        self.atlas = atlas
        self.width = width
        self.height = height
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.pixels = pixels
    }

    public static let empty = RasterizedGlyph(atlas: .mask, width: 0, height: 0, offsetX: 0, offsetY: 0, pixels: [])

    public var isEmpty: Bool { width == 0 || height == 0 }
}

/// Draws a glyph: CoreText in RenderKit; fakes in tests.
public protocol GlyphRasterizing {
    func rasterize(_ key: GlyphKey) -> RasterizedGlyph
}

/// An atlas's pixels on the CPU, which the renderer copies to its texture: the rows changed
/// since the last copy, or all of it after the atlas grew.
public final class AtlasPixels {
    public let kind: AtlasKind
    public let bytesPerPixel: Int
    public private(set) var packer: ShelfAtlas
    public private(set) var pixels: [UInt8]
    /// Rows written since `takeDirtyRows()`.
    public private(set) var dirtyRows: Range<Int>?
    /// Bumped each time the atlas grows: the texture has to be made again at the new size.
    public private(set) var sizeGeneration = 0

    public init(kind: AtlasKind, size: Int, maxSize: Int) {
        self.kind = kind
        bytesPerPixel = kind == .color ? 4 : 1
        packer = ShelfAtlas(size: size, maxSize: maxSize)
        pixels = [UInt8](repeating: 0, count: size * size * bytesPerPixel)
    }

    public var size: Int { packer.size }

    /// Room for a glyph.
    func allocate(width: Int, height: Int, frame: UInt64) -> ShelfAtlas.Outcome {
        let oldSize = packer.size
        let outcome = packer.allocate(width: width, height: height, frame: frame)
        if packer.size != oldSize { grow(from: oldSize) }
        return outcome
    }

    func markUsed(shelf: Int, frame: UInt64) {
        packer.markUsed(shelf: shelf, frame: frame)
    }

    /// Copies a bitmap in at `(x, y)`.
    func write(_ glyph: RasterizedGlyph, x: Int, y: Int) {
        let rowBytes = glyph.width * bytesPerPixel
        let atlasRowBytes = size * bytesPerPixel
        guard glyph.pixels.count >= rowBytes * glyph.height else { return }
        for row in 0..<glyph.height {
            let source = row * rowBytes
            let destination = (y + row) * atlasRowBytes + x * bytesPerPixel
            pixels.replaceSubrange(
                destination..<(destination + rowBytes), with: glyph.pixels[source..<(source + rowBytes)])
        }
        let rows = y..<(y + glyph.height)
        dirtyRows = dirtyRows.map { min($0.lowerBound, rows.lowerBound)..<max($0.upperBound, rows.upperBound) } ?? rows
    }

    /// The rows to copy to the texture, which are then clean.
    public func takeDirtyRows() -> Range<Int>? {
        defer { dirtyRows = nil }
        return dirtyRows
    }

    /// The pixels move into a larger square, keeping their places.
    private func grow(from oldSize: Int) {
        var grown = [UInt8](repeating: 0, count: size * size * bytesPerPixel)
        let oldRowBytes = oldSize * bytesPerPixel
        let newRowBytes = size * bytesPerPixel
        for row in 0..<oldSize {
            grown.replaceSubrange(
                (row * newRowBytes)..<(row * newRowBytes + oldRowBytes),
                with: pixels[(row * oldRowBytes)..<((row + 1) * oldRowBytes)])
        }
        pixels = grown
        sizeGeneration += 1
        dirtyRows = 0..<size
    }
}

/// The glyphs of one font set at one cell size: rasterized on first use, kept in a coverage
/// atlas and a color atlas, and handed to the frame builder as placements.
///
/// Rasterizing has a budget per frame, so a screenful of new glyphs (a first frame, a font
/// change, a page of CJK) spreads over a few frames instead of stalling one: glyphs past the
/// budget come back nil, their cells draw only backgrounds, and the rows stay dirty.
public final class GlyphCache: GlyphSource {
    public let mask: AtlasPixels
    public let color: AtlasPixels
    public private(set) var epoch: UInt64 = 0
    private let rasterizer: any GlyphRasterizing
    private var placements: [GlyphKey: GlyphPlacement] = [:]
    /// Which glyphs sit on each shelf, so a reused shelf forgets them.
    private var shelfKeys: [AtlasKind: [Int: [GlyphKey]]] = [.mask: [:], .color: [:]]
    private var frame: UInt64 = 0
    private var frameStart = ContinuousClock.now
    /// How long rasterizing may take in one frame.
    public var budget: Duration
    public private(set) var rasterizedThisFrame = 0

    /// Shelf numbers in placements carry their atlas in the top bit.
    static let colorShelfBit: UInt16 = 0x8000

    public init(
        rasterizer: any GlyphRasterizing, budget: Duration = .milliseconds(2), maskSize: Int = 1024,
        maskMaxSize: Int = 4096, colorSize: Int = 512, colorMaxSize: Int = 2048
    ) {
        self.rasterizer = rasterizer
        self.budget = budget
        mask = AtlasPixels(kind: .mask, size: maskSize, maxSize: maskMaxSize)
        color = AtlasPixels(kind: .color, size: colorSize, maxSize: colorMaxSize)
    }

    /// A new frame: the rasterizing budget starts again.
    public func beginFrame() {
        frame &+= 1
        frameStart = ContinuousClock.now
        rasterizedThisFrame = 0
    }

    public func placement(for key: GlyphKey) -> GlyphPlacement? {
        if let known = placements[key] { return known }
        // The first glyph of a frame is always drawn, so every frame makes progress.
        if rasterizedThisFrame > 0, ContinuousClock.now - frameStart > budget { return nil }
        let glyph = rasterizer.rasterize(key)
        rasterizedThisFrame += 1
        guard !glyph.isEmpty else {
            placements[key] = .empty
            return .empty
        }
        let atlas = glyph.atlas == .color ? color : mask
        let slot: ShelfAtlas.Slot
        switch atlas.allocate(width: glyph.width, height: glyph.height, frame: frame) {
        case .placed(let placed), .grew(let placed, _):
            slot = placed
        case .reused(let placed, let evicted):
            forget(shelf: evicted, in: glyph.atlas)
            slot = placed
        case .full:
            return nil
        }
        atlas.write(glyph, x: slot.x, y: slot.y)
        let placement = GlyphPlacement(
            atlas: glyph.atlas, x: UInt16(slot.x), y: UInt16(slot.y), width: UInt16(glyph.width),
            height: UInt16(glyph.height), offsetX: Int16(clamping: glyph.offsetX),
            offsetY: Int16(clamping: glyph.offsetY),
            shelf: UInt16(slot.shelf) | (glyph.atlas == .color ? Self.colorShelfBit : 0))
        placements[key] = placement
        shelfKeys[glyph.atlas, default: [:]][slot.shelf, default: []].append(key)
        return placement
    }

    public func markUsed(shelves: [UInt16]) {
        for shelf in shelves {
            let atlas = shelf & Self.colorShelfBit != 0 ? color : mask
            atlas.markUsed(shelf: Int(shelf & ~Self.colorShelfBit), frame: frame)
        }
    }

    /// A shelf was reused: the glyphs on it are gone, and every row must look its glyphs up
    /// again.
    private func forget(shelf: Int, in kind: AtlasKind) {
        for key in shelfKeys[kind]?[shelf] ?? [] { placements[key] = nil }
        shelfKeys[kind]?[shelf] = []
        epoch &+= 1
    }
}

extension FrameBuilder {
    /// Builds frames until every glyph is in, as a view does over its first few ticks, and
    /// says how many it took: for tools and tests that need the whole frame at once.
    public func buildComplete(
        mirror: MirrorGrid, theme: Theme, cell: CellMetrics, selection: TextRegion?, glyphs: GlyphCache,
        preedit: PreeditLayout? = nil, starfield: Bool = false, link: LinkHit? = nil, maxFrames: Int = 1_000
    ) -> (frame: Frame, frames: Int) {
        var frames = 0
        while true {
            // Each pass is a frame: the glyph cache's rasterizing budget starts again.
            glyphs.beginFrame()
            let frame = build(
                mirror: mirror, theme: theme, cell: cell, selection: selection, glyphs: glyphs, preedit: preedit,
                starfield: starfield, link: link)
            frames += 1
            if frame.isComplete || frames >= maxFrames { return (frame, frames) }
        }
    }
}
