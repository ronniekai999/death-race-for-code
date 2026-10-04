import AppKit
import Carbon
import ConfigKit
import SurfaceCore

/// Secure Keyboard Entry for the whole app: while it is on, no other process (keyloggers,
/// event taps, accessibility tools) can read the keys typed into Death Race.
///
/// When it is on follows `SecureInput`: the `secure-keyboard-entry` setting, the menu item,
/// and whether the focused tab is reading a password. macOS applies it system-wide, so it is
/// only ever on while the app is active.
@MainActor
final class SecureInputController {
    private static let menuDefaultsKey = "SecureKeyboardEntry"
    private var state: SecureInput

    init(mode: SecureKeyboardEntry) {
        state = SecureInput(mode: mode)
        // The menu item is remembered across launches, as in Terminal.
        state.menuChecked = UserDefaults.standard.bool(forKey: Self.menuDefaultsKey)
    }

    /// On now, as far as macOS knows.
    var isEnabled: Bool { state.isEnabled }

    /// The menu item shows a check mark.
    var isChecked: Bool { state.menuChecked || state.mode == .always }

    /// The menu item can be changed: with `always`, the setting decides.
    var canToggle: Bool { state.mode != .always }

    func setMode(_ mode: SecureKeyboardEntry) {
        state.mode = mode
    }

    func toggle() {
        state.menuChecked.toggle()
        UserDefaults.standard.set(state.menuChecked, forKey: Self.menuDefaultsKey)
    }

    /// Brings macOS in line with the app's state; the calls stay balanced.
    func update(appIsActive: Bool, focusedTabReadsPassword: Bool) {
        state.appIsActive = appIsActive
        state.focusedTabReadsPassword = focusedTabReadsPassword
        state.apply(
            enable: { EnableSecureEventInput() == OSStatus(noErr) },
            disable: { DisableSecureEventInput() == OSStatus(noErr) })
    }
}
