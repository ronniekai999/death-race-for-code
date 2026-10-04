/// What a cell's glyph is: its text, the face it is drawn in, and how many cells it spans.
///
/// A single scalar packs into one `UInt64`, which is what nearly every cell has; clusters
/// (combining marks, emoji sequences) keep their scalars.
public struct GlyphKey: Hashable, Sendable {
    /// Bits 0–20 the scalar, 21 bold, 22 italic, 23 two cells wide; 24 set for a cluster,
    /// whose scalars are in `cluster`.
    public let packed: UInt64
    public let cluster: [UInt32]?

    private static let boldBit: UInt64 = 1 << 21
    private static let italicBit: UInt64 = 1 << 22
    private static let wideBit: UInt64 = 1 << 23
    private static let clusterBit: UInt64 = 1 << 24

    public init(scalars: [UInt32], bold: Bool, italic: Bool, wide: Bool) {
        var packed: UInt64 = 0
        if bold { packed |= Self.boldBit }
        if italic { packed |= Self.italicBit }
        if wide { packed |= Self.wideBit }
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

    public var scalars: [UInt32] { cluster ?? [UInt32(packed & 0x1F_FFFF)] }
    public var bold: Bool { packed & Self.boldBit != 0 }
    public var italic: Bool { packed & Self.italicBit != 0 }
    public var isWide: Bool { packed & Self.wideBit != 0 }
    public var cells: Int { isWide ? 2 : 1 }

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
