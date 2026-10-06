import VTCore

/// One setting: its name, its place in the template, how to read a value into a `Config` and
/// how to write the value a `Config` holds.
public struct ConfigKey: Sendable {
    public enum Section: String, CaseIterable, Sendable {
        case fonts = "Fonts"
        case cursor = "Cursor"
        case input = "Keyboard and mouse"
        case window = "Window"
        case colors = "Colors"
        case safety = "Safety"
        case energy = "Energy"
        case wrld = "WRLD"
        case sessions = "Sessions"
        case other = "Other"
        case newTabs = "New tabs"
    }

    public let name: String
    public let section: Section
    /// What the template says about the setting, one comment line each.
    public let help: [String]
    /// May appear on many lines, each adding to the others (palette). Otherwise the last
    /// line wins.
    public let repeats: Bool
    /// The template's sample line, for settings whose default is not a value (nothing set).
    let example: String?
    let read: @Sendable (Substring, inout Config) throws(ConfigValueError) -> Void
    let write: @Sendable (Config) -> String?

    init(
        _ name: String, _ section: Section, help: [String], repeats: Bool = false, example: String? = nil,
        read: @escaping @Sendable (Substring, inout Config) throws(ConfigValueError) -> Void,
        write: @escaping @Sendable (Config) -> String?
    ) {
        self.name = name
        self.section = section
        self.help = help
        self.repeats = repeats
        self.example = example
        self.read = read
        self.write = write
    }
}

/// Why a value could not be used, in words for the person editing the file.
public struct ConfigValueError: Error, Sendable, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Every setting. This one table drives the parser, the defaults the template shows, and
/// the template itself.
public enum ConfigSchema {
    public static let keys: [ConfigKey] =
        fonts + cursor + input + window + colors + safety + energy + wrld + sessions + other + newTabs

    public static func key(named name: some StringProtocol) -> ConfigKey? {
        keys.first { $0.name == name }
    }

    private static let fonts: [ConfigKey] = [
        ConfigKey(
            "font-family", .fonts,
            help: ["The font for terminal text. SF Mono is the system's monospaced font."],
            read: { value, config throws(ConfigValueError) in config.fontFamily = String(value) },
            write: { $0.fontFamily }),
        ConfigKey(
            "font-size", .fonts,
            help: ["Points, from 6 to 144. ⌘+ and ⌘− change it in one window; ⌘0 returns to this."],
            read: { value, config throws(ConfigValueError) in config.fontSize = try Value.number(value, in: 6...144) },
            write: { Value.format($0.fontSize) }),
        ConfigKey(
            "font-family-italic", .fonts,
            help: [
                "A family for italic text, like Monaspace Radon beside Monaspace Neon. Unset, italics",
                "come from the main font.",
            ],
            example: "font-family-italic = Monaspace Radon",
            read: { value, config throws(ConfigValueError) in config.fontFamilyItalic = String(value) },
            write: { $0.fontFamilyItalic }),
        ConfigKey(
            "font-thicken", .fonts,
            help: ["Draws text with heavier strokes, which some prefer for light text on a dark background."],
            read: { value, config throws(ConfigValueError) in config.fontThicken = try Value.bool(value) },
            write: { String($0.fontThicken) }),
    ]

    private static let cursor: [ConfigKey] = [
        ConfigKey(
            "cursor-style", .cursor,
            help: ["The cursor's shape: block, bar or underline. Programs can change it, as vim does."],
            read: { value, config throws(ConfigValueError) in
                switch value {
                case "block": config.cursorStyle = .block
                case "bar": config.cursorStyle = .bar
                case "underline": config.cursorStyle = .underline
                default: throw ConfigValueError("Use block, bar or underline.")
                }
            },
            write: {
                switch $0.cursorStyle {
                case .block: "block"
                case .bar: "bar"
                case .underline: "underline"
                }
            }),
        ConfigKey(
            "cursor-style-blink", .cursor,
            help: [
                "Whether the cursor blinks, unless a program asks otherwise. It stops after 30",
                "seconds without typing.",
            ],
            read: { value, config throws(ConfigValueError) in config.cursorStyleBlink = try Value.bool(value) },
            write: { String($0.cursorStyleBlink) }),
    ]

