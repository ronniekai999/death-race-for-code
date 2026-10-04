import AppKit
import ConfigKit

/// Opens windows and tabs, owns their controllers, and answers the app-wide menu items.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configStore = ConfigStore()
    private var controllers: [TerminalWindowController] = []
    private let about = AboutWindow()
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

    // MARK: - Windows and tabs

    @objc func newWindow(_ sender: Any?) {
        let controller = makeController()
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
        guard let existingWindow = existing.window else { return newWindow(nil) }
        let controller = makeController()
        guard let window = controller.window else { return }
        existingWindow.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeController() -> TerminalWindowController {
        let controller = TerminalWindowController(
            config: configStore.config,
            onNewTab: { [weak self] existing in self?.openTab(beside: existing) },
            onClose: { [weak self] closed in
                // Released once AppKit has finished closing the window.
                Task { @MainActor in
                    self?.controllers.removeAll { $0 === closed }
                }
            })
        controllers.append(controller)
        return controller
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
        configStore.reportProblems(in: NSApp.keyWindow)
    }
}
