/// What a cell's glyph is: its text, the face it is drawn in, and how many cells it spans.
///
/// A single scalar packs into one `UInt64`, which is what nearly every cell has; clusters
/// (combining marks, emoji sequences) keep their scalars.
public struct GlyphKey: Hashable, Sendable {
    /// Bits 0–20 the scalar, 21 bold, 22 italic, 23 two cells wide; 24 set for a cluster,
    /// whose scalars are in `cluster`; 25–29 the columns a shaped run covers, less one, and
    /// zero for everything that is not a run. Bits 30 and up are free.
    ///
    /// A run's width is its own bits rather than the wide bit, because the two mean different
    /// things to the rasterizer: `isWide` is a double-width character, which is shrunk to fit
    /// its two cells, while a run keeps the advance the font gives it.
    public let packed: UInt64
    public let cluster: [UInt32]?

    private static let boldBit: UInt64 = 1 << 21
    private static let italicBit: UInt64 = 1 << 22
    private static let wideBit: UInt64 = 1 << 23
    private static let clusterBit: UInt64 = 1 << 24
    private static let runShift: UInt64 = 25
    private static let runWidth: UInt64 = 0x1F

    /// The most columns one shaped run may cover. The five bits hold 32; what a run is actually
    /// allowed to cover is `RunScanner`'s cap, which is smaller and derived from the cell size.
    public static let maxRunCells = 32

    /// The widest bitmap a rasterizer will draw, in pixels.
    ///
    /// It lives here because two places need it and they are in different modules: the
    /// rasterizer refuses anything wider, and `RunScanner` has to cap a run's columns so that
    /// it never asks. Re-typing the number in both would be a silent trap, since a refusal is
    /// cached and means "draws nothing" — raise it in one place only and over-long runs turn
    /// into blank space and stay blank.
    public static let maxRunPixels = 1024

    /// `runCells` is 0 for anything that is not a run, which packs bit-for-bit as it did before
    /// runs existed — so a frame built without shaping is identical, not merely similar.
    public init(scalars: [UInt32], bold: Bool, italic: Bool, wide: Bool, runCells: Int = 0) {
        var packed: UInt64 = 0
        if bold { packed |= Self.boldBit }
        if italic { packed |= Self.italicBit }
        if wide { packed |= Self.wideBit }
        if runCells >= 2 {
            // A run is one-column characters shaped together, so it is never also wide.
            packed &= ~Self.wideBit
            packed |= UInt64(min(runCells, Self.maxRunCells) - 1) << Self.runShift
        }
        if scalars.count == 1 {
            packed |= UInt64(scalars[0] & 0x1F_FFFF)
            cluster = nil
        } else {
            packed |= Self.clusterBit
            cluster = scalars
        }
        self.packed = packed
    }

    public init(scalar: UInt32, bold: Bool = false, italic: Bool = false, wide: Bool = false) {
        self.init(scalars: [scalar], bold: bold, italic: italic, wide: wide)
    }

    /// A run of one-column characters the font draws as one glyph: `!=`, `=>`, `===`.
    public init(run scalars: [UInt32], bold: Bool, italic: Bool) {
        self.init(scalars: scalars, bold: bold, italic: italic, wide: false, runCells: scalars.count)
    }

    public var scalars: [UInt32] { cluster ?? [UInt32(packed & 0x1F_FFFF)] }
    public var bold: Bool { packed & Self.boldBit != 0 }
    public var italic: Bool { packed & Self.italicBit != 0 }
    public var isWide: Bool { packed & Self.wideBit != 0 }
    public var isRun: Bool { (packed >> Self.runShift) & Self.runWidth != 0 }
    public var cells: Int {
        let run = (packed >> Self.runShift) & Self.runWidth
        return run != 0 ? Int(run) + 1 : (isWide ? 2 : 1)
    }

    /// The text, for shaping.
    public var string: String {
        var out = ""
        for scalar in scalars { out.unicodeScalars.append(Unicode.Scalar(scalar) ?? "\u{FFFD}") }
        return out
    }
}

/// Which atlas a glyph lives in: coverage for text, drawn in the cell's color, or full color
/// for emoji and other color glyphs.
public enum AtlasKind: UInt8, Sendable {
    case mask = 0
    case color = 1
}

/// Where a rasterized glyph is and how it sits on its cell, in device pixels.
public struct GlyphPlacement: Sendable, Equatable {
    public var atlas: AtlasKind
    /// The bitmap's corner in the atlas, and its size. Empty for glyphs that draw nothing
    /// (a space).
    public var x: UInt16
    public var y: UInt16
    public var width: UInt16
    public var height: UInt16
    /// The bitmap's top-left corner relative to the cell's top-left; glyphs may overhang
    /// their cell.
    public var offsetX: Int16
    public var offsetY: Int16
    /// The atlas shelf it is on, for keeping shelves that are in use.
    public var shelf: UInt16

    public init(
        atlas: AtlasKind, x: UInt16, y: UInt16, width: UInt16, height: UInt16, offsetX: Int16, offsetY: Int16,
        shelf: UInt16
    ) {
        self.atlas = atlas
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.shelf = shelf
    }

    /// A glyph with nothing to draw.
    public static let empty = GlyphPlacement(
        atlas: .mask, x: 0, y: 0, width: 0, height: 0, offsetX: 0, offsetY: 0, shelf: 0)

    public var isEmpty: Bool { width == 0 || height == 0 }
}

/// Rasterizes glyphs and keeps them in atlases; RenderKit's glyph cache on macOS, a fake in
/// tests.
public protocol GlyphSource: AnyObject {
    /// The glyph's placement, rasterizing it if needed. Nil when it is not ready: the time
    /// budget for this frame is spent or the atlas is full, so the cell draws its background
    /// only and its row stays dirty for the next frame.
    func placement(for key: GlyphKey) -> GlyphPlacement?
    /// Changes whenever placements handed out earlier may have become wrong (an atlas shelf
    /// was reused): every row must look its glyphs up again.
    var epoch: UInt64 { get }
    /// The shelves the frame being built draws from, so they are not reused while visible.
    func markUsed(shelves: [UInt16])
}