    private static let input: [ConfigKey] = [
        ConfigKey(
            "option-as-meta", .input,
            help: [
                "Which Option keys act as Meta (Alt): left, right, both or none. The others type your",
                "layout's special characters, like é or ∑. Layouts that need Option for brackets and",
                "braces (German, French, Nordic) want none, or right.",
            ],
            read: { value, config throws(ConfigValueError) in config.optionAsMeta = try Value.choice(value) },
            write: { $0.optionAsMeta.rawValue }),
        ConfigKey(
            "mouse-scroll-multiplier", .input,
            help: ["Lines a mouse wheel scrolls per notch. Trackpads scroll by distance and ignore it."],
            read: { value, config throws(ConfigValueError) in
                config.mouseScrollMultiplier = try Value.number(value, in: 0.1...100)
            },
            write: { Value.format($0.mouseScrollMultiplier) }),
        ConfigKey(
            "mouse-scroll-alternate", .input,
            help: [
                "On the alternate screen (less, man, vim without mouse support) the wheel sends arrow",
                "keys, so it scrolls the program's text.",
            ],
            read: { value, config throws(ConfigValueError) in config.mouseScrollAlternate = try Value.bool(value) },
            write: { String($0.mouseScrollAlternate) }),
        ConfigKey(
            "lucid-dreams-hotkey", .input,
            help: [
                "A global shortcut that shows and hides Lucid Dreams, the notch quick-terminal, even",
                "when Death Race isn't the active app. Write it as ⌥Space or opt+space. Set it to none",
                "to turn the hotkey off; the menu and the menu-bar icon still open Lucid Dreams.",
            ],
            read: { value, config throws(ConfigValueError) in config.lucidDreamsHotkey = String(value) },
            write: { $0.lucidDreamsHotkey }),
    ]

    private static let window: [ConfigKey] = [
        ConfigKey(
            "window-padding-x", .window,
            help: ["Points between the text and the window's left and right edges."],
            read: { value, config throws(ConfigValueError) in
                config.windowPaddingX = try Value.number(value, in: 0...200)
            },
            write: { Value.format($0.windowPaddingX) }),
        ConfigKey(
            "window-padding-y", .window,
            help: ["Points between the text and the window's top and bottom edges."],
            read: { value, config throws(ConfigValueError) in
                config.windowPaddingY = try Value.number(value, in: 0...200)
            },
            write: { Value.format($0.windowPaddingY) }),
        ConfigKey(
            "window-size", .window,
            help: ["The size of new windows, in columns x rows."],
            read: { value, config throws(ConfigValueError) in config.windowSize = try Value.gridSize(value) },
            write: { "\($0.windowSize.columns)x\($0.windowSize.rows)" }),
        ConfigKey(
            "pane-headers", .window,
            help: [
                "Headers above panes, with the program, directory and branch: split (only while a",
                "tab is split into panes), always or never.",
            ],
            read: { value, config throws(ConfigValueError) in config.paneHeaders = try Value.choice(value) },
            write: { $0.paneHeaders.rawValue }),
        ConfigKey(
            "starfield", .window,
            help: [
                "Faint stars behind the panes and in the empty space after each line. The light",
                "theme, Righteous, has none.",
            ],
            read: { value, config throws(ConfigValueError) in config.starfield = try Value.bool(value) },
            write: { String($0.starfield) }),
    ]

