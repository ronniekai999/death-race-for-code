import ConfigKit
import Testing

@testable import AppCore

@Suite struct FirstRunTests {
    @Test func itGreetsOnlyAnInstallWithNothingSetUp() {
        #expect(FirstRun.shouldShow(alreadyShown: false, settingsFileExists: false, hostCount: 0))
        // Shown once, whatever was chosen in it.
        #expect(!FirstRun.shouldShow(alreadyShown: true, settingsFileExists: false, hostCount: 0))
        // Someone who has been here before the welcome existed.
        #expect(!FirstRun.shouldShow(alreadyShown: false, settingsFileExists: true, hostCount: 0))
        #expect(!FirstRun.shouldShow(alreadyShown: false, settingsFileExists: false, hostCount: 2))
    }

    @Test func everyOfferedShortcutParsesAndReadsBackAsItsButton() {
        for shortcut in FirstRun.shortcuts where !FirstRun.isOff(shortcut.value) {
            let parsed = KeyShortcut(parsing: shortcut.value)
            #expect(parsed != nil, "\(shortcut.value) doesn't parse")
            #expect(parsed?.description == shortcut.title, "\(shortcut.value) reads back differently")
        }
        #expect(FirstRun.shortcuts.first?.value == Config().lucidDreamsHotkey)
        #expect(FirstRun.shortcuts.filter { FirstRun.isOff($0.value) }.count == 1)
    }

    @Test func aSettingMatchesTheShortcutItMeansHoweverItIsWritten() {
        #expect(FirstRun.shortcut(matching: "⌥Space")?.value == "⌥Space")
        #expect(FirstRun.shortcut(matching: "opt+space")?.value == "⌥Space")
        #expect(FirstRun.shortcut(matching: "ctrl+opt+space")?.value == "⌃⌥Space")
        #expect(FirstRun.shortcut(matching: " none ")?.title == "Off")
        #expect(FirstRun.shortcut(matching: "")?.title == "Off")
        // One the welcome doesn't offer is nobody's button.
        #expect(FirstRun.shortcut(matching: "cmd+shift+space") == nil)
        #expect(FirstRun.shortcut(matching: "not a shortcut") == nil)
    }

    @Test func theNoteSaysWhenMacOSRefusedTheShortcut() {
        #expect(FirstRun.shortcutNote("opt+space", works: true) == "Press ⌥Space in any app to try it.")
        #expect(
            FirstRun.shortcutNote("⌥Space", works: false)
                == "macOS didn’t allow ⌥Space, so it does nothing. Choose another.")
        #expect(FirstRun.shortcutNote("none", works: true).hasPrefix("No shortcut."))
    }

    @Test func namesAreListedAsASentenceWithAUnit() {
        #expect(FirstRun.names([]) == "")
        #expect(FirstRun.names(["prod-api"]) == "prod-api")
        #expect(FirstRun.names(["prod-api", "nas-999"]) == "prod-api and nas-999")
        #expect(FirstRun.names(["prod-api", "nas-999", "pi-hole"]) == "prod-api, nas-999 and pi-hole")
        #expect(FirstRun.names(["a", "b", "c", "d"]) == "a, b, c and 1 more host")
        #expect(FirstRun.names(["a", "b", "c", "d", "e"]) == "a, b, c and 2 more hosts")
        #expect(FirstRun.added(count: 0) == "They’re in WRLD already.")
        #expect(FirstRun.added(count: 1) == "Added 1 host to WRLD.")
        #expect(FirstRun.added(count: 12) == "Added 12 hosts to WRLD.")
    }
}
