import AppKit
import ConfigKit
import SurfaceCore
import Testing

@testable import DeathRaceApp
@testable import TerminalUI

// In the window tests' suite, so they run one at a time with the windows they share the screen
// with.
extension WindowTests {
    /// The one line in `applySettings`, and `hasGlow` beside it: a dark theme's panes glow at
    /// that theme's own strength, Righteous's do not glow at all, and the setting turns it off
    /// everywhere.
    @Test func aDarkThemeGlowsAtItsOwnStrengthAndTheLightOneNotAtAll() throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let surface = try #require(controller.activePane?.surface)
        #expect(surface.textGlow == Glow(strength: ThemeCatalog.legendsNeverDie.chrome.glowOpacity))

        var config = Config()
        config.themeID = "righteous"
        controller.apply(config)
        #expect(surface.textGlow == nil)

        // A different dark theme, to show the strength follows the theme rather than being one
        // number: Wishing Well is tuned lower than Legends Never Die.
        config.themeID = "wishing-well"
        controller.apply(config)
        #expect(surface.textGlow == Glow(strength: ThemeCatalog.wishingWell.chrome.glowOpacity))
        #expect(ThemeCatalog.wishingWell.chrome.glowOpacity != ThemeCatalog.legendsNeverDie.chrome.glowOpacity)

        config.textGlow = false
        controller.apply(config)
        #expect(surface.textGlow == nil)
    }

    /// Why `applyFrameRate` had to be **split** rather than extended, which is the one mistake
    /// in this change that would have shipped silently.
    ///
    /// It returns early at `guard let link else { return }`, and no pane in a test process or in
    /// `ChromePreview` ever has a display link — the window is never on screen, which is the
    /// same fact that has bitten this project three times from three directions. A glow settled
    /// after that guard would reach exactly none of the paths CI can see, so the chrome pictures
    /// and the render goldens would have come back with no glow in them and nothing would have
    /// said so.
    @Test func theGlowIsAppliedWhereThereIsNoDisplayLink() throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let surface = try #require(controller.activePane?.surface)
        // The runner's own temperature is not what is under test: a loaded macOS runner can
        // report `serious` thermal pressure, and then this would fail for a reason the message
        // could not name.
        surface.energyState = { FrameRatePolicy.Conditions(recentInput: false) }
        surface.applyEnergyConditions()
        let strength = UInt32((ThemeCatalog.legendsNeverDie.chrome.glowOpacity * 255).rounded())
        #expect(surface.allowedGlow >> 24 == strength)

        // And the gate itself, asserted on the policy rather than on the weather.
        surface.energyState = { FrameRatePolicy.Conditions(recentInput: false, lowPowerMode: true) }
        surface.applyEnergyConditions()
        #expect(surface.allowedGlow == 0)
        surface.energyState = { FrameRatePolicy.Conditions(recentInput: false, thermal: .serious) }
        surface.applyEnergyConditions()
        #expect(surface.allowedGlow == 0)
        // Typing must not take it away, which is the whole reason `recentInput` is not an input.
        surface.energyState = { FrameRatePolicy.Conditions(recentInput: false) }
        surface.applyEnergyConditions()
        #expect(surface.allowedGlow >> 24 == strength)
    }
}