    private static let colors: [ConfigKey] = [
        ConfigKey(
            "theme", .colors,
            help: [
                "The colors of the terminal and of the window around it: legends-never-die,",
                "lucid-dreams, goodbye-good-riddance, death-race-for-love, fighting-demons,",
                "wishing-well, the-party-never-ends or righteous (light). The settings below change",
                "single colors on top of it, wherever this line is.",
            ],
            read: { value, config throws(ConfigValueError) in
                guard let theme = ThemeCatalog.theme(named: value) else {
                    throw ConfigValueError(Value.themeHint(for: value))
                }
                config.themeID = theme.id
            },
            write: { $0.themeID }),
        ConfigKey(
            "background", .colors,
            help: ["The default background color, instead of the theme's."],
            example: "background = #100822",
            read: { value, config throws(ConfigValueError) in config.colorOverrides.background = try Value.color(value)
            },
            write: { $0.colorOverrides.background.map(Value.format) }),
        ConfigKey(
            "foreground", .colors,
            help: ["The default text color, instead of the theme's."],
            example: "foreground = #EDE7FF",
            read: { value, config throws(ConfigValueError) in config.colorOverrides.foreground = try Value.color(value)
            },
            write: { $0.colorOverrides.foreground.map(Value.format) }),
        ConfigKey(
            "cursor-color", .colors,
            help: ["The cursor's color, instead of the theme's."],
            example: "cursor-color = #EC48C4",
            read: { value, config throws(ConfigValueError) in config.colorOverrides.cursor = try Value.color(value) },
            write: { $0.colorOverrides.cursor.map(Value.format) }),
        ConfigKey(
            "cursor-text", .colors,
            help: ["The character under a block cursor. Unset, it takes the background color."],
            example: "cursor-text = #100822",
            read: { value, config throws(ConfigValueError) in config.colorOverrides.cursorText = try Value.color(value)
            },
            write: { $0.colorOverrides.cursorText.map(Value.format) }),
        ConfigKey(
            "selection-background", .colors,
            help: ["The background of selected text, instead of the theme's."],
            example: "selection-background = #463279",
            read: { value, config throws(ConfigValueError) in
                config.colorOverrides.selectionBackground = try Value.color(value)
            },
            write: { $0.colorOverrides.selectionBackground.map(Value.format) }),
        ConfigKey(
            "selection-foreground", .colors,
            help: ["Selected text. Unset, each character keeps its own color."],
            example: "selection-foreground = #FFFFFF",
            read: { value, config throws(ConfigValueError) in
                config.colorOverrides.selectionForeground = try Value.color(value)
            },
            write: { $0.colorOverrides.selectionForeground.map(Value.format) }),
        ConfigKey(
            "palette", .colors,
            help: [
                "Changes one of the 256 colors programs pick from: 0 to 7 are black, red, green,",
                "yellow, blue, magenta, cyan and white, and 8 to 15 their bright versions. Use one",
                "line per color.",
            ],
            repeats: true,
            example: "palette = 1=#FF5277",
            read: { value, config throws(ConfigValueError) in
                let (index, color) = try Value.paletteEntry(value)
                config.colorOverrides.palette[index] = color
            },
            write: { _ in nil }),
        ConfigKey(
            "bold-is-bright", .colors,
            help: ["Bold text in colors 0 to 7 uses their bright versions, 8 to 15, as old terminals did."],
            example: "bold-is-bright = true",
            read: { value, config throws(ConfigValueError) in config.colorOverrides.boldIsBright = try Value.bool(value)
            },
            write: { $0.colorOverrides.boldIsBright.map { String($0) } }),
    ]

