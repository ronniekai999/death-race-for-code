/// A color as a program asked for it: the default, one of the 256 palette entries, or 24-bit
/// RGB. Packed into 32 bits: a tag in the top byte, the value below it. Resolving palette
/// entries to actual colors is the renderer's job, so a theme change never rewrites cells.
public struct TerminalColor: Hashable, Sendable {
    public let raw: UInt32

    @inlinable
    init(raw: UInt32) { self.raw = raw }

    public static let `default` = TerminalColor(raw: 0)

    @inlinable
    public static func indexed(_ index: UInt8) -> TerminalColor {
        TerminalColor(raw: 0x0100_0000 | UInt32(index))
    }

    @inlinable
    public static func rgb(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> TerminalColor {
        TerminalColor(raw: 0x0200_0000 | UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue))
    }

    public enum Kind: Equatable, Sendable {
        case `default`
        case indexed(UInt8)
        case rgb(red: UInt8, green: UInt8, blue: UInt8)
    }

    public var kind: Kind {
        switch raw >> 24 {
        case 1: .indexed(UInt8(truncatingIfNeeded: raw))
        case 2:
            .rgb(
                red: UInt8(truncatingIfNeeded: raw >> 16), green: UInt8(truncatingIfNeeded: raw >> 8),
                blue: UInt8(truncatingIfNeeded: raw))
        default: .default
        }
    }
}

public enum UnderlineStyle: UInt8, Sendable, Hashable {
    case none, single, double, curly, dotted, dashed
}

public struct TextAttributes: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold = TextAttributes(rawValue: 1 << 0)
    public static let faint = TextAttributes(rawValue: 1 << 1)
    public static let italic = TextAttributes(rawValue: 1 << 2)
    public static let blink = TextAttributes(rawValue: 1 << 3)
    public static let inverse = TextAttributes(rawValue: 1 << 4)
    public static let invisible = TextAttributes(rawValue: 1 << 5)
    public static let strikethrough = TextAttributes(rawValue: 1 << 6)
    public static let overline = TextAttributes(rawValue: 1 << 7)
}

/// Everything SGR can set. 16 bytes; rows intern them, so a cell carries a 16-bit index.
public struct Style: Hashable, Sendable {
    public var foreground: TerminalColor
    public var background: TerminalColor
    public var underlineColor: TerminalColor
    public var attributes: TextAttributes
    public var underline: UnderlineStyle

    public init(
        foreground: TerminalColor = .default,
        background: TerminalColor = .default,
        underlineColor: TerminalColor = .default,
        attributes: TextAttributes = [],
        underline: UnderlineStyle = .none
    ) {
        self.foreground = foreground
        self.background = background
        self.underlineColor = underlineColor
        self.attributes = attributes
        self.underline = underline
    }

    public static let `default` = Style()

    /// What erased cells get: only the background survives ("background color erase", the
    /// `bce` capability xterm-256color advertises).
    @inlinable
    public var erasing: Style {
        background == .default ? .default : Style(background: background)
    }
}
