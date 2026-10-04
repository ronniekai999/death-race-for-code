/// Everything the app can be asked to do from a menu, a shortcut or Hear Me Calling. One
/// table drives the menu bar, the palette's actions and Settings › Keys, so a shortcut can
/// never say one thing in a menu and another in the palette.
public enum ActionID: String, CaseIterable, Sendable {
    // The app menu
    case about, settings, openSettingsFile, reloadConfiguration, secureKeyboardEntry, hide, hideOthers, showAll, quit
    // Shell
    case newWindow, newTab, newHost, openWRLD, splitRight, splitDown, armedAndDangerous, closePane, closeTab,
        closeWindow
    // Edit
    case copy, paste, selectAll, saveSelectionToWishingWell, clearToStart, clearScrollback
    // View
    case hearMeCalling, toggleSidebar, bigger, smaller, actualSize, zoomPane, equalizePanes
    // Window
    case minimize, zoomWindow, showPreviousTab, showNextTab, moveTabToNewWindow
    case previousPane, nextPane, focusPaneLeft, focusPaneRight, focusPaneUp, focusPaneDown
    case moveDividerLeft, moveDividerRight, moveDividerUp, moveDividerDown, bringAllToFront
}

/// A key and its modifiers, written as macOS writes them: "⌃⌥⇧⌘", then the key.
public struct KeyShortcut: Hashable, Sendable, CustomStringConvertible {
    public enum Key: Hashable, Sendable {
        case character(Character)
        case left, right, up, down
        case returnKey
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    public var key: Key
    public var modifiers: Modifiers
    /// Matched by the key's position rather than the character it types (the number row,
    /// the brackets), so the shortcut works on layouts where those keys type other things.
    public var positional: Bool

    public init(_ key: Key, _ modifiers: Modifiers = .command, positional: Bool = false) {
        self.key = key
        self.modifiers = modifiers
        self.positional = positional
    }

    public var description: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .character(let character): text += character == " " ? "Space" : String(character).uppercased()
        case .left: text += "←"
        case .right: text += "→"
        case .up: text += "↑"
        case .down: text += "↓"
        case .returnKey: text += "↩"
        }
        return text
    }
}

extension KeyShortcut {
    /// Reads a shortcut written as macOS writes it ("⌥Space", "⌃⌘P") or in words
    /// ("opt+space", "ctrl+cmd+p", joined by +, - or spaces); nil when it can't be understood.
    /// The key is a letter, digit or punctuation, or one of Space, ←/→/↑/↓ (or left/right/up/
    /// down) and Return (or enter). Letters fold to one case, so "cmd+p" and "⌘P" are the same.
    public init?(parsing text: String) {
        var modifiers = Modifiers()
        var rest = Self.trimmed(Substring(text))
        guard !rest.isEmpty else { return nil }
        // Leading modifier symbols, in any order: ⌃⌥⇧⌘.
        while let first = rest.first, let modifier = Self.symbolModifier(first) {
            modifiers.insert(modifier)
            rest = Self.trimmed(rest.dropFirst())
        }
        guard !rest.isEmpty else { return nil }
        let keyToken: String
        if rest.count > 1, rest.contains(where: Self.isSeparator) {
            // "opt+space", "ctrl cmd p": words for the modifiers, then the key last.
            let tokens = rest.split(whereSeparator: Self.isSeparator)
            guard let last = tokens.last else { return nil }
            for token in tokens.dropLast() {
                guard let modifier = Self.wordModifier(token) else { return nil }
                modifiers.insert(modifier)
            }
            keyToken = String(last)
        } else {
            keyToken = String(rest)
        }
        guard let key = Self.key(from: keyToken) else { return nil }
        self.init(key, modifiers)
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character == "+" || character == "-" || character == " " || character == "\t"
    }

    private static func symbolModifier(_ character: Character) -> Modifiers? {
        switch character {
        case "⌃": .control
        case "⌥": .option
        case "⇧": .shift
        case "⌘": .command
        default: nil
        }
    }

    private static func wordModifier(_ token: some StringProtocol) -> Modifiers? {
        switch token.lowercased() {
        case "ctrl", "control", "⌃": .control
        case "opt", "option", "alt", "⌥": .option
        case "shift", "⇧": .shift
        case "cmd", "command", "super", "⌘": .command
        default: nil
        }
    }

    private static func key(from token: String) -> Key? {
        switch token.lowercased() {
        case "space", "␣": return .character(" ")
        case "left", "←": return .left
        case "right", "→": return .right
        case "up", "↑": return .up
        case "down", "↓": return .down
        case "return", "enter", "↩", "⏎": return .returnKey
        default:
            // Letters fold to lower case, the form the catalog stores; `description` upper-cases
            // for display, so "⌘N" and "cmd+n" both read back as `.character("n")`.
            guard token.count == 1, let character = token.lowercased().first else { return nil }
            return .character(character)
        }
    }