    private static let safety: [ConfigKey] = [
        ConfigKey(
            "confirm-close", .safety,
            help: ["Ask before closing a tab, a window or the app while a program other than the shell runs."],
            read: { value, config throws(ConfigValueError) in config.confirmClose = try Value.bool(value) },
            write: { String($0.confirmClose) }),
        ConfigKey(
            "paste-protection", .safety,
            help: [
                "Ask before pasting text that would run commands as soon as it lands: several lines,",
                "or control characters, for a program that has not turned on bracketed paste.",
            ],
            read: { value, config throws(ConfigValueError) in config.pasteProtection = try Value.bool(value) },
            write: { String($0.pasteProtection) }),
        ConfigKey(
            "clipboard-write", .safety,
            help: [
                "Whether programs may put text on the clipboard (OSC 52, which tmux and vim use over",
                "SSH): allow, ask or deny. Only the focused tab of the active window can. Programs can",
                "never read the clipboard.",
            ],
            read: { value, config throws(ConfigValueError) in config.clipboardWrite = try Value.choice(value) },
            write: { $0.clipboardWrite.rawValue }),
        ConfigKey(
            "secure-keyboard-entry", .safety,
            help: [
                "Secure Keyboard Entry keeps other apps from seeing what you type. auto turns it on",
                "while a program reads a password (sudo, ssh) and while it is checked in the Death",
                "Race menu; always keeps it on while Death Race is active; manual follows only the",
                "menu.",
            ],
            read: { value, config throws(ConfigValueError) in config.secureKeyboardEntry = try Value.choice(value) },
            write: { $0.secureKeyboardEntry.rawValue }),
    ]

    private static let energy: [ConfigKey] = [
        ConfigKey(
            "follow-low-power-mode", .energy,
            help: ["In Low Power Mode, draw at most 60 frames a second while typing and 30 for output."],
            read: { value, config throws(ConfigValueError) in config.followLowPowerMode = try Value.bool(value) },
            write: { String($0.followLowPowerMode) }),
        ConfigKey(
            "output-frame-rate-cap", .energy,
            help: [
                "Draw busy output at most 60 frames a second. Typing and scrolling keep the",
                "display's full rate.",
            ],
            read: { value, config throws(ConfigValueError) in config.outputFrameRateCap = try Value.bool(value) },
            write: { String($0.outputFrameRateCap) }),
    ]

    private static let wrld: [ConfigKey] = [
        ConfigKey(
            "wrld-check-hosts", .wrld,
            help: [
                "Check how quickly Legends answer, with a connection that sends nothing, while the",
                "WRLD sidebar or window shows them: five minutes apart, never through a jump host,",
                "and on your own network only once you've connected yourself.",
            ],
            read: { value, config throws(ConfigValueError) in config.checkHosts = try Value.bool(value) },
            write: { String($0.checkHosts) }),
        ConfigKey(
            "wrld-host-os", .wrld,
            help: [
                "Read what each host runs from its /etc/os-release, over a connection you already",
                "have, at most once a week.",
            ],
            read: { value, config throws(ConfigValueError) in config.readHostOS = try Value.bool(value) },
            write: { String($0.readHostOS) }),
    ]

    private static let sessions: [ConfigKey] = [
        ConfigKey(
            "legends-never-die", .sessions,
            help: [
                "Keep local shells running when Death Race quits or crashes, and put them back in",
                "their windows the next time it starts. They are held by legendsd, a small program",
                "beside the app, which ends on its own once nothing is left in it.",
                "Sessions on a host are not kept: they run through an ssh connection this app owns,",
                "which goes when it does.",
            ],
            read: { value, config throws(ConfigValueError) in config.legendsNeverDie = try Value.bool(value) },
            write: { String($0.legendsNeverDie) }),
        ConfigKey(
            "shell-integration", .sessions,
            help: [
                "Tell your shell to say where each prompt and command begins and ends, which is what",
                "a command's duration, its pass or fail mark, and the word when a long one finishes",
                "are all read from.",
                "zsh and fish are set up through the environment and no file of yours is touched.",
                "bash is different: it is offered one line to add to your ~/.bashrc, and shown the",
                "line first. Turning this off stops all three.",
            ],
            read: { value, config throws(ConfigValueError) in config.shellIntegration = try Value.bool(value) },
            write: { String($0.shellIntegration) }),
    ]

    private static let other: [ConfigKey] = [
        ConfigKey(
            "copy-on-select", .other,
            help: ["Copy text to the clipboard as soon as you select it."],
            read: { value, config throws(ConfigValueError) in config.copyOnSelect = try Value.bool(value) },
            write: { String($0.copyOnSelect) }),
        ConfigKey(
            "bell", .other,
            help: [
                "What the terminal bell does: system (the alert sound), visual (a flash) or none.",
                "When Death Race is in the background, the Dock icon also bounces once.",
            ],
            read: { value, config throws(ConfigValueError) in config.bell = try Value.choice(value) },
            write: { $0.bell.rawValue }),
    ]

