import ConfigKit
import Testing
import VTCore

@testable import SurfaceCore

/// Bitmaps of a chosen size, fully covered, so a test can decide what goes into the atlas and in
/// what order. CoreText draws whatever CoreText draws, which is the wrong tool for a question
/// about atlas neighbours.
private final class SolidBitmaps: GlyphRasterizing {
    /// Scalar to (width, height).
    let shapes: [UInt32: (Int, Int)]

    init(shapes: [UInt32: (Int, Int)]) {
        self.shapes = shapes
    }

    func rasterize(_ key: GlyphKey) -> RasterizedGlyph {
        guard let scalar = key.scalars.first, let (width, height) = shapes[scalar] else { return .empty }
        return RasterizedGlyph(
            atlas: .mask, width: width, height: height, offsetX: 2, offsetY: 5,
            pixels: [UInt8](repeating: 0xFF, count: width * height))
    }
}

@Suite struct GlowTests {
    @Test func theStrengthRidesInTheAlphaByte() {
        let glow = Glow(strength: 0.14, tint: RGB(0x10, 0x20, 0x30))
        #expect(glow.packed == 0x2430_2010)
        #expect(Glow(strength: 2).packed >> 24 == 0xFF)
        #expect(Glow(strength: -1).packed == 0)
    }

    /// The renderer skips the glow draw on `glow == 0`, so "off" has to be exactly one value: a
    /// tint with no strength must not look like a glow to be drawn.
    @Test func offIsExactlyZeroWhateverTheTint() {
        #expect(Glow.none.packed == 0)
        #expect(Glow.none.isOff)
        #expect(Glow(strength: 0, tint: RGB(0xFF, 0xFF, 0xFF)).packed == 0)
        #expect(Glow(strength: 0.001, tint: RGB(0xFF, 0xFF, 0xFF)).packed == 0)
        #expect(!Glow(strength: 0.01).isOff)
    }

    // MARK: - The rule

