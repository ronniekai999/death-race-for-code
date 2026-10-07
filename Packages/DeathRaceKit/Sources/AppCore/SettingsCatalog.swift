import ConfigKit

/// The Settings window's pages. Every control edits one line of the settings file through
/// `ConfigEditor`, so the file stays the one source of truth and hand edits show up.
///
/// The single-color overrides (`background`, `palette` and the rest) stay in the file: the
/// window offers whole themes.
public enum SettingsCatalog {
    public enum Page: String, CaseIterable, Sendable, Identifiable {
        case general = "General"
        case appearance = "Appearance"
        case terminal = "Terminal"
        case keys = "Keys"
        case energy = "Energy"
        case wrld = "WRLD"
        case advanced = "Advanced"

        public var id: String { rawValue }

        /// The SF Symbol beside the page's name.
        public var symbol: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintpalette"
            case .terminal: "terminal"
            case .keys: "keyboard"
            case .energy: "leaf"
            case .wrld: "globe"
            case .advanced: "slider.horizontal.3"
            }
        }
    }

    public struct Choice: Sendable, Equatable {
        /// What the file says.
        public var value: String
        /// What the window says.
        public var label: String

        public init(_ value: String, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    public enum Control: Sendable, Equatable {
        case toggle
        case choice([Choice])
        case number(range: ClosedRange<Double>, step: Double, unit: String)
        /// Whole megabytes, written as "50MB".
        case megabytes(range: ClosedRange<Int>)
        /// Free text; empty goes back to the default.
        case text(placeholder: String)
        /// A font family, or for italics none (the main font's own).
        case fontFamily(italic: Bool)
        /// The eight themes, as swatches.
        case theme
        /// Columns by rows.
        case gridSize
    }

    public struct Setting: Sendable, Equatable, Identifiable {
        /// The setting's name in the file.
        public var key: String
        public var label: String
        public var control: Control
        /// A line under the control, when the label is not enough.
        public var note: String?

        public var id: String { key }

        init(_ key: String, _ label: String, _ control: Control, note: String? = nil) {
            self.key = key
            self.label = label
            self.control = control
            self.note = note
        }
    }

    public struct Group: Sendable, Equatable, Identifiable {
        public var title: String
        public var settings: [Setting]

        public var id: String { title }
    }

    /// Settings left to the file.
    public static let fileOnly: Set<String> = [
        "background", "foreground", "cursor-color", "cursor-text", "selection-background", "selection-foreground",
        "palette", "bold-is-bright", "lucid-dreams-hotkey",
    ]

    public static func groups(on page: Page) -> [Group] {
        switch page {
        case .general:
            [
                Group(
                    title: "Windows",
                    settings: [
                        Setting(
                            "confirm-close", "Ask before closing programs that are still running", .toggle),
                        Setting(
                            "pane-headers", "Pane headers",
                            .choice([
                                Choice("split", "While a tab is split"), Choice("always", "Always"),
                                Choice("never", "Never"),
                            ])),
                        Setting("window-size", "New window size", .gridSize, note: "In columns and rows."),
                    ]),
                Group(
                    title: "Sessions",
                    settings: [
                        Setting(
                            "legends-never-die", "Keep local shells running when Death Race quits", .toggle,
                            note: "They go back in their windows next time. Sessions on a host are not kept."),
                        Setting(
                            "shell-integration", "Let your shell say where each command begins and ends", .toggle,
                            note: "Where a command's duration and its pass or fail mark come from. zsh and fish "
                                + "are set up through the environment; bash is offered one line for your ~/.bashrc."),
                    ]),
                Group(
                    title: "New tabs",
                    settings: [
                        Setting(
                            "working-directory", "Start in",
                            .choice([Choice("inherit", "The active pane's folder"), Choice("home", "Home")]),
                            note: "A particular folder can be set in the settings file."),
                        Setting(
                            "command", "Run", .text(placeholder: "Your login shell"),
                            note: "A program and its arguments, like /opt/homebrew/bin/fish --login."),
                    ]),
            ]
        case .appearance:
            [
                Group(title: "Theme", settings: [Setting("theme", "Theme", .theme)]),
                Group(
                    title: "Text",
                    settings: [
                        Setting("font-family", "Font", .fontFamily(italic: false)),
                        Setting("font-size", "Size", .number(range: 6...144, step: 1, unit: "pt")),
                        Setting("font-family-italic", "Italics", .fontFamily(italic: true)),
                        Setting("font-thicken", "Thicken strokes", .toggle),
                    ]),
                Group(
                    title: "Window",
                    settings: [
                        Setting("starfield", "Starfield behind the terminal", .toggle),
                        Setting("conversations", "Mark each command and how long it took", .toggle),
                        Setting(
                            "fast-threshold-milliseconds", "Show a command's time when it is over",
                            .number(range: 0...60_000, step: 250, unit: "ms")),
                        Setting("window-padding-x", "Side padding", .number(range: 0...40, step: 1, unit: "pt")),
                        Setting(
                            "window-padding-y", "Top and bottom padding", .number(range: 0...40, step: 1, unit: "pt")),
                    ]),
                Group(
                    title: "Cursor",
                    settings: [
                        Setting(
                            "cursor-style", "Shape",
                            .choice([Choice("block", "Block"), Choice("bar", "Bar"), Choice("underline", "Underline")])
                        ),
                        Setting("cursor-style-blink", "Blink", .toggle),
                    ]),
            ]
        case .terminal:
            [
                Group(
                    title: "Keyboard and mouse",
                    settings: [
                        Setting(
                            "option-as-meta", "Option as Meta",
                            .choice([
                                Choice("left", "Left Option"), Choice("right", "Right Option"),
                                Choice("both", "Both"), Choice("none", "Neither"),
                            ]),
                            note: "The other Option key types your layout's special characters."),
                        Setting(
                            "mouse-scroll-multiplier", "Lines per wheel notch",
                            .number(range: 1...20, step: 1, unit: "lines")),
                        Setting("mouse-scroll-alternate", "Wheel scrolls full-screen programs", .toggle),
                        Setting("copy-on-select", "Copy text when selected", .toggle),
                    ]),
                Group(
                    title: "Safety",
                    settings: [
                        Setting("paste-protection", "Ask before pasting commands that would run", .toggle),
                        Setting(
                            "clipboard-write", "Programs may copy to the clipboard",
                            .choice([Choice("allow", "Yes"), Choice("ask", "Ask each time"), Choice("deny", "No")])),
                        Setting(
                            "secure-keyboard-entry", "Secure Keyboard Entry",
                            .choice([
                                Choice("auto", "For passwords, or from the menu"),
                                Choice("always", "Always"), Choice("manual", "From the menu"),
                            ])),
                    ]),
                Group(
                    title: "History and bell",
                    settings: [
                        Setting("scrollback-limit", "History per tab", .megabytes(range: 0...1024)),
                        Setting(
                            "bell", "Bell",
                            .choice([Choice("system", "Sound"), Choice("visual", "Flash"), Choice("none", "Nothing")])),
                    ]),
            ]
        case .energy:
            [
                Group(
                    title: "Frame rate",
                    settings: [
                        Setting("follow-low-power-mode", "Follow Low Power Mode", .toggle),
                        Setting(
                            "output-frame-rate-cap", "Cap busy output at 60 frames per second", .toggle,
                            note: "Typing and scrolling keep the display's full rate."),
                    ])
            ]
        case .wrld:
            [
                Group(
                    title: "What WRLD finds out by itself",
                    settings: [
                        Setting(
                            "wrld-check-hosts", "Check how quickly Legends answer", .toggle,
                            note:
                                "While the sidebar or WRLD shows them, five minutes apart, never through a jump host. Each check is a line in the server's log."
                        ),
                        Setting(
                            "wrld-host-os", "Read what each host runs", .toggle,
                            note: "From /etc/os-release, over a connection you already have, at most once a week."),
                    ])
            ]
        case .keys, .advanced:
            []
        }
    }

    /// Every setting the window shows, page by page.
    public static var allSettings: [Setting] {
        Page.allCases.flatMap { groups(on: $0) }.flatMap(\.settings)
    }

    /// The setting for `key`, if the window shows it.
    public static func setting(_ key: String) -> Setting? {
        allSettings.first { $0.key == key }
    }

    // MARK: - Values

    /// A control's value.
    public enum Value: Sendable, Equatable {
        case bool(Bool)
        case text(String)
        case number(Double)
        case grid(columns: Int, rows: Int)
    }

    /// What `config` holds for `setting`, in the control's terms.
    public static func value(of setting: Setting, in config: Config) -> Value {
        let written = ConfigSchema.key(named: setting.key)?.value(in: config) ?? ""
        switch setting.control {
        case .toggle:
            return .bool(written == "true")
        case .number:
            return .number(Double(written) ?? 0)
        case .megabytes:
            return .number(Double(config.scrollbackLimit / (1024 * 1024)))
        case .gridSize:
            return .grid(columns: config.windowSize.columns, rows: config.windowSize.rows)
        case .choice, .text, .fontFamily, .theme:
            return .text(written)
        }
    }

    /// What the file should say for `value`; nil comments the setting out, back to its
    /// default.
    public static func text(for value: Value, of setting: Setting) -> String? {
        switch (setting.control, value) {
        case (.toggle, .bool(let on)):
            return on ? "true" : "false"
        case (.number(let range, _, _), .number(let number)):
            let clamped = min(max(number, range.lowerBound), range.upperBound)
            return clamped == clamped.rounded() ? String(Int(clamped)) : String(clamped)
        case (.megabytes(let range), .number(let number)):
            return "\(min(max(Int(number.rounded()), range.lowerBound), range.upperBound))MB"
        case (.gridSize, .grid(let columns, let rows)):
            return "\(max(columns, 20))x\(max(rows, 4))"
        case (_, .text(let text)):
            let trimmed = text.trimmedOfSpaces
            return trimmed.isEmpty ? nil : trimmed
        default:
            return nil
        }
    }

    /// `file` with `setting` changed to `value`, every other line as it was.
    public static func set(_ setting: Setting, to value: Value, in file: String) -> String {
        ConfigEditor.set(setting.key, to: text(for: value, of: setting), in: file)
    }
}

extension String {
    fileprivate var trimmedOfSpaces: String {
        var text = Substring(self)
        while let first = text.first, first == " " || first == "\t" { text.removeFirst() }
        while let last = text.last, last == " " || last == "\t" { text.removeLast() }
        return String(text)
    }
}