    private static let newTabs: [ConfigKey] = [
        ConfigKey(
            "command", .newTabs,
            help: ["What new tabs run instead of your login shell. Quote words that contain spaces."],
            example: "command = /opt/homebrew/bin/fish --login",
            read: { value, config throws(ConfigValueError) in
                guard !ShellWords.split(String(value)).isEmpty else {
                    throw ConfigValueError("Give a program to run, like /bin/zsh.")
                }
                config.command = String(value)
            },
            write: { $0.command }),
        ConfigKey(
            "working-directory", .newTabs,
            help: ["Where new tabs start: inherit (the current tab's directory), home, or a path."],
            read: { value, config throws(ConfigValueError) in
                switch value {
                case "inherit": config.workingDirectory = .inherit
                case "home": config.workingDirectory = .home
                default:
                    guard value.hasPrefix("/") || value == "~" || value.hasPrefix("~/") else {
                        throw ConfigValueError("Use inherit, home, or a path starting with / or ~.")
                    }
                    config.workingDirectory = .path(String(value))
                }
            },
            write: {
                switch $0.workingDirectory {
                case .inherit: "inherit"
                case .home: "home"
                case .path(let path): path
                }
            }),
        ConfigKey(
            "scrollback-limit", .newTabs,
            help: ["How much history each tab keeps, from 0 to 1G, like 50MB. K, M and G count in 1024s."],
            read: { value, config throws(ConfigValueError) in config.scrollbackLimit = try Value.bytes(value) },
            write: { Value.formatBytes($0.scrollbackLimit) }),
    ]

    // MARK: - The template

    /// The file Settings… creates when there is none: every setting, commented out at its
    /// default, with what it does.
    public static var template: String {
        let defaults = Config()
        var out = """
            # Death Race for Code settings
            #
            # Each setting is a line of the form `name = value`. Lines starting with # are
            # comments: remove the # in front of a setting to change it. Reload Configuration
            # (⌘⇧, in the Death Race menu) applies changes to the open windows; settings under
            # New tabs apply to tabs opened afterwards.

            """
        for section in ConfigKey.Section.allCases {
            out += "\n# ---- \(section.rawValue) ----\n"
            for key in keys where key.section == section {
                out += "\n"
                for line in key.help { out += "# \(line)\n" }
                if let value = key.write(defaults) {
                    out += "# \(key.name) = \(value)\n"
                } else if let example = key.example {
                    out += "# \(example)\n"
                }
            }
        }
        return out
    }
}

/// Reading and writing the kinds of values settings take.
enum Value {
    static func bool(_ text: Substring) throws(ConfigValueError) -> Bool {
        switch text {
        case "true": return true
        case "false": return false
        default: throw ConfigValueError("Use true or false.")
        }
    }

    static func number(_ text: Substring, in range: ClosedRange<Double>) throws(ConfigValueError) -> Double {
        guard let value = Double(text), value.isFinite, range.contains(value) else {
            throw ConfigValueError("Use a number from \(format(range.lowerBound)) to \(format(range.upperBound)).")
        }
        return value
    }

    static func choice<Choice: RawRepresentable & CaseIterable>(_ text: Substring) throws(ConfigValueError) -> Choice
    where Choice.RawValue == String {
        if let choice = Choice(rawValue: String(text)) { return choice }
        let names = Choice.allCases.map(\.rawValue)
        throw ConfigValueError("Use \(names.dropLast().joined(separator: ", ")) or \(names.last ?? "").")
    }

