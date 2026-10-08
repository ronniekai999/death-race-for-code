import VTCore

/// A theme: the terminal's colors and the window's around them.
public struct NamedTheme: Sendable, Equatable, Identifiable {
    /// What `theme =` takes: `legends-never-die`, `lucid-dreams`…
    public let id: String
    /// The Juice WRLD title it is named after.
    public let name: String
    /// Dark text on white, with a light window (Righteous).
    public let isLight: Bool
    public let terminal: Theme
    public let chrome: ChromeColors

    /// Stars behind the panes and in the terminal's empty space; light themes have none.
    public var hasStars: Bool { !isLight }

    /// Whether a bright colour throws light around its own character here, which light themes
    /// cannot do — and the reason is mechanical rather than a matter of taste.
    ///
    /// The glow is light *added* to the frame. Righteous is dark text on white, so adding light
    /// around a dark glyph brightens white: invisible at best, and at worst it eats the
    /// antialiased edge that gives the letter its shape. Its palette also sits entirely at a
    /// brightness of 0.32 to 0.45, straddling the rule's own floor, so half of it would glow
    /// arbitrarily — `GlowTests` records that as seven of its sixteen entries landing in the
    /// faint middle, against none to three in any dark theme.
    public var hasGlow: Bool { !isLight }
}

/// The window's colors around the terminal: the design system's tokens, per theme. Legends
/// Never Die's are exactly LegendsUI's Midnight tokens, the look shared with MenuGlance.
public struct ChromeColors: Sendable, Equatable {
    /// The window behind the panes.
    public var ground: RGB
    /// The title bar and status bar.
    public var groundDeep: RGB
    /// Raised things: cards, the palette, Settings' rows.
    public var surface: RGB
    public var surfaceHover: RGB
    /// Borders.
    public var line: RGB
    /// Borders that need to be seen: key caps, controls.
    public var lineStrong: RGB
    /// Text: primary, secondary, tertiary. Each holds 4.5:1 on every ground and surface.
    public var ink: RGB
    public var inkMuted: RGB
    public var inkFaint: RGB
    /// Five stops, left to right: the active tab pill, the 999 personal bests.
    public var gradient: [RGB]
    /// Three stops: the focused pane's border, the 999 wordmark, the equalizer.
    public var neon: [RGB]
    /// Text on the gradient and on accent fills.
    public var onAccent: RGB
    /// Branch names, status dots, links in the chrome.
    public var accent: RGB
    /// The halo around the focused pane.
    public var glow: RGB
    public var glowOpacity: Double
    public var danger: RGB
    public var warning: RGB

    /// Armed and Dangerous: each armed pane's border, orange to pink, as on the board.
    public var armed: [RGB] { [warning, danger] }
    /// Armed and Dangerous's banner: the ground tinted toward each end of the border.
    public var armedTint: [RGB] { armed.map { ground.mixed(with: $0, by: 0.16) } }

    init(
        ground: UInt32, groundDeep: UInt32, surface: UInt32, surfaceHover: UInt32, line: UInt32,
        lineStrong: UInt32, ink: UInt32, inkMuted: UInt32, inkFaint: UInt32, gradient: [UInt32],
        neon: [UInt32], onAccent: UInt32, accent: UInt32, glow: UInt32, glowOpacity: Double, danger: UInt32,
        warning: UInt32
    ) {
        self.ground = RGB(hex: ground)
        self.groundDeep = RGB(hex: groundDeep)
        self.surface = RGB(hex: surface)
        self.surfaceHover = RGB(hex: surfaceHover)
        self.line = RGB(hex: line)
        self.lineStrong = RGB(hex: lineStrong)
        self.ink = RGB(hex: ink)
        self.inkMuted = RGB(hex: inkMuted)
        self.inkFaint = RGB(hex: inkFaint)
        self.gradient = gradient.map { RGB(hex: $0) }
        self.neon = neon.map { RGB(hex: $0) }
        self.onAccent = RGB(hex: onAccent)
        self.accent = RGB(hex: accent)
        self.glow = RGB(hex: glow)
        self.glowOpacity = glowOpacity
        self.danger = RGB(hex: danger)
        self.warning = RGB(hex: warning)
    }
}

/// The eight themes, named after Juice WRLD titles. Original palettes: each starts from the
/// anchors on the mockups' Themes board, and `scripts/gen-themes.py` mixed the rest and
/// nudged them until every text color holds 4.5:1 (ThemeCatalogTests checks the rules).
public enum ThemeCatalog {
    public static let all: [NamedTheme] = [
        legendsNeverDie, lucidDreams, goodbyeGoodRiddance, deathRaceForLove, fightingDemons, wishingWell,
        thePartyNeverEnds, righteous,
    ]

