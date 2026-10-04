import AppKit
import ConfigKit
import PTYKit
import SessionKit

/// Opens windows and tabs, owns their controllers, and answers the app-wide menu items.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configStore = ConfigStore()
    private var controllers: [TerminalWindowController] = []
    private let about = AboutWindow()
    private lazy var secureInput = SecureInputController(mode: configStore.config.secureKeyboardEntry)
    /// Where the next new window's top-left corner goes, so windows cascade.
    private var cascadePoint: NSPoint?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A held key repeats, as terminals expect, instead of offering accented letters.
        UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` starts a bare executable as a background process: promote it so its
        // windows take keystrokes. In the bundled app this changes nothing.
        NSApp.setActivationPolicy(.regular)
        if controllers.isEmpty { newWindow(nil) }
        NSApp.activate()
        configStore.reportProblems(in: controllers.first?.window)
    }

    /// A click on the Dock icon with no windows open opens one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // Focus follows the app as well as the window: a terminal in a background app is not
    // focused (its cursor goes hollow, programs get a focus-out report).
    func applicationDidBecomeActive(_ notification: Notification) {
        for controller in controllers { controller.surface.focusChanged() }
        updateSecureInput()
    }

    func applicationDidResignActive(_ notification: Notification) {
        for controller in controllers { controller.surface.focusChanged() }
        updateSecureInput()
    }

    /// Quitting with programs running in any tab asks once, for all of them.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let sessions = controllers.compactMap(\.session).filter { $0.status == .running }
        guard configStore.config.confirmClose, !sessions.isEmpty else { return .terminateNow }
        Task {
            var running: [String] = []
            for session in sessions {
                if let process = await session.foregroundProcess(), !process.isShell {
                    running.append(process.name.isEmpty ? "a program" : process.name)
                }
            }
            guard !running.isEmpty else { return NSApp.reply(toApplicationShouldTerminate: true) }
            let alert = NSAlert()
            alert.messageText = "Goodbye & Good Riddance?"
            alert.informativeText =
                running.count == 1
                ? "\(running[0]) is still running. Quit anyway?"
                : "\(ListFormatter.localizedString(byJoining: running)) are still running. Quit anyway?"
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            NSApp.reply(toApplicationShouldTerminate: alert.runModal() == .alertFirstButtonReturn)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        secureInput.update(appIsActive: false, focusedTabReadsPassword: false)
        for controller in controllers { controller.session?.close() }
    }

    // MARK: - Windows and tabs

    @objc func newWindow(_ sender: Any?) {
        let controller = makeController(directory: nil)
        guard let window = controller.window else { return }
        // A new window, even when the user prefers tabs: ⌘T is for tabs.
        window.tabbingMode = .disallowed
        if let point = cascadePoint {
            cascadePoint = window.cascadeTopLeft(from: point)
        } else {
            window.center()
            cascadePoint = window.cascadeTopLeft(from: NSPoint(x: window.frame.minX, y: window.frame.maxY))
        }
        controller.showWindow(nil)
        window.tabbingMode = .automatic
    }

    /// ⌘T with no terminal window to add a tab to.
    @objc func newWindowForTab(_ sender: Any?) {
        newWindow(sender)
    }

    private func openTab(beside existing: TerminalWindowController) {
        // A new tab starts where the current one is (with `working-directory = inherit`),
        // which takes a question to its session.
        Task {
            let directory = await existing.currentDirectory()
            guard let existingWindow = existing.window, existingWindow.isVisible else { return newWindow(nil) }
            let controller = makeController(directory: directory)
            guard let window = controller.window else { return }
            existingWindow.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func makeController(directory: String?) -> TerminalWindowController {
        let controller = TerminalWindowController(
            config: configStore.config, directory: directory,
            onNewTab: { [weak self] existing in self?.openTab(beside: existing) },
            onClose: { [weak self] closed in
                // Released once AppKit has finished closing the window.
                Task { @MainActor in
                    self?.controllers.removeAll { $0 === closed }
                }
            })
        controller.onInputStateChange = { [weak self] in self?.updateSecureInput() }
        controllers.append(controller)
        return controller
    }

    // MARK: - Secure Keyboard Entry

    /// Secure Keyboard Entry follows the active app, the focused tab and the menu item; the
    /// focused window shows a lock while it is on.
    private func updateSecureInput() {
        let focused = NSApp.isActive ? NSApp.keyWindow?.windowController as? TerminalWindowController : nil
        secureInput.update(
            appIsActive: NSApp.isActive, focusedTabReadsPassword: focused?.surface.readsPassword ?? false)
        for controller in controllers {
            controller.showsSecureInputLock = secureInput.isEnabled && controller === focused
        }
    }

    @objc func toggleSecureKeyboardEntry(_ sender: Any?) {
        secureInput.toggle()
        updateSecureInput()
    }

    // MARK: - Menu actions

    @objc func showAbout(_ sender: Any?) {
        about.show()
    }

    @objc func openSettings(_ sender: Any?) {
        do {
            try configStore.openInEditor()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Death Race could not create its settings file"
            alert.informativeText = "\(configStore.url.path): \(error.localizedDescription)"
            alert.runModal()
        }
    }

    @objc func reloadConfiguration(_ sender: Any?) {
        configStore.load()
        for controller in controllers { controller.apply(configStore.config) }
        secureInput.setMode(configStore.config.secureKeyboardEntry)
        updateSecureInput()
        configStore.reportProblems(in: NSApp.keyWindow)
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(toggleSecureKeyboardEntry(_:)) else { return true }
        menuItem.state = secureInput.isChecked ? .on : .off
        return secureInput.canToggle
    }
}
