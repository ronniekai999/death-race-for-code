import VTCore

/// Death Race's settings: what `~/.config/deathrace/config` says, with defaults for what it
/// leaves out. `ConfigSchema` lists every key; `Config.parse` reads the file.
public struct Config: Sendable, Equatable {
    // Fonts
    /// A font family name. "SF Mono" means the system's monospaced font.
    public var fontFamily = "SF Mono"
    /// Points.
    public var fontSize = 13.0
    /// Heavier strokes for light text on a dark background.
    public var fontThicken = false
    /// A family for italic text, like Monaspace Radon beside Monaspace Neon; nil uses the
    /// main family's italic.
    public var fontFamilyItalic: String?

    // Cursor
    public var cursorStyle = CursorShape.block
    /// Whether the cursor blinks when no program has asked (DECSCUSR decides otherwise).
    public var cursorStyleBlink = true

    // Keyboard and mouse
    /// Which Option keys act as Meta (Alt). The others type the layout's special characters.
    public var optionAsMeta = OptionAsMeta.left
    /// Lines per mouse-wheel notch. Trackpads scroll by distance and ignore it.
    public var mouseScrollMultiplier = 3.0
    /// On the alternate screen (less, vim), the wheel sends arrow keys.
    public var mouseScrollAlternate = true
    /// The global hotkey that shows and hides Lucid Dreams, the notch quick-terminal, written
    /// as macOS writes shortcuts ("⌥Space"). "none" turns the hotkey off; the menu and the
    /// menu-bar icon still open it. The app reads it with `KeyShortcut(parsing:)`.
    public var lucidDreamsHotkey = "⌥Space"

    // Window
    /// Points between the window edges and the text.
    public var windowPaddingX = 8.0
    public var windowPaddingY = 6.0
    /// The size of new windows, in cells.
    public var windowSize = GridSize(columns: 100, rows: 30)
    /// Faint stars behind the panes and in the terminal's empty space (dark themes only).
    public var starfield = true
    /// When panes show a header with the program, directory and branch.
    public var paneHeaders = PaneHeaders.split

    // Colors
    /// The theme's id in `ThemeCatalog`.
    public var themeID = ThemeCatalog.default.id
    /// Colors the file sets on top of the theme.
    public var colorOverrides = ColorOverrides()

    // Safety
    public var confirmClose = true
    /// Ask before pasting text that would run commands the moment it lands.
    public var pasteProtection = true
    public var clipboardWrite = ClipboardWrite.allow
    public var secureKeyboardEntry = SecureKeyboardEntry.auto

    // Energy
    /// In Low Power Mode, draw at most 60 frames a second for typing and 30 for output.
    public var followLowPowerMode = true
    /// Draw busy output at most 60 frames a second; typing and scrolling keep the display's
    /// full rate.
    public var outputFrameRateCap = true

    // WRLD
    /// Check how quickly Legends answer while the sidebar or the WRLD window shows them.
    public var checkHosts = true
    /// Whether local shells are kept running by `legendsd` when the app goes.
    public var legendsNeverDie = true
    /// Whether a shell is told to report where its prompts and commands begin and end, which
    /// is what Conversations, Fast and Ring Ring are built on.
    public var shellIntegration = true
    /// Whether what the shell reports is drawn: a rail beside each command, a band behind the
    /// one you are in, and a badge saying how long it took.
    public var conversations = true
    /// A command faster than this gets no badge. One that failed gets one however fast it was.
    public var fastThresholdMilliseconds = 1_000
    /// Read what each host runs from its /etc/os-release, at most weekly.
    public var readHostOS = true

    // Other
    public var copyOnSelect = false
    public var bell = Bell.system

    // New tabs
    /// What new tabs run; nil runs your login shell.
    public var command: String?
    public var workingDirectory = WorkingDirectory.inherit
    /// Bytes of scrollback per tab.
    public var scrollbackLimit = 50 * 1024 * 1024

    public init() {}

    /// The theme `theme` names.
    public var namedTheme: NamedTheme { ThemeCatalog.theme(id: themeID) ?? ThemeCatalog.default }

    /// The terminal's colors: the theme's, with the file's color settings on top.
    public var theme: Theme { colorOverrides.applied(to: namedTheme.terminal) }

    /// The window's colors around the terminal.
    public var chrome: ChromeColors { namedTheme.chrome }