    /// Legends Never Die: MenuGlance's palette.
    public static let `default` = legendsNeverDie

    public static func theme(id: String) -> NamedTheme? {
        all.first { $0.id == id }
    }

    /// The theme an id or a name stands for, ignoring case, spaces and punctuation:
    /// "lucid-dreams", "Lucid Dreams" and "LUCID DREAMS" all find Lucid Dreams.
    public static func theme(named text: some StringProtocol) -> NamedTheme? {
        let wanted = folded(text)
        guard !wanted.isEmpty else { return nil }
        return all.first { folded($0.id) == wanted || folded($0.name) == wanted }
    }

    /// Letters and digits only, lowercased.
    static func folded(_ text: some StringProtocol) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    public static let legendsNeverDie = NamedTheme(
        id: "legends-never-die", name: "Legends Never Die", isLight: false,
        terminal: Theme(
            palette: Palette.themed(
                system: [
                    0x3A2B6A, 0xFF5277, 0x4FE3A9, 0xFFC45C, 0x80A4FC, 0xEC48C4, 0x5CC8FC, 0xC3B5EE,
                    0x7B6BB0, 0xFF7D99, 0x86F0C8, 0xFFD98A, 0xA9C1FF, 0xF37FD8, 0x97DDFF, 0xFFFFFF,
                ],
                foreground: 0xEDE7FF, background: 0x100822, cursor: 0xEC48C4),
            selectionBackground: RGB(hex: 0x463279)),
        chrome: ChromeColors(
            ground: 0x160C2E,
            groundDeep: 0x100822,
            surface: 0x22153F,
            surfaceHover: 0x2C1D4F,
            line: 0x3A2C63,
            lineStrong: 0x6E5FA8,
            ink: 0xFFFFFF,
            inkMuted: 0xC3B5EE,
            inkFaint: 0x9A8CC8,
            gradient: [0xEC48C4, 0xD054D8, 0x9870FC, 0x80A4FC, 0x5CC8FC],
            neon: [0xEC48C4, 0x9870FC, 0x5CC8FC],
            onAccent: 0x1A0C33, accent: 0x5CC8FC,
            glow: 0x9D63FF, glowOpacity: 0.35,
            danger: 0xFF5277, warning: 0xFF8A3D))

    public static let lucidDreams = NamedTheme(
        id: "lucid-dreams", name: "Lucid Dreams", isLight: false,
        terminal: Theme(
            palette: Palette.themed(
                system: [
                    0x463E68, 0xFF8FA3, 0x9FF2D0, 0xFFE29A, 0xA4BCFF, 0xFF9AD5, 0x8FD3FF, 0xC9C0EA,
                    0x867EA9, 0xFFB1BF, 0xBCF6DE, 0xFFEBB8, 0xBFD0FF, 0xFFB8E2, 0xB1E0FF, 0xFFFFFF,
                ],
                foreground: 0xECE8FF, background: 0x141128, cursor: 0xFF9AD5),
            selectionBackground: RGB(hex: 0x564D7E)),
        chrome: ChromeColors(
            ground: 0x1B1832,
            groundDeep: 0x141128,
            surface: 0x292444,
            surfaceHover: 0x363054,
            line: 0x463E68,
            lineStrong: 0x7C70A8,
            ink: 0xFFFFFF,
            inkMuted: 0xC9C0EA,
            inkFaint: 0xA19ABE,
            gradient: [0xFF9AD5, 0xDCA0EA, 0xB9A6FF, 0xA4BCFF, 0x8FD3FF],
            neon: [0xFF9AD5, 0xB9A6FF, 0x8FD3FF],
            onAccent: 0x1E1A35, accent: 0x8FD3FF,
            glow: 0xB9A6FF, glowOpacity: 0.35,
            danger: 0xFF8FA3, warning: 0xFF8A3D))

