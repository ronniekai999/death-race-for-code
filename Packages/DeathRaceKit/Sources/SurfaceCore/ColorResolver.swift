import ConfigKit
import VTCore

/// A color as the GPU takes it: sRGB bytes red, green, blue, alpha, red in the lowest byte,
/// which a Metal shader reads as `uchar4` (or unpacks with `unpack_unorm4x8_to_float`).
public typealias PackedColor = UInt32

extension RGB {
    public var packed: PackedColor {
        UInt32(red) | UInt32(green) << 8 | UInt32(blue) << 16 | 0xFF00_0000
    }

    /// Halfway (or `amount` of the way) from this color to `other`, per channel in sRGB.
    public func mixed(with other: RGB, amount: Double = 0.5) -> RGB {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(clamping: Int((Double(a) + (Double(b) - Double(a)) * amount).rounded()))
        }
        return RGB(mix(red, other.red), mix(green, other.green), mix(blue, other.blue))
    }
}

/// A style ready to draw: its colors resolved against the palette and theme, and what to draw
/// with them.
public struct ResolvedStyle: Sendable, Equatable {
    public var foreground: RGB
    public var background: RGB
    public var underlineColor: RGB
    public var bold: Bool
    public var italic: Bool
    public var underline: UnderlineStyle
    public var strikethrough: Bool
    public var overline: Bool
    /// SGR 8: nothing but the background is drawn.
    public var invisible: Bool
}

/// Turns styles into colors, the way xterm does unless the theme says otherwise.
///
/// - Default colors come from the palette's foreground and background; indexed ones from its
///   256 colors; truecolor is used as given.
/// - Inverse (SGR 7) swaps foreground and background, and the whole-screen reverse video mode
///   (DECSCNM) swaps them again, so inverse text stands out on a reversed screen too.
/// - Faint text is halfway to its background. Bold uses the bright versions of colors 0–7
///   only with `bold-is-bright`.
/// - Selected cells take the selection colors; the underline takes the text color unless the
///   program chose one (SGR 58).
public struct ColorResolver: Sendable {
    public var palette: Palette
    public var theme: Theme
    public var reverseVideo: Bool

    public init(palette: Palette, theme: Theme, reverseVideo: Bool = false) {
        self.palette = palette
        self.theme = theme
        self.reverseVideo = reverseVideo
    }

    public func resolve(_ style: Style, selected: Bool = false) -> ResolvedStyle {
        let attributes = style.attributes
        let bold = attributes.contains(.bold)
        var foreground = color(style.foreground, default: palette.foreground, brighten: bold && theme.boldIsBright)
        var background = color(style.background, default: palette.background, brighten: false)
        if attributes.contains(.inverse) != reverseVideo { swap(&foreground, &background) }
        if attributes.contains(.faint) { foreground = foreground.mixed(with: background) }
        var underlineColor =
            style.underlineColor == .default
            ? foreground : color(style.underlineColor, default: foreground, brighten: false)
        if selected {
            background = theme.selectionBackground
            if let selectedText = theme.selectionForeground {
                foreground = selectedText
                underlineColor = selectedText
            }
        }
        return ResolvedStyle(
            foreground: foreground, background: background, underlineColor: underlineColor, bold: bold,
            italic: attributes.contains(.italic), underline: style.underline,
            strikethrough: attributes.contains(.strikethrough), overline: attributes.contains(.overline),
            invisible: attributes.contains(.invisible))
    }

    /// The color behind the grid: the padding around it and any area no row covers.
    public var clearColor: RGB {
        reverseVideo ? palette.foreground : palette.background
    }

    private func color(_ color: TerminalColor, default fallback: RGB, brighten: Bool) -> RGB {
        switch color.kind {
        case .default:
            return fallback
        case .indexed(let index):
            let index = brighten && index < 8 ? index + 8 : index
            return palette.colors[Int(index)]
        case .rgb(let red, let green, let blue):
            return RGB(red, green, blue)
        }
    }
}
