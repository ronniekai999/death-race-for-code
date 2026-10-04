import Testing
import VTCore

@testable import ConfigKit

@Suite struct ConfigTests {
    @Test func anEmptyFileGivesTheDefaults() {
        let (config, diagnostics) = Config.parse("")
        #expect(config == Config())
        #expect(diagnostics.isEmpty)
        #expect(config.fontFamily == "SF Mono")
        #expect(config.fontSize == 13)
        #expect(config.optionAsMeta == .left)
        #expect(config.theme == .legendsNeverDie)
        #expect(config.scrollbackLimit == 50 * 1024 * 1024)
    }

    @Test func readsEverySetting() {
        let text = """
            font-family = Monaspace Neon
            font-size = 14.5
            font-thicken = true
            cursor-style = bar
            cursor-style-blink = false
            option-as-meta = both
            mouse-scroll-multiplier = 1.5
            mouse-scroll-alternate = false
            window-padding-x = 0
            window-padding-y = 12
            window-size = 132x43
            background = #101010
            foreground = eeeeee
            cursor-color = #F0A
            cursor-text = #000000
            selection-background = #334455
            selection-foreground = #FFFFFF
            palette = 1=#FF0000
            palette = 255 = #ABCDEF
            bold-is-bright = true
            confirm-close = false
            paste-protection = false
            clipboard-write = ask
            secure-keyboard-entry = always
            copy-on-select = true
            bell = none
            command = /opt/homebrew/bin/fish --login
            working-directory = ~/code
            scrollback-limit = 2GB
            """
        let (config, diagnostics) = Config.parse(text)
        #expect(
            diagnostics == [
                ConfigDiagnostic(
                    line: 29, message: "“2GB” does not work for scrollback-limit. Use a size from 0 to 1G, like 50MB.")
            ])
        #expect(config.fontFamily == "Monaspace Neon")
        #expect(config.fontSize == 14.5)
        #expect(config.fontThicken)
        #expect(config.cursorStyle == .bar)
        #expect(!config.cursorStyleBlink)
        #expect(config.optionAsMeta == .both)
        #expect(config.mouseScrollMultiplier == 1.5)
        #expect(!config.mouseScrollAlternate)
        #expect(config.windowPaddingX == 0)
        #expect(config.windowPaddingY == 12)
        #expect(config.windowSize == GridSize(columns: 132, rows: 43))
        #expect(config.theme.palette.background == RGB(hex: 0x101010))
        #expect(config.theme.palette.foreground == RGB(hex: 0xEEEEEE))
        #expect(config.theme.palette.cursor == RGB(hex: 0xFF00AA))
        #expect(config.theme.cursorText == RGB(hex: 0x000000))
        #expect(config.theme.selectionBackground == RGB(hex: 0x334455))
        #expect(config.theme.selectionForeground == RGB(hex: 0xFFFFFF))
        #expect(config.theme.palette.colors[1] == RGB(hex: 0xFF0000))
        #expect(config.theme.palette.colors[255] == RGB(hex: 0xABCDEF))
        #expect(config.theme.palette.colors[2] == Palette.legendsNeverDie.colors[2])
        #expect(config.theme.boldIsBright)
        #expect(!config.confirmClose)
        #expect(!config.pasteProtection)
        #expect(config.clipboardWrite == .ask)
        #expect(config.secureKeyboardEntry == .always)
        #expect(config.copyOnSelect)
        #expect(config.bell == .silent)
        #expect(config.commandArguments == ["/opt/homebrew/bin/fish", "--login"])
        #expect(config.workingDirectory == .path("~/code"))
        #expect(config.scrollbackLimit == Config().scrollbackLimit)
    }

    @Test func commentsBlankLinesQuotesAndWindowsLineEnds() {
        let text =
            "# a comment\r\n\r\n   # indented comment\r\nfont-family = \"  Spaced Font  \"\r\nbackground=#123456\r\n"
        let (config, diagnostics) = Config.parse(text)
        #expect(diagnostics.isEmpty)
        #expect(config.fontFamily == "  Spaced Font  ")
        #expect(config.theme.palette.background == RGB(hex: 0x123456))
    }

    @Test func theLastLineWinsAndPaletteLinesAddUp() {
        let text = """
            font-size = 12
            font-size = 16
            palette = 0=#000001
            palette = 1=#000002
            palette = 0=#000003
            """
        let (config, _) = Config.parse(text)
        #expect(config.fontSize == 16)
        #expect(config.theme.palette.colors[0] == RGB(hex: 0x000003))
        #expect(config.theme.palette.colors[1] == RGB(hex: 0x000002))
    }

    @Test func badLinesAreReportedAndKeepTheirDefaults() {
        let text = """
            font-szie = 14
            font-size = big
            cursor-style = beam
            option-as-meta = Left
            just some words
            palette = 256=#FFFFFF
            palette = 3=red
            bell =
            window-size = 5x5
            fontsize = 20
            totally-unknown-thing = 1
            """
        let (config, diagnostics) = Config.parse(text)
        #expect(config == Config())
        #expect(diagnostics.map(\.line) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
        #expect(diagnostics[0].message == "There is no setting called “font-szie”. Did you mean “font-size”?")
        #expect(diagnostics[1].message == "“big” does not work for font-size. Use a number from 6 to 144.")
        #expect(diagnostics[2].message == "“beam” does not work for cursor-style. Use block, bar or underline.")
        #expect(diagnostics[3].message == "“Left” does not work for option-as-meta. Use left, right, both or none.")
        #expect(diagnostics[4].message == "Write settings as name = value.")
        #expect(diagnostics[5].message.hasSuffix("Use a color number from 0 to 255 and a color, like 1=#FF5277."))
        #expect(diagnostics[6].message == "“3=red” does not work for palette. Use a color like #EC48C4.")
        #expect(diagnostics[7].message == "“bell” needs a value.")
        #expect(diagnostics[8].message.hasPrefix("“5x5” does not work for window-size."))
        #expect(diagnostics[9].message == "There is no setting called “fontsize”. Did you mean “font-size”?")
        #expect(diagnostics[10].message == "There is no setting called “totally-unknown-thing”.")
        #expect(diagnostics[0].description == "Line 1: " + diagnostics[0].message)
    }

    @Test func colorForms() throws {
        #expect(try Value.color("#EC48C4") == RGB(hex: 0xEC48C4))
        #expect(try Value.color("ec48c4") == RGB(hex: 0xEC48C4))
        #expect(try Value.color("#F0A") == RGB(hex: 0xFF00AA))
        #expect(throws: ConfigValueError.self) { try Value.color("#EC48C") }
        #expect(throws: ConfigValueError.self) { try Value.color("#GGGGGG") }
        #expect(throws: ConfigValueError.self) { try Value.color("") }
        #expect(throws: ConfigValueError.self) { try Value.color("+12345") }
        #expect(Value.format(RGB(hex: 0x0A0B0C)) == "#0A0B0C")
    }

    @Test func byteSizes() throws {
        #expect(try Value.bytes("0") == 0)
        #expect(try Value.bytes("1048576") == 1 << 20)
        #expect(try Value.bytes("512K") == 512 << 10)
        #expect(try Value.bytes("50MB") == 50 << 20)
        #expect(try Value.bytes("50mb") == 50 << 20)
        #expect(try Value.bytes("2MiB") == 2 << 20)
        #expect(try Value.bytes("1G") == 1 << 30)
        #expect(throws: ConfigValueError.self) { try Value.bytes("2G") }
        #expect(throws: ConfigValueError.self) { try Value.bytes("-1") }
        #expect(throws: ConfigValueError.self) { try Value.bytes("lots") }
        #expect(throws: ConfigValueError.self) { try Value.bytes("MB") }
        #expect(throws: ConfigValueError.self) { try Value.bytes("99999999999999999999") }
        #expect(Value.formatBytes(50 << 20) == "50MB")
        #expect(Value.formatBytes(1 << 30) == "1GB")
        #expect(Value.formatBytes(1536) == "1536")
        #expect(Value.formatBytes(0) == "0")
    }

    @Test func numbers() throws {
        #expect(try Value.number("13", in: 6...144) == 13)
        #expect(throws: ConfigValueError.self) { try Value.number("nan", in: 6...144) }
        #expect(throws: ConfigValueError.self) { try Value.number("inf", in: 0...1e300) }
        #expect(throws: ConfigValueError.self) { try Value.number("5", in: 6...144) }
        #expect(Value.format(13) == "13")
        #expect(Value.format(0.5) == "0.5")
    }

    @Test func workingDirectories() {
        #expect(Config.parse("working-directory = home").config.workingDirectory == .home)
        #expect(Config.parse("working-directory = inherit").config.workingDirectory == .inherit)
        #expect(Config.parse("working-directory = /tmp").config.workingDirectory == .path("/tmp"))
        #expect(Config.parse("working-directory = ~").config.workingDirectory == .path("~"))
        let (config, diagnostics) = Config.parse("working-directory = relative/path")
        #expect(config.workingDirectory == .inherit)
        #expect(diagnostics.count == 1)
    }

    @Test func emptyCommandsAreRefused() {
        let (config, diagnostics) = Config.parse("command = \"\"")
        #expect(config.command == nil)
        #expect(diagnostics.count == 1)
        #expect(Config().commandArguments == nil)
    }

    @Test func optionKeySides() {
        #expect(OptionAsMeta.left.usesLeft && !OptionAsMeta.left.usesRight)
        #expect(!OptionAsMeta.right.usesLeft && OptionAsMeta.right.usesRight)
        #expect(OptionAsMeta.both.usesLeft && OptionAsMeta.both.usesRight)
        #expect(!OptionAsMeta.neither.usesLeft && !OptionAsMeta.neither.usesRight)
    }

    @Test func suggestionsOnlyForTypos() {
        #expect(ConfigParser.suggestion(for: "font-szie") == "font-size")
        #expect(ConfigParser.suggestion(for: "Font-Size") == "font-size")
        #expect(ConfigParser.suggestion(for: "pallete") == "palette")
        #expect(ConfigParser.suggestion(for: "colour") == nil)
        #expect(ConfigParser.editDistance("", "abc") == 3)
        #expect(ConfigParser.editDistance("kitten", "sitting") == 3)
    }
}