    public static let goodbyeGoodRiddance = NamedTheme(
        id: "goodbye-good-riddance", name: "Goodbye & Good Riddance", isLight: false,
        terminal: Theme(
            palette: Palette.themed(
                system: [
                    0x3E3E42, 0xFF3B4F, 0xD6D6DC, 0x9E9EA8, 0xA1A1AA, 0xFFFFFF, 0x8A8A94, 0xCCCCCE,
                    0x848488, 0xFF7684, 0xE2E2E6, 0xBBBBC2, 0xBDBDC4, 0xFFFFFF, 0xADADB4, 0xFFFFFF,
                ],
                foreground: 0xF2F2F4, background: 0x0A0A0C, cursor: 0xFFFFFF),
            selectionBackground: RGB(hex: 0x505054)),
        chrome: ChromeColors(
            ground: 0x121214,
            groundDeep: 0x0A0A0C,
            surface: 0x212123,
            surfaceHover: 0x2E2E31,
            line: 0x3E3E42,
            lineStrong: 0x78787C,
            ink: 0xFFFFFF,
            inkMuted: 0xCCCCCE,
            inkFaint: 0xA0A0A3,
            gradient: [0xFFFFFF, 0xDCDCE0, 0xB8B8C0, 0xA1A1AA, 0x8A8A94],
            neon: [0xFFFFFF, 0xB8B8C0, 0x8A8A94],
            onAccent: 0x141417, accent: 0x8A8A94,
            glow: 0xFFFFFF, glowOpacity: 0.12,
            danger: 0xFF3B4F, warning: 0xFF8A3D))

    public static let deathRaceForLove = NamedTheme(
        id: "death-race-for-love", name: "Death Race for Love", isLight: false,
        terminal: Theme(
            palette: Palette.themed(
                system: [
                    0x5A1619, 0xFF3D3D, 0x7CF29A, 0xFFE066, 0x4DA3FF, 0xFF5FA8, 0x64CACC, 0xE8A7A4,
                    0xA15C5C, 0xFF7777, 0xA3F6B8, 0xFFE994, 0x82BFFF, 0xFF8FC2, 0x92DADB, 0xFFFFFF,
                ],
                foreground: 0xFFEEE8, background: 0x14060A, cursor: 0xFF3D3D),
            selectionBackground: RGB(hex: 0x721C1E)),
        chrome: ChromeColors(
            ground: 0x1F080C,
            groundDeep: 0x14060A,
            surface: 0x330D11,
            surfaceHover: 0x441114,
            line: 0x5A1619,
            lineStrong: 0xA33E3F,
            ink: 0xFFFFFF,
            inkMuted: 0xE8A7A4,
            inkFaint: 0xB88382,
            gradient: [0xFF3D3D, 0xFF7735, 0xFFB02E, 0xFFC84A, 0xFFE066],
            neon: [0xFF3D3D, 0xFFB02E, 0xFFE066],
            onAccent: 0x22090D, accent: 0xFFB02E,
            glow: 0xFF3D3D, glowOpacity: 0.3,
            danger: 0xFF3D3D, warning: 0xFF8A3D))

    public static let fightingDemons = NamedTheme(
        id: "fighting-demons", name: "Fighting Demons", isLight: false,
        terminal: Theme(
            palette: Palette.themed(
                system: [
                    0x204E40, 0xFF4060, 0x3DFF8F, 0xE8D36A, 0x6FB7E8, 0xE07BC8, 0x59D6B5, 0xA5D6C5,
                    0x619281, 0xFF7990, 0x77FFB1, 0xEFE097, 0x9ACDEF, 0xE9A3D8, 0x8BE2CB, 0xFFFFFF,
                ],
                foreground: 0xDEF5E8, background: 0x08130E, cursor: 0x3DFF8F),
            selectionBackground: RGB(hex: 0x286151)),
        chrome: ChromeColors(
            ground: 0x0C1C16,
            groundDeep: 0x08130E,
            surface: 0x132C24,
            surfaceHover: 0x193B30,
            line: 0x204E40,
            lineStrong: 0x468A77,
            ink: 0xFFFFFF,
            inkMuted: 0xA5D6C5,
            inkFaint: 0x82AB9C,
            gradient: [0x3DFF8F, 0x4BEAA2, 0x59D6B5, 0x7CDF92, 0x9FE870],
            neon: [0x3DFF8F, 0x59D6B5, 0x9FE870],
            onAccent: 0x0D1F18, accent: 0x9FE870,
            glow: 0x3DFF8F, glowOpacity: 0.25,
            danger: 0xFF4060, warning: 0xFF8A3D))

