import AppKit

/// Death Race for Code: an AppKit application.
///
/// AppKit rather than SwiftUI's `App`: a terminal needs what only AppKit offers, such as
/// native tabs with a working + button, close and quit confirmation sheets, and a responder
/// chain that takes Copy, Paste and font size to the terminal view. SwiftUI still draws the
/// Legends Never Die pieces, hosted in AppKit windows.
public enum DeathRaceApplication {
    public static let version = "0.1.0"

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
