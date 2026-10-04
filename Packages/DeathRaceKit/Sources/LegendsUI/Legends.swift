import SwiftUI

/// The Legends Never Die design system: the look Death Race for Code shares with MenuGlance.
///
/// Values are the design system's Midnight theme. The brand hues are the exact colors of
/// MenuGlance's 999 icon; surfaces and text are calibrated to its panel. Every text color
/// holds 4.5:1 on `ground`, `groundDeep` and `surface`.
///
/// Computed properties rather than stored ones: SwiftUI's gradient types are not Sendable,
/// and building a Color is cheap.
public enum Legends {
    // Surfaces
    public static var ground: Color { Color(hex: 0x160C2E) }
    public static var groundDeep: Color { Color(hex: 0x100822) }
    public static var surface: Color { Color(hex: 0x22153F) }
    public static var surfaceHover: Color { Color(hex: 0x2C1D4F) }
    public static var line: Color { Color(hex: 0x3A2C63) }
    public static var lineStrong: Color { Color(hex: 0x6E5FA8) }

    // Text
    public static var ink: Color { .white }
    public static var inkMuted: Color { Color(hex: 0xC3B5EE) }
    public static var inkFaint: Color { Color(hex: 0x9A8CC8) }

    // Brand hues, in gradient order
    public static var pink: Color { Color(hex: 0xEC48C4) }
    public static var orchid: Color { Color(hex: 0xD054D8) }
    public static var violet: Color { Color(hex: 0x9870FC) }
    public static var periwinkle: Color { Color(hex: 0x80A4FC) }
    public static var cyan: Color { Color(hex: 0x5CC8FC) }
    public static var plum: Color { Color(hex: 0x681D69) }
    public static var indigo: Color { Color(hex: 0x3C1666) }
    public static var glow: Color { Color(hex: 0x9D63FF) }

    // Signals
    public static var warning: Color { Color(hex: 0xFF8A3D) }
    public static var danger: Color { Color(hex: 0xFF5277) }
    /// Text on pink, cyan or gradient fills. White fails 4.5:1 on pink.
    public static var onAccent: Color { Color(hex: 0x1A0C33) }

    /// Pink → orchid → violet → periwinkle → cyan, left to right.
    public static var gradient: LinearGradient {
        LinearGradient(colors: [pink, orchid, violet, periwinkle, cyan], startPoint: .leading, endPoint: .trailing)
    }

    /// The gradient around a NeonBorder, running from the top-left corner.
    public static var borderGradient: LinearGradient {
        LinearGradient(colors: [pink, violet, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Elevated states: memory pressure, Armed and Dangerous.
    public static var warningGradient: LinearGradient {
        LinearGradient(colors: [warning, pink], startPoint: .leading, endPoint: .trailing)
    }

    public enum Radius {
        public static let tile: CGFloat = 12
        public static let card: CGFloat = 18
        public static let hero: CGFloat = 24
    }
}

extension Color {
    /// An sRGB color from 0xRRGGBB, matching the design system's hex tokens exactly.
    public init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
