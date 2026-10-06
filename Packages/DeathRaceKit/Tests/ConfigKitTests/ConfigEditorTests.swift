import Testing
import VTCore

@testable import ConfigKit

@Suite struct ConfigEditorTests {
    /// A value for every setting that is not its default.
    static let samples: [String: String] = [
        "font-family": "Monaspace Neon", "font-size": "15", "font-family-italic": "Monaspace Radon",
        "font-thicken": "true", "cursor-style": "bar", "cursor-style-blink": "false", "option-as-meta": "both",
        "mouse-scroll-multiplier": "1.5", "mouse-scroll-alternate": "false", "window-padding-x": "10",
        "window-padding-y": "4", "window-size": "120x40", "pane-headers": "always", "starfield": "false",
        "conversations": "false", "fast-threshold-milliseconds": "2500",
        "theme": "righteous", "background": "#000000", "foreground": "#FFFFFF", "cursor-color": "#FF0000",
        "cursor-text": "#000000", "selection-background": "#333333", "selection-foreground": "#FFFFFF",
        "palette": "1=#FF0000", "bold-is-bright": "true", "confirm-close": "false", "paste-protection": "false",
        "clipboard-write": "ask", "secure-keyboard-entry": "always", "follow-low-power-mode": "false",
        "output-frame-rate-cap": "false", "wrld-check-hosts": "false", "wrld-host-os": "false",
        "legends-never-die": "false",
        "shell-integration": "false",
        "copy-on-select": "true", "bell": "visual", "command": "/bin/zsh -l",
        "working-directory": "~/code", "scrollback-limit": "10MB", "lucid-dreams-hotkey": "⌃⌘T",
    ]

    @Test func everySettingHasASample() {
        #expect(Set(Self.samples.keys) == Set(ConfigSchema.keys.map(\.name)))
    }

    /// Set on the template, every setting reads back as set, and only one line changes.
    @Test(arguments: ConfigSchema.keys.map(\.name))
    func everySettingRoundTripsThroughTheTemplate(_ name: String) throws {
        let template = ConfigSchema.template
        let sample = try #require(Self.samples[name])
        let edited = ConfigEditor.set(name, to: sample, in: template)
        let (config, diagnostics) = Config.parse(edited)
        #expect(diagnostics.isEmpty)
        let key = try #require(ConfigSchema.key(named: name))
        if name == "palette" {
            #expect(config.colorOverrides.palette == [1: RGB(hex: 0xFF0000)])
        } else {
            #expect(key.value(in: config) == sample)
        }
        let before = template.split(separator: "\n", omittingEmptySubsequences: false)
        var after = edited.split(separator: "\n", omittingEmptySubsequences: false)
        let added = try #require(after.firstIndex(of: Substring("\(name) = \(sample)")))
        after.remove(at: added)
        #expect(after == before)
        // Right under the template's line for it.
        #expect(edited.split(separator: "\n", omittingEmptySubsequences: false)[added - 1].hasPrefix("# \(name)"))
    }

    @Test func theLastLineForASettingIsTheOneReplaced() {
        let text = "font-size = 12\n# a note\nfont-size = 14\nbell = none\n"
        #expect(
            ConfigEditor.set("font-size", to: "16", in: text)
                == "font-size = 12\n# a note\nfont-size = 16\nbell = none\n")
    }

    @Test func indentationStays() {
        #expect(ConfigEditor.set("bell", to: "visual", in: "  bell = none\n") == "  bell = visual\n")
    }

    @Test func aNewSettingGoesAtTheEndOfItsSection() {
        let text = """
            # ---- Fonts ----
            font-size = 14

            # ---- Other ----
            bell = none

            """
        let edited = ConfigEditor.set("font-family", to: "Menlo", in: text)
        #expect(
            edited == """
                # ---- Fonts ----
                font-size = 14
                font-family = Menlo

                # ---- Other ----
                bell = none

                """)
    }

    @Test func withoutASectionItGoesAtTheEnd() {
        #expect(ConfigEditor.set("bell", to: "visual", in: "font-size = 14\n") == "font-size = 14\n\nbell = visual\n")
        #expect(ConfigEditor.set("bell", to: "visual", in: "") == "bell = visual\n")
    }

    @Test func noValueCommentsTheSettingOut() {
        let text = "bell = none\nfont-size = 14\nbell = visual\n"
        let edited = ConfigEditor.set("bell", to: nil, in: text)
        #expect(edited == "# bell = none\nfont-size = 14\n# bell = visual\n")
        #expect(Config.parse(edited).config.bell == Config().bell)
    }

    @Test func spacesAtTheEndsAreQuoted() {
        let edited = ConfigEditor.set("command", to: " /bin/zsh ", in: "")
        #expect(edited == "command = \" /bin/zsh \"\n")
        #expect(Config.parse(edited).config.command == " /bin/zsh ")
        #expect(ConfigEditor.set("command", to: "a\nb", in: "") == "command = a b\n")
    }

    /// A command whose path has a space is written in double quotes; the parser takes the
    /// outer pair as quoting, so the value keeps another.
    @Test func doubleQuotedValuesKeepTheirQuotes() {
        let command = "\"/Applications/My Shell.app/Contents/MacOS/fish\""
        let file = ConfigEditor.set("command", to: command, in: ConfigSchema.template)
        let (config, diagnostics) = Config.parse(file)
        #expect(diagnostics.isEmpty)
        #expect(config.command == command)
        #expect(config.commandArguments == ["/Applications/My Shell.app/Contents/MacOS/fish"])
        // Quotes inside a value need nothing.
        let inside = ConfigEditor.set("command", to: "fish -c \"echo hi\"", in: "")
        #expect(Config.parse(inside).0.commandArguments == ["fish", "-c", "echo hi"])
    }

    @Test func lineEndingsAndTheLastNewlineStay() {
        #expect(
            ConfigEditor.set("bell", to: "visual", in: "bell = none\r\nfont-size = 14\r\n")
                == "bell = visual\r\nfont-size = 14\r\n")
        #expect(
            ConfigEditor.set("bell", to: "visual", in: "font-size = 14\nbell = none") == "font-size = 14\nbell = visual"
        )
    }

    @Test func paletteLinesAreMatchedByColorNumber() {
        let text = "palette = 1=#FF0000\npalette = 2=#00FF00\n"
        #expect(ConfigEditor.set("palette", to: "2=#0000FF", in: text) == "palette = 1=#FF0000\npalette = 2=#0000FF\n")
        #expect(
            ConfigEditor.set("palette", to: "3=#FFFFFF", in: text)
                == "palette = 1=#FF0000\npalette = 2=#00FF00\n\npalette = 3=#FFFFFF\n")
        #expect(ConfigEditor.set("palette", to: nil, in: text) == "# palette = 1=#FF0000\n# palette = 2=#00FF00\n")
    }

    @Test func commentsThatLookLikeSettingsAreLeftAlone() {
        let text = "# bell = none, the quiet option\nbell = system\n"
        #expect(ConfigEditor.set("bell", to: "visual", in: text) == "# bell = none, the quiet option\nbell = visual\n")
    }
}