    private static func trimmed(_ text: Substring) -> Substring {
        var start = text.startIndex
        var end = text.endIndex
        while start < end, text[start] == " " || text[start] == "\t" { start = text.index(after: start) }
        while start < end, text[text.index(before: end)] == " " || text[text.index(before: end)] == "\t" {
            end = text.index(before: end)
        }
        return text[start..<end]
    }
}

public struct Action: Sendable, Identifiable {
    public enum Group: String, Sendable, CaseIterable {
        case app = "App", shell = "Shell", edit = "Edit", view = "View", window = "Window"
    }

    public let id: ActionID
    /// In Title Case, as menus are.
    public let menuTitle: String
    /// In sentence case, as Hear Me Calling lists it.
    public let paletteTitle: String
    public let group: Group
    /// Other words to find it by.
    public let keywords: [String]
    public let shortcut: KeyShortcut?
    /// Shortcuts that do the same without being shown (⌘= for Bigger).
    public let alternates: [KeyShortcut]
    /// Listed in Hear Me Calling. Copy and Paste are not: the palette would take the text.
    public let inPalette: Bool

    init(
        _ id: ActionID, _ menuTitle: String, _ paletteTitle: String, _ group: Group, _ shortcut: KeyShortcut? = nil,
        alternates: [KeyShortcut] = [], keywords: [String] = [], inPalette: Bool = true
    ) {
        self.id = id
        self.menuTitle = menuTitle
        self.paletteTitle = paletteTitle
        self.group = group
        self.shortcut = shortcut
        self.alternates = alternates
        self.keywords = keywords
        self.inPalette = inPalette
    }
}

public enum ActionCatalog {
    public static func action(_ id: ActionID) -> Action {
        all.first { $0.id == id }!
    }

