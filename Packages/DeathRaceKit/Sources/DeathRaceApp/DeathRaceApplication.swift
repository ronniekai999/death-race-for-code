import AppKit

/// Death Race for Code: an AppKit application.
///
/// AppKit rather than SwiftUI's `App`: a terminal needs what only AppKit offers, such as
/// native tabs with a working + button, close and quit confirmation sheets, and a responder
/// chain that takes Copy, Paste and font size to the terminal view. SwiftUI still draws the
/// Legends Never Die pieces, hosted in AppKit windows.
public enum DeathRaceApplication {
    /// What scripts/bundle.sh stamped into Info.plist, or 0.1.0 for a run with no bundle of ours
    /// around it (`swift run`, the tests), whose Info.plist, if it has one, is someone else's.
    public static let version = ownInfo("CFBundleShortVersionString") ?? "0.1.0"
    /// Which build of `version` this is. Every beta of a version shares the version, so a report
    /// from a tester needs this too; nil outside the bundle.
    public static let build = ownInfo("CFBundleVersion")
    /// "0.1.0 (3)" in a bundle, "0.1.0" outside one: what About shows.
    public static var versionAndBuild: String { build.map { "\(version) (\($0))" } ?? version }

    private static func ownInfo(_ key: String) -> String? {
        guard Bundle.main.bundleIdentifier == "local.deathraceforcode.DeathRace" else { return nil }
        return Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    /// Runs the app; returns only if AppKit stops the event loop.
    @MainActor
    public static func run() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.mainMenu = MainMenu.make()
        // NSApplication holds its delegate weakly.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
