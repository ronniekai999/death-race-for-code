import Testing
import VTCore

@testable import ConfigKit

@Suite struct ThemeCatalogTests {
    /// The anchors on the mockups' Themes board: background, foreground, accents, red.
    static let anchors: [String: [UInt32]] = [
        "legends-never-die": [0x100822, 0xEDE7FF, 0xEC48C4, 0x9870FC, 0x5CC8FC, 0x4FE3A9, 0xFFC45C, 0xFF5277],
        "lucid-dreams": [0x141128, 0xECE8FF, 0xFF9AD5, 0xB9A6FF, 0x8FD3FF, 0x9FF2D0, 0xFFE29A, 0xFF8FA3],
        "goodbye-good-riddance": [0x0A0A0C, 0xF2F2F4, 0xFFFFFF, 0xB8B8C0, 0x8A8A94, 0xD6D6DC, 0x9E9EA8, 0xFF3B4F],
        "death-race-for-love": [0x14060A, 0xFFEEE8, 0xFF3D3D, 0xFFB02E, 0x4DA3FF, 0x7CF29A, 0xFFE066, 0xFF3D3D],
        "fighting-demons": [0x08130E, 0xDEF5E8, 0x3DFF8F, 0x59D6B5, 0x9FE870, 0x59D6B5, 0xE8D36A, 0xFF4060],
        "wishing-well": [0x06172A, 0xE1F1FF, 0x3FD0FF, 0x7AA8FF, 0x2EE6C5, 0xB8F0FF, 0xFFCF5C, 0xFF6B81],
        "the-party-never-ends": [0x12031F, 0xFFF2FF, 0xFF2FD6, 0x2FF3FF, 0xB6FF3A, 0xFF8A1F, 0xFFE14D, 0xFF3F6E],
        "righteous": [0xFFFFFF, 0x2B1F4D, 0xB8259B, 0x6440D8, 0x0A6E9E, 0x0B7552, 0x8A5600, 0xBE1F45],
    ]

