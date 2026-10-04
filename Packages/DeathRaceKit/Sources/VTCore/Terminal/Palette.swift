public struct RGB: Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(hex: UInt32) {
        self.init(
            UInt8(truncatingIfNeeded: hex >> 16), UInt8(truncatingIfNeeded: hex >> 8), UInt8(truncatingIfNeeded: hex))
    }

    /// The X11 form OSC color queries answer with: `rgb:RRRR/GGGG/BBBB`.
    var x11: String {
        func hex4(_ v: UInt8) -> String {
            let digits = Array("0123456789abcdef")
            let hi = String(digits[Int(v >> 4)]) + String(digits[Int(v & 0xF)])
            return hi + hi
        }
        return "rgb:\(hex4(red))/\(hex4(green))/\(hex4(blue))"
    }

    /// Parses `rgb:R/G/B` (1–4 hex digits each), `#RGB`, `#RRGGBB`, `#RRRGGGBBB` and
    /// `#RRRRGGGGBBBB`, the specifications OSC 4/10/11/12 accept.
    init?(colorSpec: Substring) {
        func scaled(_ digits: Substring) -> UInt8? {
            guard !digits.isEmpty, digits.count <= 4, let value = UInt32(digits, radix: 16) else { return nil }
            let max = (UInt32(1) << (4 * UInt32(digits.count))) - 1
            return UInt8((value * 255 + max / 2) / max)
        }
        if colorSpec.hasPrefix("rgb:") {
            let parts = colorSpec.dropFirst(4).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3, let r = scaled(parts[0]), let g = scaled(parts[1]), let b = scaled(parts[2]) else {
                return nil
            }
            self.init(r, g, b)
        } else if colorSpec.hasPrefix("#") {
            let hex = colorSpec.dropFirst()
            guard hex.count % 3 == 0, hex.count >= 3, hex.count <= 12 else { return nil }
            let n = hex.count / 3
            let start = hex.startIndex
            func part(_ i: Int) -> Substring {
                hex[hex.index(start, offsetBy: i * n)..<hex.index(start, offsetBy: (i + 1) * n)]
            }
            // In X11's #-form the digits are the most significant bits: #F00 is 0xF0, not 0xFF.
            func high(_ digits: Substring) -> UInt8? {
                guard let value = UInt32(digits, radix: 16) else { return nil }
                let bits = 4 * digits.count
                return bits >= 8
                    ? UInt8(truncatingIfNeeded: value >> UInt32(bits - 8))
                    : UInt8(truncatingIfNeeded: value << UInt32(8 - bits))
            }
            guard let r = high(part(0)), let g = high(part(1)), let b = high(part(2)) else { return nil }
            self.init(r, g, b)
        } else {
            return nil
        }
    }
}

/// The 256 indexed colors plus the dynamic foreground, background and cursor colors.
///
/// The app installs its theme as the base; programs may change entries (OSC 4, 10, 11, 12)
/// and reset them (OSC 104, 110, 111, 112) back to that base.
public struct Palette: Sendable, Equatable {
    public var colors: [RGB]
    public var foreground: RGB
    public var background: RGB
    public var cursor: RGB

    public init(colors: [RGB], foreground: RGB, background: RGB, cursor: RGB) {
        precondition(colors.count == 256, "a palette has 256 colors")
        self.colors = colors
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
    }

    /// xterm's defaults: 16 system colors, the 6×6×6 cube, and 24 grays.
    public static let xterm: Palette = {
        let system: [UInt32] = [
            0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
            0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
        ]
        var colors = system.map { RGB(hex: $0) }
        let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
        for r in levels { for g in levels { for b in levels { colors.append(RGB(r, g, b)) } } }
        for i in 0..<24 {
            let v = UInt8(8 + 10 * i)
            colors.append(RGB(v, v, v))
        }
        return Palette(
            colors: colors, foreground: RGB(hex: 0xE5E5E5), background: RGB(hex: 0x000000), cursor: RGB(hex: 0xE5E5E5))
    }()

    /// Legends Never Die, the default theme: MenuGlance's palette with every ANSI color
    /// holding 4.5:1 on the background (black and bright black excepted).
    public static let legendsNeverDie: Palette = {
        var palette = Palette.xterm
        let system: [UInt32] = [
            0x3A2B6A, 0xFF5277, 0x4FE3A9, 0xFFC45C, 0x80A4FC, 0xEC48C4, 0x5CC8FC, 0xC3B5EE,
            0x7B6BB0, 0xFF7D99, 0x86F0C8, 0xFFD98A, 0xA9C1FF, 0xF37FD8, 0x97DDFF, 0xFFFFFF,
        ]
        for (i, hex) in system.enumerated() { palette.colors[i] = RGB(hex: hex) }
        palette.foreground = RGB(hex: 0xEDE7FF)
        palette.background = RGB(hex: 0x100822)
        palette.cursor = RGB(hex: 0xEC48C4)
        return palette
    }()
}