@Suite struct ConfigTemplateTests {
    /// Every setting is in the template, at its default, under its section.
    @Test func theTemplateListsEverySettingAtItsDefault() {
        let template = ConfigSchema.template
        let defaults = Config()
        for key in ConfigSchema.keys {
            if let value = key.write(defaults) {
                #expect(template.contains("\n# \(key.name) = \(value)\n"), "\(key.name) is missing")
            } else {
                #expect(key.example.map { template.contains("\n# \($0)\n") } == true, "\(key.name) has no example")
            }
        }
        for section in ConfigKey.Section.allCases {
            #expect(template.contains("# ---- \(section.rawValue) ----"))
        }
    }

    /// The template is all comments, so it reads as the defaults; uncommented, every line
    /// is a valid setting that still gives the defaults, and every example parses too.
    @Test func theTemplateRoundTrips() {
        let template = ConfigSchema.template
        let (asIs, asIsDiagnostics) = Config.parse(template)
        #expect(asIs == Config())
        #expect(asIsDiagnostics.isEmpty)

        let names = ConfigSchema.keys.map(\.name)
        let settingLines = template.split(separator: "\n").filter { line in
            names.contains { line.hasPrefix("# \($0) = ") }
        }
        #expect(settingLines.count == ConfigSchema.keys.count)
        let defaultsOnly = settingLines.filter { line in
            !ConfigSchema.keys.contains { $0.example.map { line == "# " + $0 } ?? false }
        }
        let (uncommented, diagnostics) = Config.parse(defaultsOnly.map { $0.dropFirst(2) }.joined(separator: "\n"))
        #expect(diagnostics.isEmpty)
        #expect(uncommented == Config())

        let examples = ConfigSchema.keys.compactMap(\.example).joined(separator: "\n")
        #expect(Config.parse(examples).diagnostics.isEmpty)
    }

