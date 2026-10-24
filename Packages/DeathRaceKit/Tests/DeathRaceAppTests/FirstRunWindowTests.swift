import AppCore
import AppKit
import ConfigKit
import Foundation
import Testing

@testable import DeathRaceApp

// In the window tests' suite, so they run one at a time with the windows they share the
// screen with.
extension WindowTests {
    @Test func theWelcomeSavesEachChoiceAsItIsMadeAndTakesTheTheme() async throws {
        let home = try makeFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        // Defaults of its own: the "shown" mark never lands in the test runner's.
        let suite = "deathrace-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppDelegate(
            makeSession: { _, configuration, _, _ in FakeSession(configuration) },
            configStore: ConfigStore(environment: ["XDG_CONFIG_HOME": home.path]), defaults: defaults)
        app.newWindow(nil)
        let controller = try #require(app.windows.first)
        defer { controller.window?.close() }

        app.showWelcome(nil)
        let sheet = try #require(app.firstRunSheet)
        defer { sheet.close() }
        await eventually(within: 2) { controller.window?.attachedSheet === sheet.panel }
        #expect(controller.window?.attachedSheet === sheet.panel)
        #expect(defaults.bool(forKey: FirstRun.shownKey))
        // Asked for again, it is the same sheet brought forward rather than a second one.
        app.showWelcome(nil)
        #expect(app.firstRunSheet === sheet)
        // No WRLD in a window test, so nothing to bring in from ~/.ssh/config.
        #expect(sheet.model.importable.isEmpty)

        // A theme: its line in the file, and the window behind and the welcome in its colours.
        sheet.model.choose(theme: "righteous")
        let file = try String(contentsOf: app.configStore.url, encoding: .utf8)
        #expect(file.split(separator: "\n").contains("theme = righteous"))
        #expect(sheet.model.theme == "righteous")
        #expect(sheet.model.palette.isLight)
        #expect(sheet.panel.appearance?.name == .aqua)
        #expect(controller.window?.appearance?.name == .aqua)

        // A shortcut: the line Settings doesn't show, written as its button says it.
        sheet.model.choose(shortcut: "⌃⌥Space")
        #expect(app.configStore.config.lucidDreamsHotkey == "⌃⌥Space")
        #expect(sheet.model.shortcut == "⌃⌥Space")
        #expect(FirstRun.shortcut(matching: sheet.model.shortcut)?.title == "⌃⌥Space")
        // With no hotkey controller nothing could have refused it.
        #expect(sheet.model.shortcutWorks)
        #expect(sheet.model.problem == nil)

        sheet.model.done()
        #expect(app.firstRunSheet == nil)
        await eventually(within: 2) { controller.window?.attachedSheet == nil }
        #expect(controller.window?.attachedSheet == nil)
    }

    /// A choice that can't be saved says why, and the welcome goes on showing what the file
    /// says rather than what was clicked.
    @Test func aWelcomeChoiceThatCannotBeSavedSaysWhy() async throws {
        let home = try makeFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        let suite = "deathrace-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppDelegate(
            makeSession: { _, configuration, _, _ in FakeSession(configuration) },
            configStore: ConfigStore(environment: ["XDG_CONFIG_HOME": home.path]), defaults: defaults)
        app.newWindow(nil)
        let controller = try #require(app.windows.first)
        defer { controller.window?.close() }
        app.showWelcome(nil)
        let sheet = try #require(app.firstRunSheet)
        defer { sheet.close() }

        // Neither the settings folder nor a file in it can be made.
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: home.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path) }
        sheet.model.choose(theme: "righteous")
        #expect(sheet.model.problem?.hasPrefix("Death Race could not save the change") == true)
        #expect(sheet.model.theme == Config().namedTheme.id)
        #expect(!sheet.model.palette.isLight)
    }
}

/// The welcome's offer to add what ~/.ssh/config names, apart from WRLD.
@MainActor
@Suite struct FirstRunModelTests {
    func model(offering names: [String]) -> FirstRunModel {
        FirstRunModel(
            palette: .midnight, theme: "legends-never-die", shortcut: "⌥Space", shortcutWorks: true,
            importable: names)
    }

    @Test func addingHostsSaysHowManyAndOffersNoMore() {
        let model = model(offering: ["prod-api", "nas-999"])
        var asked: [[String]] = []
        model.onImport = { names in
            asked.append(names)
            return nil
        }
        model.importHosts()
        #expect(asked == [["prod-api", "nas-999"]])
        #expect(model.added == 2)
        #expect(model.importable.isEmpty)
        #expect(model.problem == nil)
        // Nothing left to offer, so nothing is asked for.
        model.importHosts()
        #expect(asked.count == 1)
    }

    @Test func aFailedAddSaysWhyAndKeepsTheOffer() {
        let model = model(offering: ["prod-api"])
        model.onImport = { _ in "WRLD couldn’t save wrld.json." }
        model.importHosts()
        #expect(model.problem == "WRLD couldn’t save wrld.json.")
        #expect(model.added == 0)
        #expect(model.importable == ["prod-api"])
    }
}