    /// `#RRGGBB`, `#RGB` (each digit doubled, as in CSS) or `RRGGBB`.
    static func color(_ text: Substring) throws(ConfigValueError) -> RGB {
        let hex = text.hasPrefix("#") ? text.dropFirst() : text
        guard hex.count == 3 || hex.count == 6, hex.allSatisfy(\.isHexDigit), let value = UInt32(hex, radix: 16)
        else {
            throw ConfigValueError("Use a color like #EC48C4.")
        }
        if hex.count == 6 { return RGB(hex: value) }
        let r = UInt8(value >> 8 & 0xF) * 17
        let g = UInt8(value >> 4 & 0xF) * 17
        let b = UInt8(value & 0xF) * 17
        return RGB(r, g, b)
    }

    /// `N=#RRGGBB`, N from 0 to 255.
    static func paletteEntry(_ text: Substring) throws(ConfigValueError) -> (Int, RGB) {
        let parts = text.split(separator: "=", maxSplits: 1)
        guard parts.count == 2,
            let index = Int(parts[0].trimmingSpaces), (0...255).contains(index)
        else {
            throw ConfigValueError("Use a color number from 0 to 255 and a color, like 1=#FF5277.")
        }
        return (index, try color(parts[1].trimmingSpaces))
    }

    /// `100x30`: columns by rows.
    static func gridSize(_ text: Substring) throws(ConfigValueError) -> GridSize {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let columns = Int(parts[0]), let rows = Int(parts[1]),
            (10...1000).contains(columns), (2...1000).contains(rows)
        else {
            throw ConfigValueError("Use columns x rows, like 100x30 (10 to 1000 columns, 2 to 1000 rows).")
        }
        return GridSize(columns: columns, rows: rows)
    }

    /// A byte count: digits, then optionally K, M or G (each 1024 times the last), with an
    /// optional B or iB after: `50MB`, `512K`, `2GiB`, `1048576`.
    static func bytes(_ text: Substring) throws(ConfigValueError) -> Int {
        let failure = ConfigValueError("Use a size from 0 to 1G, like 50MB.")
        var digits = Substring(text.uppercased())
        if digits.hasSuffix("IB") {
            digits = digits.dropLast(2)
        } else if digits.hasSuffix("B") {
            digits = digits.dropLast()
        }
        var scale = 1
        switch digits.last {
        case "K": scale = 1 << 10
        case "M": scale = 1 << 20
        case "G": scale = 1 << 30
        default: break
        }
        if scale > 1 { digits = digits.dropLast() }
        guard let count = Int(digits.trimmingSpaces), count >= 0, count <= (1 << 30) / scale else { throw failure }
        return count * scale
    }

    /// What to say about a theme name that matches none: the closest, if it looks like a
    /// typo, else every name.
    static func themeHint(for text: Substring) -> String {
        let wanted = ThemeCatalog.folded(text)
        var best: (id: String, distance: Int)?
        for theme in ThemeCatalog.all {
            let distance = min(
                ConfigParser.editDistance(wanted, ThemeCatalog.folded(theme.id)),
                ConfigParser.editDistance(wanted, ThemeCatalog.folded(theme.name)))
            if distance < best?.distance ?? Int.max { best = (theme.id, distance) }
        }
        if let best, best.distance <= 3 { return "Did you mean \(best.id)?" }
        let ids = ThemeCatalog.all.map(\.id)
        return "Use \(ids.dropLast().joined(separator: ", ")) or \(ids.last ?? "")."
    }

    static func format(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }

    static func format(_ color: RGB) -> String {
        let digits = Array("0123456789ABCDEF")
        var out = "#"
        for byte in [color.red, color.green, color.blue] {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0xF)])
        }
        return out
    }

    static func formatBytes(_ count: Int) -> String {
        for (suffix, scale) in [("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10)] where count >= scale {
            if count % scale == 0 { return "\(count / scale)\(suffix)" }
        }
        return String(count)
    }
}

extension StringProtocol {
    /// Without spaces and tabs at either end.
    var trimmingSpaces: Substring {
        var text = Substring(self)
        while let first = text.first, first == " " || first == "\t" { text.removeFirst() }
        while let last = text.last, last == " " || last == "\t" { text.removeLast() }
        return text
    }
}