    /// The settings in `text`, and what was wrong with it. Every line that could not be used
    /// leaves its setting at the default; nothing in the file can stop the app starting.
    public static func parse(_ text: String) -> (config: Config, diagnostics: [ConfigDiagnostic]) {
        var config = Config()
        let diagnostics = ConfigParser.parse(text, into: &config)
        return (config, diagnostics)
    }

    /// `command` split into words the way a shell would, without expanding anything:
    /// whitespace separates them, and quotes ('…' or "…") or a backslash keep spaces in one.
    public var commandArguments: [String]? {
        guard let command else { return nil }
        let words = ShellWords.split(command)
        return words.isEmpty ? nil : words
    }
}

public struct GridSize: Sendable, Hashable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

public enum OptionAsMeta: String, CaseIterable, Sendable {
    case left, right, both
    /// Neither Option key: both type special characters (German, French and Nordic layouts
    /// need them for brackets and braces).
    case neither = "none"

    public var usesLeft: Bool { self == .left || self == .both }
    public var usesRight: Bool { self == .right || self == .both }
}

public enum ClipboardWrite: String, CaseIterable, Sendable {
    /// Programs may set the clipboard (OSC 52) from the focused tab.
    case allow
    /// Ask each time.
    case ask
    case deny
}

public enum SecureKeyboardEntry: String, CaseIterable, Sendable {
    /// On while a program reads a password, or while the menu item is checked.
    case auto
    /// On whenever Death Race is the active app.
    case always
    /// Only while the menu item is checked.
    case manual
}

public enum Bell: String, CaseIterable, Sendable {
    case system, visual
    case silent = "none"
}

public enum PaneHeaders: String, CaseIterable, Sendable {
    /// Only while a tab is split into panes.
    case split
    case always
    case never
}

public enum WorkingDirectory: Sendable, Hashable {
    /// The focused tab's directory, else home.
    case inherit
    case home
    /// An absolute path; a leading `~` is your home directory.
    case path(String)
}

/// Colors for the terminal: the 256-color palette with the default foreground, background
/// and cursor colors, plus what only the app draws.
public struct Theme: Sendable, Equatable {
    public var palette: Palette
    /// The character under a block cursor; nil uses the background color.
    public var cursorText: RGB?
    public var selectionBackground: RGB
    /// Selected text; nil keeps each character's own color.
    public var selectionForeground: RGB?
    /// Bold text in colors 0–7 uses their bright versions, 8–15, as old terminals did.
    public var boldIsBright: Bool

    public init(
        palette: Palette, cursorText: RGB? = nil, selectionBackground: RGB, selectionForeground: RGB? = nil,
        boldIsBright: Bool = false
    ) {
        self.palette = palette
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.boldIsBright = boldIsBright
    }

    /// The default: MenuGlance's palette (`Palette.legendsNeverDie`) and a violet selection
    /// the default text holds 8.7:1 on.
    public static let legendsNeverDie = Theme(
        palette: .legendsNeverDie, selectionBackground: RGB(hex: 0x463279))
}

/// The color settings in the file, applied on top of whichever theme it names, wherever the
/// `theme` line is.
public struct ColorOverrides: Sendable, Equatable {
    public var background: RGB?
    public var foreground: RGB?
    public var cursor: RGB?
    public var cursorText: RGB?
    public var selectionBackground: RGB?
    public var selectionForeground: RGB?
    /// Palette entries 0–255.
    public var palette: [Int: RGB] = [:]
    public var boldIsBright: Bool?

    public init() {}

    /// How many of the theme's colors the file changes.
    public var count: Int {
        let single: [RGB?] = [background, foreground, cursor, cursorText, selectionBackground, selectionForeground]
        return single.count { $0 != nil } + palette.count
    }

    public func applied(to theme: Theme) -> Theme {
        var theme = theme
        if let background { theme.palette.background = background }
        if let foreground { theme.palette.foreground = foreground }
        if let cursor { theme.palette.cursor = cursor }
        if let cursorText { theme.cursorText = cursorText }
        if let selectionBackground { theme.selectionBackground = selectionBackground }
        if let selectionForeground { theme.selectionForeground = selectionForeground }
        for (index, color) in palette { theme.palette.colors[index] = color }
        if let boldIsBright { theme.boldIsBright = boldIsBright }
        return theme
    }
}