    @Test func thereAreEightThemesWithTheMockupsNames() {
        #expect(
            ThemeCatalog.all.map(\.name) == [
                "Legends Never Die", "Lucid Dreams", "Goodbye & Good Riddance", "Death Race for Love",
                "Fighting Demons", "Wishing Well", "The Party Never Ends", "Righteous",
            ])
        #expect(Set(ThemeCatalog.all.map(\.id)).count == 8)
        #expect(ThemeCatalog.all.filter(\.isLight).map(\.id) == ["righteous"])
    }

    @Test func legendsNeverDieIsTodaysPaletteAndTokens() {
        let legends = ThemeCatalog.legendsNeverDie
        #expect(ThemeCatalog.default == legends)
        #expect(legends.terminal == Theme.legendsNeverDie)
        #expect(legends.terminal.palette == Palette.legendsNeverDie)
        // LegendsUI's Midnight tokens.
        #expect(legends.chrome.ground == RGB(hex: 0x160C2E))
        #expect(legends.chrome.groundDeep == RGB(hex: 0x100822))
        #expect(legends.chrome.surface == RGB(hex: 0x22153F))
        #expect(legends.chrome.inkMuted == RGB(hex: 0xC3B5EE))
        #expect(legends.chrome.onAccent == RGB(hex: 0x1A0C33))
        #expect(legends.chrome.gradient.map(\.hex) == [0xEC48C4, 0xD054D8, 0x9870FC, 0x80A4FC, 0x5CC8FC])
    }

    @Test(arguments: ThemeCatalog.all)
    func everyAnchorAppearsExactly(_ theme: NamedTheme) throws {
        let anchors = try #require(Self.anchors[theme.id])
        let palette = theme.terminal.palette
        #expect(palette.background.hex == anchors[0])
        #expect(palette.foreground.hex == anchors[1])
        #expect(palette.cursor.hex == anchors[2])
        #expect(palette.colors[1].hex == anchors[7])
        let chrome = theme.chrome
        let used = Set(
            palette.colors[0..<16].map(\.hex) + (chrome.gradient + [chrome.accent, chrome.warning]).map(\.hex))
        for accent in anchors[2...6] {
            #expect(used.contains(accent), "\(theme.name) leaves out \(String(accent, radix: 16))")
        }
    }

    /// The WCAG 2 ratios each theme must hold, for text and for lines and dots.
    @Test(arguments: ThemeCatalog.all)
    func everyThemeHoldsItsContrast(_ theme: NamedTheme) {
        let chrome = theme.chrome
        let palette = theme.terminal.palette
        func check(_ color: RGB, on backgrounds: [RGB], _ minimum: Double, _ what: String) {
            for background in backgrounds {
                let ratio = color.contrast(with: background)
                #expect(
                    ratio >= minimum,
                    "\(theme.name): \(what) \(color.hexString) on \(background.hexString) is \(ratio), under \(minimum)"
                )
            }
        }
        let grounds = [chrome.ground, chrome.groundDeep, chrome.surface, chrome.surfaceHover]
        check(chrome.ink, on: grounds, 4.5, "ink")
        check(chrome.inkMuted, on: grounds, 4.5, "inkMuted")
        check(chrome.inkFaint, on: grounds, 4.5, "inkFaint")
        check(chrome.onAccent, on: chrome.gradient + chrome.neon, 4.5, "onAccent")
        check(chrome.lineStrong, on: [chrome.ground, chrome.groundDeep], 3, "lineStrong")
        check(chrome.accent, on: [chrome.groundDeep, palette.background], 4.5, "accent")
        check(chrome.danger, on: [chrome.groundDeep], 3, "danger")
        check(chrome.warning, on: [chrome.groundDeep], 3, "warning")

        check(palette.foreground, on: [palette.background], 7, "foreground")
        check(palette.foreground, on: [theme.terminal.selectionBackground], 4.5, "selected text")
        check(palette.cursor, on: [palette.background], 3, "cursor")
        check(theme.terminal.cursorText ?? palette.background, on: [palette.cursor], 4.5, "text under the cursor")
        // Black and bright black are for backgrounds on dark themes, white and bright white
        // on light ones; bright black is the dim gray, and only needs to be seen.
        let readable = [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14] + (theme.isLight ? [0] : [7, 15])
        for index in readable {
            check(palette.colors[index], on: [palette.background], 4.5, "color \(index)")
        }
        check(palette.colors[8], on: [palette.background], 3, "color 8")
    }

    @Test func themesAreFoundByIdOrName() {
        #expect(ThemeCatalog.theme(id: "lucid-dreams")?.name == "Lucid Dreams")
        #expect(ThemeCatalog.theme(id: "Lucid Dreams") == nil)
        #expect(ThemeCatalog.theme(named: "Lucid Dreams")?.id == "lucid-dreams")
        #expect(ThemeCatalog.theme(named: "LUCID-DREAMS")?.id == "lucid-dreams")
        #expect(ThemeCatalog.theme(named: "Goodbye & Good Riddance")?.id == "goodbye-good-riddance")
        #expect(ThemeCatalog.theme(named: "the party never ends")?.id == "the-party-never-ends")
        #expect(ThemeCatalog.theme(named: "") == nil)
        #expect(ThemeCatalog.theme(named: "Legends Never Live") == nil)
    }

    @Test func theThemeLineAppliesWhereverItIs() {
        let before = Config.parse("background = #000000\ntheme = righteous").config
        let after = Config.parse("theme = righteous\nbackground = #000000").config
        #expect(before == after)
        #expect(before.themeID == "righteous")
        #expect(before.namedTheme.isLight)
        #expect(before.theme.palette.background == RGB(hex: 0x000000))
        #expect(before.theme.palette.foreground == ThemeCatalog.righteous.terminal.palette.foreground)
        #expect(before.chrome == ThemeCatalog.righteous.chrome)
        #expect(before.colorOverrides.count == 1)
    }

    @Test func aMisspelledThemeIsReportedWithASuggestion() {
        let (config, diagnostics) = Config.parse("theme = Lucid Dreams")
        #expect(config.themeID == "lucid-dreams")
        #expect(diagnostics.isEmpty)

        let (unknown, problems) = Config.parse("theme = lucid-dremas")
        #expect(unknown.themeID == ThemeCatalog.default.id)
        #expect(
            problems == [
                ConfigDiagnostic(line: 1, message: "“lucid-dremas” does not work for theme. Did you mean lucid-dreams?")
            ])

        let far = Config.parse("theme = solarized").diagnostics
        #expect(far.first?.message.contains("Use legends-never-die, lucid-dreams") == true)
    }

    @Test func theTemplateNamesEveryTheme() {
        let help = ConfigSchema.key(named: "theme")?.help.joined(separator: " ") ?? ""
        for theme in ThemeCatalog.all {
            #expect(help.contains(theme.id), "the theme help leaves out \(theme.id)")
        }
    }

    @Test func colorsAndContrastFollowWCAG() {
        let white = RGB(hex: 0xFFFFFF)
        let black = RGB(hex: 0x000000)
        #expect(abs(white.contrast(with: black) - 21) < 1e-9)
        #expect(white.contrast(with: white) == 1)
        // #767676 is the lightest gray that holds 4.5:1 on white.
        #expect(RGB(hex: 0x767676).contrast(with: white) >= 4.5)
        #expect(RGB(hex: 0x777777).contrast(with: white) < 4.5)
        #expect(black.mixed(with: white, by: 0.5) == RGB(hex: 0x808080))
    }
}

extension NamedTheme: CustomTestStringConvertible {
    public var testDescription: String { name }
}

extension RGB {
    var hex: UInt32 { UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue) }
    var hexString: String { "#" + String(hex, radix: 16, uppercase: true) }
}