    public static let all: [Action] = [
        // The app menu
        Action(.about, "About Death Race for Code", "About Death Race for Code", .app, keywords: ["version"]),
        Action(.settings, "Settings…", "Settings", .app, KeyShortcut(.character(",")), keywords: ["preferences"]),
        Action(.openSettingsFile, "Open Settings File", "Open the settings file", .app, keywords: ["config", "edit"]),
        Action(
            .reloadConfiguration, "Reload Configuration", "Reload the settings file", .app,
            KeyShortcut(.character(","), [.command, .shift]), keywords: ["config"]),
        Action(
            .secureKeyboardEntry, "Secure Keyboard Entry", "Secure Keyboard Entry", .app,
            keywords: ["password", "keylogger", "lock"]),
        Action(.hide, "Hide Death Race for Code", "Hide Death Race for Code", .app, KeyShortcut(.character("h"))),
        Action(.hideOthers, "Hide Others", "Hide other apps", .app, KeyShortcut(.character("h"), [.command, .option])),
        Action(.showAll, "Show All", "Show all apps", .app),
        Action(.quit, "Quit Death Race for Code", "Quit", .app, KeyShortcut(.character("q")), keywords: ["exit"]),

        // Shell
        Action(.newWindow, "New Window", "New window", .shell, KeyShortcut(.character("n"))),
        Action(.newTab, "New Tab", "New tab", .shell, KeyShortcut(.character("t"))),
        Action(
            .newHost, "New Host…", "New host", .shell,
            keywords: ["wrld", "ssh", "server", "add host", "secure enclave", "key"]),
        Action(
            .openWRLD, "Open WRLD", "Open WRLD", .shell, KeyShortcut(.character("o")),
            keywords: ["hosts", "vault", "servers", "keys", "known hosts", "tunnels", "snippets"]),
        Action(
            .splitRight, "Split Right", "Split pane right", .shell, KeyShortcut(.character("d")),
            keywords: ["vertical", "side by side"]),
        Action(
            .splitDown, "Split Down", "Split pane down", .shell, KeyShortcut(.character("d"), [.command, .shift]),
            keywords: ["horizontal", "stacked"]),
        Action(
            .armedAndDangerous, "Armed and Dangerous", "Armed and Dangerous: type into every pane", .shell,
            KeyShortcut(.character("i"), [.command, .shift]),
            keywords: ["broadcast", "all panes", "synchronize panes", "send input", "every server"]),
        Action(.closePane, "Close", "Close pane", .shell, KeyShortcut(.character("w"))),
        Action(.closeTab, "Close Tab", "Close tab", .shell, KeyShortcut(.character("w"), [.command, .option])),
        Action(
            .closeWindow, "Close Window", "Close window", .shell, KeyShortcut(.character("w"), [.command, .shift])),

        // Edit
        Action(.copy, "Copy", "Copy", .edit, KeyShortcut(.character("c")), inPalette: false),
        Action(.paste, "Paste", "Paste", .edit, KeyShortcut(.character("v")), inPalette: false),
        Action(.selectAll, "Select All", "Select all", .edit, KeyShortcut(.character("a")), inPalette: false),
        Action(
            .saveSelectionToWishingWell, "Save Selection to Wishing Well…", "Save selection to Wishing Well", .edit,
            keywords: ["snippet", "save command", "wishing well"]),
        Action(
            .clearToStart, "Clear to Start", "Clear to start", .edit, KeyShortcut(.character("k")),
            keywords: ["clear screen", "reset", "cls"]),
        Action(
            .clearScrollback, "Clear Scrollback", "Clear scrollback", .edit,
            KeyShortcut(.character("k"), [.command, .option]), keywords: ["history"]),

        // View
        Action(
            .hearMeCalling, "Hear Me Calling…", "Hear Me Calling", .view,
            KeyShortcut(.character("p"), [.command, .shift]), keywords: ["command palette", "search"], inPalette: false),
        Action(
            .toggleSidebar, "WRLD Sidebar", "Show or hide the WRLD sidebar", .view,
            KeyShortcut(.character("s"), [.command, .control]), keywords: ["hosts", "legends", "side bar"]),
        Action(
            .bigger, "Bigger", "Make text bigger", .view, KeyShortcut(.character("+")),
            alternates: [KeyShortcut(.character("="))], keywords: ["font size", "zoom in"]),
        Action(
            .smaller, "Smaller", "Make text smaller", .view, KeyShortcut(.character("-")),
            keywords: ["font size", "zoom out"]),
        Action(
            .actualSize, "Actual Size", "Actual size", .view, KeyShortcut(.character("0")),
            keywords: ["font size", "reset"]),
        Action(
            .zoomPane, "Zoom Pane", "Zoom pane", .view, KeyShortcut(.returnKey, [.command, .shift]),
            keywords: ["maximize", "fill", "focus"]),
        Action(
            .equalizePanes, "Equalize Panes", "Equalize panes", .view,
            KeyShortcut(.character("="), [.command, .control]),
            keywords: ["balance", "even"]),

        // Window
        Action(.minimize, "Minimize", "Minimize window", .window, KeyShortcut(.character("m"))),
        Action(.zoomWindow, "Zoom", "Zoom window", .window),
        Action(
            .showPreviousTab, "Show Previous Tab", "Show previous tab", .window,
            KeyShortcut(.character("["), [.command, .shift], positional: true)),
        Action(
            .showNextTab, "Show Next Tab", "Show next tab", .window,
            KeyShortcut(.character("]"), [.command, .shift], positional: true)),
        Action(.moveTabToNewWindow, "Move Tab to New Window", "Move tab to new window", .window, keywords: ["detach"]),
        Action(
            .previousPane, "Select Previous Pane", "Select previous pane", .window,
            KeyShortcut(.character("["), positional: true)),
        Action(
            .nextPane, "Select Next Pane", "Select next pane", .window, KeyShortcut(.character("]"), positional: true)),
        Action(
            .focusPaneLeft, "Select Pane Left", "Select pane to the left", .window,
            KeyShortcut(.left, [.command, .option])),
        Action(
            .focusPaneRight, "Select Pane Right", "Select pane to the right", .window,
            KeyShortcut(.right, [.command, .option])),
        Action(.focusPaneUp, "Select Pane Above", "Select pane above", .window, KeyShortcut(.up, [.command, .option])),
        Action(
            .focusPaneDown, "Select Pane Below", "Select pane below", .window, KeyShortcut(.down, [.command, .option])),
        Action(
            .moveDividerLeft, "Move Divider Left", "Move divider left", .window,
            KeyShortcut(.left, [.command, .control]),
            keywords: ["resize pane"]),
        Action(
            .moveDividerRight, "Move Divider Right", "Move divider right", .window,
            KeyShortcut(.right, [.command, .control]), keywords: ["resize pane"]),
        Action(
            .moveDividerUp, "Move Divider Up", "Move divider up", .window, KeyShortcut(.up, [.command, .control]),
            keywords: ["resize pane"]),
        Action(
            .moveDividerDown, "Move Divider Down", "Move divider down", .window,
            KeyShortcut(.down, [.command, .control]),
            keywords: ["resize pane"]),
        Action(.bringAllToFront, "Bring All to Front", "Bring all windows to front", .window),
    ]

    /// Shortcuts the window handles by number rather than as menu items: ⌘1–⌘9 select
    /// tabs, ⌥⌘1–⌥⌘9 panes, 9 being the last. Positional, on the number row.
    public static let tabNumbers = KeyShortcut.Modifiers.command
    public static let paneNumbers: KeyShortcut.Modifiers = [.command, .option]

    /// The rows Settings › Keys lists: every shortcut, numbered ones included, by group.
    public static var reference: [(group: Action.Group, rows: [(title: String, shortcut: String)])] {
        Action.Group.allCases.map { group in
            var rows = all.filter { $0.group == group && $0.shortcut != nil }.map {
                (title: $0.paletteTitle, shortcut: $0.shortcut!.description)
            }
            if group == .window {
                rows.insert((title: "Select tab 1 to 8, or the last", shortcut: "⌘1 – ⌘9"), at: 0)
                rows.insert((title: "Select pane 1 to 8, or the last", shortcut: "⌥⌘1 – ⌥⌘9"), at: 1)
            }
            return (group, rows)
        }
    }
}
