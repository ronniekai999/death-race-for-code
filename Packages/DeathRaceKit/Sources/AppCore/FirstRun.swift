import Foundation

/// The welcome a new install opens with, apart from its views: whether to show it, the
/// shortcuts it offers for Lucid Dreams, and what it says about the hosts `~/.ssh/config`
/// names. Three choices that otherwise wait in Settings, WRLD and the settings file for
/// someone to go looking for them.
public enum FirstRun {
    /// Where the app notes that the welcome has been shown.
    public static let shownKey = "FirstRunShown"

    /// Once, on a launch with nothing set up yet: no settings file and no host in WRLD.
    /// Someone with either found their way in before the welcome existed, and an update
    /// shouldn't greet them as a stranger. Help › Welcome to Death Race for Code opens it at
    /// any time.
    public static func shouldShow(alreadyShown: Bool, settingsFileExists: Bool, hostCount: Int) -> Bool {
        !alreadyShown && !settingsFileExists && hostCount == 0
    }

    // MARK: - Lucid Dreams' shortcut

    /// A shortcut the welcome offers for Lucid Dreams.
    public struct Shortcut: Equatable, Sendable, Identifiable {
        /// What `lucid-dreams-hotkey` says for it.
        public let value: String
        /// What its button says.
        public let title: String
        /// What VoiceOver says for it: the symbols read as nothing useful.
        public let spoken: String

        public var id: String { value }
    }

    /// ⌥Space, the default, first. ⌃⌥Space beside it, for a Mac that refuses a shortcut whose
    /// only modifier is Option; ⌃` as other apps' drop-down terminals have it; and Off, which
    /// leaves the Shell menu and the menu-bar icon.
    public static let shortcuts = [
        Shortcut(value: "⌥Space", title: "⌥Space", spoken: "Option Space"),
        Shortcut(value: "⌃⌥Space", title: "⌃⌥Space", spoken: "Control Option Space"),
        Shortcut(value: "⌃`", title: "⌃`", spoken: "Control Grave Accent"),
        Shortcut(value: "none", title: "Off", spoken: "Off"),
    ]

    /// Whether `setting` turns the hotkey off, as `HotKeyController` reads it: blank or "none".
    public static func isOff(_ setting: String) -> Bool {
        let trimmed = setting.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.lowercased() == "none"
    }

    /// The offered shortcut `setting` means, however it is written: "opt+space" is ⌥Space.
    /// Nil for one the welcome doesn't offer, which is then left as it is until a button is
    /// pressed.
    public static func shortcut(matching setting: String) -> Shortcut? {
        if isOff(setting) { return shortcuts.first { isOff($0.value) } }
        guard let wanted = KeyShortcut(parsing: setting) else { return nil }
        return shortcuts.first { KeyShortcut(parsing: $0.value) == wanted }
    }

    /// Under the shortcuts: how to try the one chosen, that there is none, or that macOS
    /// refused it — which otherwise shows only as a key that does nothing.
    public static func shortcutNote(_ setting: String, works: Bool) -> String {
        if isOff(setting) { return "No shortcut. The Shell menu and the menu-bar icon still open it." }
        let shown = KeyShortcut(parsing: setting)?.description ?? setting
        return works
            ? "Press \(shown) in any app to try it."
            : "macOS didn’t allow \(shown), so it does nothing. Choose another."
    }

    // MARK: - Hosts in ~/.ssh/config

    /// A few of the names, then how many more: "prod-api, nas-999, pi-hole and 9 more hosts".
    public static func names(_ names: [String], showing limit: Int = 3) -> String {
        let shown = Array(names.prefix(max(limit, 1)))
        let rest = names.count - shown.count
        var parts = shown
        if rest > 0 { parts.append("\(rest) more \(rest == 1 ? "host" : "hosts")") }
        guard let last = parts.popLast() else { return "" }
        return parts.isEmpty ? last : parts.joined(separator: ", ") + " and " + last
    }

    /// After the button: "Added 3 hosts to WRLD."
    public static func added(count: Int) -> String {
        "Added \(WRLDBoard.counted(count, "host")) to WRLD."
    }
}