    @Test func helpLinesFitAnEightyColumnTerminal() {
        for line in ConfigSchema.template.split(separator: "\n") {
            #expect(line.count <= 100, "too long: \(line)")
        }
        for key in ConfigSchema.keys {
            #expect(!key.help.isEmpty)
            for line in key.help { #expect(line.count + 2 <= 92, "\(key.name): \(line)") }
        }
    }

    @Test func namesAreUniqueAndLowercase() {
        let names = ConfigSchema.keys.map(\.name)
        #expect(Set(names).count == names.count)
        for name in names { #expect(name == name.lowercased() && !name.contains(" ")) }
        #expect(ConfigSchema.keys.filter(\.repeats).map(\.name) == ["palette"])
    }
}

@Suite struct ConfigLocationTests {
    @Test func xdgConfigHomeWinsWhenAbsolute() {
        #expect(ConfigLocation.path(environment: [:], home: "/Users/me") == "/Users/me/.config/deathrace/config")
        #expect(
            ConfigLocation.path(environment: ["XDG_CONFIG_HOME": "/Users/me/cfg/"], home: "/Users/me")
                == "/Users/me/cfg/deathrace/config")
        #expect(
            ConfigLocation.path(environment: ["XDG_CONFIG_HOME": "relative"], home: "/Users/me/")
                == "/Users/me/.config/deathrace/config")
        #expect(ConfigLocation.path(environment: ["XDG_CONFIG_HOME": "/"], home: "/x") == "/deathrace/config")
    }
}

@Suite struct ShellWordsTests {
    @Test func splitsLikeAShell() {
        #expect(ShellWords.split("") == [])
        #expect(ShellWords.split("   ") == [])
        #expect(ShellWords.split("fish --login") == ["fish", "--login"])
        #expect(ShellWords.split("  a\tb  c ") == ["a", "b", "c"])
        #expect(ShellWords.split("'/Applications/My App/run' -x") == ["/Applications/My App/run", "-x"])
        #expect(ShellWords.split("\"a b\" c") == ["a b", "c"])
        #expect(ShellWords.split("a\\ b") == ["a b"])
        #expect(ShellWords.split("\"say \\\"hi\\\"\"") == ["say \"hi\""])
        #expect(ShellWords.split("\"C:\\dir\"") == ["C:\\dir"])
        #expect(ShellWords.split("'it''s'") == ["its"])
        #expect(ShellWords.split("\"\" x") == ["", "x"])
        #expect(ShellWords.split("pre'fix'post") == ["prefixpost"])
        #expect(ShellWords.split("'unfinished quote") == ["unfinished quote"])
        #expect(ShellWords.split("trailing\\") == ["trailing\\"])
    }
}