    /// The three invariants the feature promises, across every theme at once: ordinary output
    /// never glows, and neither does white or black however the rest is tuned.
    @Test func ordinaryTextNeverGlowsInAnyTheme() {
        for theme in ThemeCatalog.all {
            let palette = theme.terminal.palette
            #expect(
                Glow.emissiveStrength(of: palette.foreground) == 0,
                "\(theme.id)'s default foreground glows, so every line of output would")
            #expect(Glow.emissiveStrength(of: palette.colors[15]) == 0, "\(theme.id)'s white glows")
            #expect(Glow.emissiveStrength(of: palette.colors[0]) == 0, "\(theme.id)'s black glows")
        }
    }

    /// The tightest margin in the rule, and the reason chroma's floor sits where it does:
    /// `ESC[37m` and `ESC[90m` are ordinary output, and the themes put them at chroma up to 0.28
    /// — close enough to a pastel bright magenta's 0.275 that no threshold separates them. The
    /// greys get the benefit of the doubt.
    @Test func theGreysAreSilentInEveryTheme() {
        for theme in ThemeCatalog.all {
            for index in [7, 8] {
                let strength = Glow.emissiveStrength(of: theme.terminal.palette.colors[index])
                #expect(strength <= 0.001, "\(theme.id)'s palette[\(index)] glows at \(strength)")
            }
        }
        // The one grey in all eight themes that is not *exactly* zero, pinned rather than hidden
        // behind the tolerance above: The Party Never Ends' bright black is the most saturated
        // grey anyone shipped, at chroma 0.282 against a floor of 0.28. Six ten-thousandths of a
        // glow, which at a theme's strongest 0.35 is 0.0002 of light — but it is not nothing, and
        // if a retune lowers the floor this is the entry that moves first.
        let party = ThemeCatalog.thePartyNeverEnds.terminal.palette.colors[8]
        let leak = Glow.emissiveStrength(of: party)
        #expect(leak > 0 && leak < 0.001, "the worst grey is now \(leak)")
    }

    /// What the four thresholds actually do to all eight palettes, recorded rather than
    /// described. This is the table a retune has to update, and the only place the Swift rule and
    /// its Metal twin can be compared against anything: the numbers below were read off this
    /// implementation, so a change here that is not mirrored in `Shaders.source` shows up as a
    /// table that no longer matches what the Mac draws.
    ///
    /// `glowing` is at or above half strength and `silent` is at or below a thousandth — nothing
    /// a person could see. Whatever is in neither list is the deliberate faint middle
    /// `smoothstep` exists for. The entries that must be *exactly* zero, every theme's default
    /// foreground and its white and black, are pinned above instead.
    @Test(arguments: [
        ("legends-never-die", [1, 2, 3, 4, 5, 6, 9, 10, 11, 13, 14], [0, 7, 8, 15]),
        ("lucid-dreams", [1, 3, 5, 6], [0, 7, 8, 10, 11, 12, 13, 15]),
        ("goodbye-good-riddance", [1, 9], [0, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15]),
        ("death-race-for-love", [1, 2, 3, 4, 5, 6, 9, 11, 12, 13], [0, 7, 8, 15]),
        ("fighting-demons", [1, 2, 3, 4, 5, 6, 9, 10], [0, 7, 8, 13, 15]),
        ("wishing-well", [1, 2, 3, 4, 5, 6, 9, 10, 11, 12], [0, 7, 8, 14, 15]),
        ("the-party-never-ends", [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14], [0, 7, 8, 15]),
        ("righteous", [9, 11, 12, 13, 14], [0, 7, 8, 15]),
    ])
    func eachThemeGlowsWhereItsTableSays(id: String, glowing: [Int], silent: [Int]) throws {
        let theme = try #require(ThemeCatalog.theme(id: id))
        for index in glowing {
            let strength = Glow.emissiveStrength(of: theme.terminal.palette.colors[index])
            #expect(strength >= 0.5, "\(id)'s palette[\(index)] should glow and is \(strength)")
        }
        for index in silent {
            let strength = Glow.emissiveStrength(of: theme.terminal.palette.colors[index])
            #expect(strength <= 0.001, "\(id)'s palette[\(index)] should be silent and is \(strength)")
        }
    }

    /// Goodbye & Good Riddance is the theme that proves the rule is about chroma and not about
    /// brightness: fourteen of its sixteen entries are greys brighter than most themes' colours,
    /// and only its two reds glow.
    @Test func theMonochromeThemeGlowsOnlyItsReds() throws {
        let theme = try #require(ThemeCatalog.theme(id: "goodbye-good-riddance"))
        let glowing = (0..<16).filter { Glow.emissiveStrength(of: theme.terminal.palette.colors[$0]) > 0 }
        #expect(glowing == [1, 9])
    }

    /// Why Righteous has no glow, stated as a measurement rather than as taste: its palette
    /// straddles the brightness floor, so half of it would glow arbitrarily.
    @Test func theLightThemesPaletteStraddlesTheFloor() throws {
        let theme = try #require(ThemeCatalog.theme(id: "righteous"))
        let middling = (0..<16).filter {
            let strength = Glow.emissiveStrength(of: theme.terminal.palette.colors[$0])
            return strength > 0 && strength < 0.5
        }
        #expect(middling.count == 7)
    }

    @Test func aSaturatedColourGlowsFullyAndAnUnsaturatedOneNotAtAll() {
        #expect(Glow.emissiveStrength(of: RGB(hex: 0xFF3B4F)) == 1)
        #expect(Glow.emissiveStrength(of: RGB(hex: 0x5CC8FC)) == 1)
        #expect(Glow.emissiveStrength(of: RGB(hex: 0xFFFFFF)) == 0)
        #expect(Glow.emissiveStrength(of: RGB(hex: 0x000000)) == 0)
        // Saturated, and too dark: the brightness floor is what keeps ANSI black out.
        #expect(Glow.emissiveStrength(of: RGB(hex: 0x200010)) == 0)
    }

    @Test func theThresholdsAreTheEdgesTheyClaimToBe() {
        #expect(Glow.smoothstep(0.28, 0.44, 0.28) == 0)
        #expect(Glow.smoothstep(0.28, 0.44, 0.44) == 1)
        #expect(abs(Glow.smoothstep(0.28, 0.44, 0.36) - 0.5) < 1e-12)
        #expect(Glow.smoothstep(0.28, 0.44, 0.1) == 0)
        #expect(Glow.smoothstep(0.28, 0.44, 0.9) == 1)
    }

    // MARK: - What the macOS half's hardest test rests on

    /// `RenderKitTests.aGlowReadsOnlyItsOwnGlyph` proves the scatter does not read a
    /// neighbouring glyph out of the atlas, and it can only prove that if the packer really does
    /// put two bitmaps of one height side by side. That is a portable fact, so it is checked
    /// here on every push rather than inside a test only a Mac with a GPU ever runs — where a
    /// change in the packer would turn it into a test that passes while proving nothing.
    @Test func theAtlasPacksTwoBitmapsOfOneHeightSideBySide() throws {
        let rasterizer = SolidBitmaps(shapes: [0x41: (8, 12), 0x42: (2, 12)])
        let cache = GlyphCache(rasterizer: rasterizer)
        let block = try #require(cache.placement(for: GlyphKey(scalar: 0x41)))
        let sliver = try #require(cache.placement(for: GlyphKey(scalar: 0x42)))
        #expect(block.y == sliver.y)
        #expect(block.shelf == sliver.shelf)
        #expect(sliver.x > block.x)
        // One pixel of pad, which is exactly why the scatter has to clamp: three pixels of
        // halo reach well past it.
        #expect(Int(sliver.x) - Int(block.x + block.width) <= 2)
    }

    // MARK: - The energy gate

    @Test func aMacAskingToBeLeftAloneGetsNoGlow() {
        let policy = EffectsPolicy()
        #expect(policy.allowsGlow(.init(recentInput: false)))
        #expect(!policy.allowsGlow(.init(recentInput: false, lowPowerMode: true)))
        #expect(!policy.allowsGlow(.init(recentInput: false, thermal: .serious)))
        #expect(!policy.allowsGlow(.init(recentInput: false, thermal: .critical)))
        #expect(policy.allowsGlow(.init(recentInput: false, thermal: .fair)))
    }

    @Test func lowPowerModeIsIgnoredWhenTheSettingSaysSo() {
        let policy = EffectsPolicy(followsLowPowerMode: false)
        #expect(policy.allowsGlow(.init(recentInput: false, lowPowerMode: true)))
        // Thermal pressure is not a setting: a hot Mac is a hot Mac.
        #expect(!policy.allowsGlow(.init(recentInput: false, lowPowerMode: true, thermal: .serious)))
    }

    /// The conditions are rebuilt on every key press, so a glow that read `recentInput` would
    /// blink on and off as you type. It must change nothing, under every other condition.
    @Test func typingChangesNothing() {
        for policy in [EffectsPolicy(), EffectsPolicy(followsLowPowerMode: false)] {
            for lowPower in [false, true] {
                for thermal in [FrameRatePolicy.Thermal.nominal, .fair, .serious, .critical] {
                    let quiet = FrameRatePolicy.Conditions(
                        recentInput: false, lowPowerMode: lowPower, thermal: thermal)
                    let typing = FrameRatePolicy.Conditions(
                        recentInput: true, lowPowerMode: lowPower, thermal: thermal)
                    #expect(
                        policy.allowsGlow(quiet) == policy.allowsGlow(typing),
                        "typing changed the answer at lowPower \(lowPower), thermal \(thermal)")
                }
            }
        }
    }

    /// The two policies have to agree about what "hot" means, or the frame rate would drop to 30
    /// while the glow was still being drawn.
    @Test func theTwoPoliciesAgreeAboutHeat() {
        #expect(EffectsPolicy.tooHot == .serious)
        let rate = FrameRatePolicy(displayMaximum: 120)
        #expect(rate.range(for: .init(recentInput: true, thermal: EffectsPolicy.tooHot)).maximum == 30)
        #expect(rate.range(for: .init(recentInput: true, thermal: .fair)).maximum == 120)
    }
}
