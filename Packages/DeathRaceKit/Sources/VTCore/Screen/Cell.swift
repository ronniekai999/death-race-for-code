/// How a cell takes part in a character's width.
public enum CellWidth: UInt8, Sendable {
    /// A one-column character, or an empty cell.
    case narrow = 0
    /// The left half of a two-column character.
    case wide = 1
    /// The right half of a two-column character; draws nothing itself.
    case spacerTail = 2
    /// The last column of a row whose next character was too wide to fit and wrapped.
    case spacerHead = 3
}

/// One grid cell in 8 bytes.
///
/// `content` packs the character and its flags:
///
///     bits 0...20   the Unicode scalar (0 = empty)
///     bit  21       more scalars follow in the row's grapheme table (combining marks, ZWJ…)
///     bits 22...23  CellWidth
///     bit  24       protected from selective erase (DECSCA)
///     bit  25       part of a hyperlink (OSC 8)
///
/// `styleID` indexes the owning row's style table; 0 is always the default style.
public struct Cell: Equatable, Sendable {
    public var content: UInt32
    public var styleID: UInt16
    public var reserved: UInt16

    @usableFromInline static let scalarMask: UInt32 = 0x1F_FFFF
    @usableFromInline static let graphemeBit: UInt32 = 1 << 21
    @usableFromInline static let widthShift: UInt32 = 22
    @usableFromInline static let widthMask: UInt32 = 0b11 << 22
    @usableFromInline static let protectedBit: UInt32 = 1 << 24
    @usableFromInline static let hyperlinkBit: UInt32 = 1 << 25

    @inlinable
    public init(content: UInt32 = 0, styleID: UInt16 = 0) {
        self.content = content
        self.styleID = styleID
        self.reserved = 0
    }

    @inlinable
    public init(scalar: UInt32, width: CellWidth = .narrow, styleID: UInt16, protected: Bool = false) {
        var content = scalar & Self.scalarMask | UInt32(width.rawValue) << Self.widthShift
        if protected { content |= Self.protectedBit }
        self.init(content: content, styleID: styleID)
    }

    public static let empty = Cell()

    @inlinable
    public var scalar: UInt32 {
        get { content & Self.scalarMask }
        set { content = content & ~Self.scalarMask | newValue & Self.scalarMask }
    }

    @inlinable
    public var width: CellWidth {
        get { CellWidth(rawValue: UInt8((content & Self.widthMask) >> Self.widthShift)) ?? .narrow }
        set { content = content & ~Self.widthMask | UInt32(newValue.rawValue) << Self.widthShift }
    }

    @inlinable
    public var hasGrapheme: Bool {
        get { content & Self.graphemeBit != 0 }
        set { content = newValue ? content | Self.graphemeBit : content & ~Self.graphemeBit }
    }

    @inlinable
    public var isProtected: Bool {
        get { content & Self.protectedBit != 0 }
        set { content = newValue ? content | Self.protectedBit : content & ~Self.protectedBit }
    }

    /// No character: what erase leaves behind (it may still carry a background color).
    @inlinable
    public var isEmpty: Bool { content & (Self.scalarMask | Self.graphemeBit) == 0 }

    /// An empty cell in the given style.
    @inlinable
    public static func blank(styleID: UInt16) -> Cell {
        Cell(content: 0, styleID: styleID)
    }
}