    public static let wishingWell = NamedTheme(
        id: "wishing-well", name: "Wishing Well", isLight: false,
        terminal: Theme(
            palette: Palette.themed(
                system: [
                    0x29426A, 0xFF6B81, 0x2EE6C5, 0xFFCF5C, 0x7AA8FF, 0xD98CFF, 0x3FD0FF, 0xAFC7EA,
                    0x6B84AA, 0xFF97A7, 0x6DEED6, 0xFFDD8D, 0xA2C2FF, 0xE4AEFF, 0xB8F0FF, 0xFFFFFF,
                ],
                foreground: 0xE1F1FF, background: 0x06172A, cursor: 0x3FD0FF),
            selectionBackground: RGB(hex: 0x34517F)),
        chrome: ChromeColors(
            ground: 0x0B1E34,
            groundDeep: 0x06172A,
            surface: 0x152A46,
            surfaceHover: 0x1E3556,
            line: 0x29426A,
            lineStrong: 0x5675A9,
            ink: 0xFFFFFF,
            inkMuted: 0xAFC7EA,
            inkFaint: 0x8AA0BF,
            gradient: [0x3FD0FF, 0x5CBCFF, 0x7AA8FF, 0x54C7E2, 0x2EE6C5],
            neon: [0x3FD0FF, 0x7AA8FF, 0x2EE6C5],
            onAccent: 0x0D2037, accent: 0x2EE6C5,
            glow: 0x3FD0FF, glowOpacity: 0.3,
            danger: 0xFF6B81, warning: 0xFF8A3D))

    public static let thePartyNeverEnds = NamedTheme(
        id: "the-party-never-ends", name: "The Party Never Ends", isLight: false,
        terminal: Theme(
            palette: Palette.themed(
                system: [
                    0x591056, 0xFF3F6E, 0xB6FF3A, 0xFFE14D, 0x6F8BFF, 0xFF2FD6, 0x2FF3FF, 0xE7A6DE,
                    0xA05899, 0xFF799A, 0xCCFF75, 0xFFEA82, 0x9AAEFF, 0xFF6DE2, 0x6DF7FF, 0xFFFFFF,
                ],
                foreground: 0xFFF2FF, background: 0x12031F, cursor: 0xFF2FD6),
            selectionBackground: RGB(hex: 0x711568)),
        chrome: ChromeColors(
            ground: 0x1D0527,
            groundDeep: 0x12031F,
            surface: 0x310937,
            surfaceHover: 0x430C45,
            line: 0x591056,
            lineStrong: 0xA03291,
            ink: 0xFFFFFF,
            inkMuted: 0xE7A6DE,
            inkFaint: 0xB882B3,
            gradient: [0xFF2FD6, 0x9791EA, 0x2FF3FF, 0x72F99C, 0xB6FF3A],
            neon: [0xFF2FD6, 0x2FF3FF, 0xB6FF3A],
            onAccent: 0x20062A, accent: 0xB6FF3A,
            glow: 0xFF2FD6, glowOpacity: 0.35,
            danger: 0xFF3F6E, warning: 0xFF8A1F))

    public static let righteous = NamedTheme(
        id: "righteous", name: "Righteous", isLight: true,
        terminal: Theme(
            palette: Palette.themed(
                system: [
                    0x2B1F4D, 0xBE1F45, 0x0B7552, 0x8A5600, 0x3757BB, 0xB8259B, 0x0A6E9E, 0xDAD6E9,
                    0x8A849D, 0xC63A5B, 0x288566, 0x986A1F, 0x4F6BC3, 0xC13FA7, 0x277EA8, 0xFFFFFF,
                ],
                foreground: 0x2B1F4D, background: 0xFFFFFF, cursor: 0xB8259B),
            selectionBackground: RGB(hex: 0xE0D9F7)),
        chrome: ChromeColors(
            ground: 0xF9F7FD,
            groundDeep: 0xF4F2FC,
            surface: 0xFFFFFF,
            surfaceHover: 0xF0ECFB,
            line: 0xE0D9F7,
            lineStrong: 0x8B70E2,
            ink: 0x1E1636,
            inkMuted: 0x392770,
            inkFaint: 0x665E7F,
            gradient: [0xB8259B, 0x8E32BA, 0x6440D8, 0x3757BB, 0x0A6E9E],
            neon: [0xB8259B, 0x6440D8, 0x0A6E9E],
            onAccent: 0xFFFFFF, accent: 0x0A6E9E,
            glow: 0x6440D8, glowOpacity: 0.25,
            danger: 0xBE1F45, warning: 0xB54A00))

}

extension Palette {
    /// xterm's 256 colors with a theme's 16 system colors and its default colors.
    static func themed(system: [UInt32], foreground: UInt32, background: UInt32, cursor: UInt32) -> Palette {
        precondition(system.count == 16, "a theme names 16 system colors")
        var palette = Palette.xterm
        for (index, hex) in system.enumerated() { palette.colors[index] = RGB(hex: hex) }
        palette.foreground = RGB(hex: foreground)
        palette.background = RGB(hex: background)
        palette.cursor = RGB(hex: cursor)
        return palette
    }
}
