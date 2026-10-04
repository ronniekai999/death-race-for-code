import AppCore
import AppKit
import ConfigKit
import Foundation
import Testing

@testable import DeathRaceApp

/// Waits up to `seconds` for work that arrives on the main queue: kernel file events and
/// the watcher's settling.
@MainActor
func eventually(within seconds: Double, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

// In the window tests' suite, so they run one at a time with the windows they share the
// screen with.
extension WindowTests {
    /// A folder of the test's own: the user's settings are never touched.
    func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("deathrace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// An app whose settings file is `deathrace/config` in `configHome`.
    func makeApp(configHome: URL) -> AppDelegate {
        AppDelegate(
            makeSession: { _, configuration, _ in FakeSession(configuration) },
            configStore: ConfigStore(environment: ["XDG_CONFIG_HOME": configHome.path]))
    }

    func setting(_ key: String) throws -> SettingsCatalog.Setting {
        try #require(SettingsCatalog.allSettings.first { $0.key == key })
    }

    @Test func aSettingWritesItsLineAndEveryWindowFollows() throws {
        let home = try makeFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = makeApp(configHome: home)
        app.newWindow(nil)
        let controller = try #require(app.windows.first)
        defer { controller.window?.close() }

        app.showSettings(page: .appearance)
        let settings = try #require(app.settingsWindow)
        defer { settings.window?.close() }
        settings.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(settings.window?.isVisible == true)
        #expect(settings.model.page == .appearance)
        #expect(settings.window?.appearance?.name == .darkAqua)

        let theme = try setting("theme")
        settings.model.set(theme, .text("righteous"))
        let file = try String(contentsOf: app.configStore.url, encoding: .utf8)
        #expect(file.split(separator: "\n").contains("theme = righteous"))
        // Everything else in the file is the template, as it was.
        #expect(file.contains("# ---- "))
        #expect(app.configStore.config.namedTheme.id == "righteous")
        #expect(settings.model.config.namedTheme.id == "righteous")
        #expect(settings.model.palette.isLight)
        #expect(settings.window?.appearance?.name == .aqua)
        #expect(controller.window?.appearance?.name == .aqua)

        // A value that cannot be saved is not shown as if it were. Neither the folder nor
        // the file can be written, so neither a save by rename nor one in place succeeds.
        let folder = app.configStore.url.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: app.configStore.url.path)
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let starfield = try setting("starfield")
        #expect(settings.model.boolValue(starfield))
        settings.model.set(starfield, .bool(false))
        #expect(settings.model.problem != nil)
        #expect(settings.model.boolValue(starfield))
    }

    @Test func anEditSavedInAnEditorAppliesWithoutAsking() async throws {
        let home = try makeFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = makeApp(configHome: home)
        app.newWindow(nil)
        let controller = try #require(app.windows.first)
        defer { controller.window?.close() }
        // No settings folder yet: the watcher waits for it to be made.
        app.watchSettingsFile()
        defer { app.watcher?.stop() }

        let url = app.configStore.url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // As most editors save: a new file renamed over the old one.
        try Data("theme = fighting-demons\n".utf8).write(to: url, options: .atomic)
        await eventually(within: 5) { app.configStore.config.namedTheme.id == "fighting-demons" }
        #expect(app.configStore.config.namedTheme.id == "fighting-demons")
        #expect(controller.config.namedTheme.id == "fighting-demons")

        // A setting it cannot use shows in the status bar, with no sheet.
        try Data("theme = fighting-demons\nfont-size = huge\n".utf8).write(to: url, options: .atomic)
        await eventually(within: 5) { controller.settingsProblems == 1 }
        #expect(controller.settingsProblems == 1)
        #expect(controller.window?.attachedSheet == nil)
    }

    /// A file Death Race could not read, or that is not UTF-8, is never replaced by the
    /// template with one change in it.
    @Test func aFileThatCannotBeReadIsNotWrittenOver() throws {
        let home = try makeFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ConfigStore(environment: ["XDG_CONFIG_HOME": home.path])
        let manager = FileManager.default
        try manager.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let theme = try setting("theme")

        let mine = Data("font-size = 15\n# mine\n".utf8)
        try mine.write(to: store.url)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.url.path)
        #expect(throws: ConfigFileError.self) {
            try store.update { SettingsCatalog.set(theme, to: .text("righteous"), in: $0) }
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
        #expect(manager.contents(atPath: store.url.path) == mine)

        let latin1 = Data([0x23, 0x20, 0xE9, 0x0A]) + Data("font-size = 15\n".utf8)
        try latin1.write(to: store.url)
        #expect(throws: ConfigFileError.self) {
            try store.update { SettingsCatalog.set(theme, to: .text("righteous"), in: $0) }
        }
        #expect(manager.contents(atPath: store.url.path) == latin1)
    }

    @Test func theWatcherSeesEditsButNotDeathRacesOwnWrites() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config")
        try Data("font-size = 13\n".utf8).write(to: file)
        let watcher = ConfigWatcher(file: file)
        var changes = 0
        watcher.onChange = { changes += 1 }
        watcher.start()
        defer { watcher.stop() }

        let own = Data("font-size = 14\n".utf8)
        watcher.noteWritten(own)
        try own.write(to: file, options: .atomic)
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(changes == 0)

        // Written in place, as some editors do.
        try Data("font-size = 15\n".utf8).write(to: file)
        await eventually(within: 5) { changes == 1 }
        #expect(changes == 1)

        // Saved by rename, after which the file's own source must be opened again.
        try Data("font-size = 16\n".utf8).write(to: file, options: .atomic)
        await eventually(within: 5) { changes == 2 }
        try Data("font-size = 17\n".utf8).write(to: file)
        await eventually(within: 5) { changes == 3 }
        #expect(changes == 3)
    }
}
