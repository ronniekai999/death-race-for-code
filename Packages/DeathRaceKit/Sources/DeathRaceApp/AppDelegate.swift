import AppCore
import AppKit
import ConfigKit
import PTYKit
import SessionKit

/// Opens windows, owns their controllers, and answers the app-wide menu items.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, WindowHost {
    private let configStore = ConfigStore()
    private(set) var windows: [PitLaneWindowController] = []
    private let about = AboutWindow()
    private lazy var secureInput = SecureInputController(mode: configStore.config.secureKeyboardEntry)
    /// Where the next new window's top-left corner goes, so windows cascade.
    private var cascadePoint: NSPoint?
    let ids = IDSource()
    let makeSession: SessionMaker

    init(makeSession: @escaping SessionMaker = PaneController.realSession) {
        self.makeSession = makeSession
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Tabs are the window's own: no native tab bar, Show All Tabs or Merge All Windows,
        // and the "prefer tabs" setting never merges Death Race windows.
        NSWindow.allowsAutomaticWindowTabbing = false
        // A held key repeats, as terminals expect, instead of offering accented letters.
        UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` starts a bare executable as a background process: promote it so its
        // windows take keystrokes. In the bundled app this changes nothing.
        NSApp.setActivationPolicy(.regular)
        if windows.isEmpty { newWindow(nil) }
        NSApp.activate()
        configStore.reportProblems(in: windows.first?.window)
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
        for pane in allPanes { pane.surface.focusChanged() }
        updateSecureInput()
    }

    func applicationDidResignActive(_ notification: Notification) {
        for pane in allPanes { pane.surface.focusChanged() }
        updateSecureInput()
    }

    private var allPanes: [PaneController] {
        windows.flatMap { Array($0.panes.values) }
    }

    /// Quitting with programs running in any pane asks once, for all of them.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = allPanes.filter { $0.isRunning }
        guard configStore.config.confirmClose, !running.isEmpty else { return .terminateNow }
        Task {
            var programs: [String] = []
            for pane in running {
                if let program = await pane.runningProgram() { programs.append(program) }
            }
            guard !programs.isEmpty else { return NSApp.reply(toApplicationShouldTerminate: true) }
            let alert = NSAlert()
            alert.messageText = "Goodbye & Good Riddance?"
            alert.informativeText =
                programs.count == 1
                ? "\(programs[0]) is still running. Quit anyway?"
                : "\(ListFormatter.localizedString(byJoining: programs)) are still running. Quit anyway?"
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            NSApp.reply(toApplicationShouldTerminate: alert.runModal() == .alertFirstButtonReturn)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        secureInput.update(appIsActive: false, focusedTabReadsPassword: false)
        for pane in allPanes { pane.shutDown() }
    }

    // MARK: - Windows

    @objc func newWindow(_ sender: Any?) {
        let controller = PitLaneWindowController(config: configStore.config, host: self, directory: nil)
        show(controller)
    }

    /// ⌘T with no window to add a tab to.
    @objc func newTab(_ sender: Any?) {
        newWindow(sender)
    }

    private func show(_ controller: PitLaneWindowController, near other: NSWindow? = nil) {
        guard let window = controller.window else { return }
        controller.onSettingsProblemsClick = { [weak self] in self?.openSettingsFile(nil) }
        controller.settingsProblems = configStore.diagnostics.count
        windows.append(controller)
        if let other {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: other.frame.minX, y: other.frame.maxY)))
        } else if let point = cascadePoint {
            cascadePoint = window.cascadeTopLeft(from: point)
        } else {
            window.center()
            cascadePoint = window.cascadeTopLeft(from: NSPoint(x: window.frame.minX, y: window.frame.maxY))
        }
        controller.showWindow(nil)
    }

    func windowClosed(_ controller: PitLaneWindowController) {
        // Released once AppKit has finished closing the window.
        Task { @MainActor in
            self.windows.removeAll { $0 === controller }
            self.updateSecureInput()
        }
    }

    func inputStateChanged() {
        updateSecureInput()
    }

    /// Move Tab to New Window: a window for the tab, beside the one it left.
    func open(
        detached tab: TabModel, panes: [PaneController], area: PaneAreaView, from controller: PitLaneWindowController
    ) {
        let window = PitLaneWindowController(
            config: configStore.config, host: self, adopting: tab, panes: panes, area: area)
        show(window, near: controller.window)
    }

    // MARK: - Secure Keyboard Entry

    /// Secure Keyboard Entry follows the active app, the key window's active pane and the
    /// menu item; that window's status bar shows it while it is on.
    private func updateSecureInput() {
        let focused = NSApp.isActive ? NSApp.keyWindow?.windowController as? PitLaneWindowController : nil
        secureInput.update(
            appIsActive: NSApp.isActive, focusedTabReadsPassword: focused?.activePane?.surface.readsPassword ?? false)
        for controller in windows {
            controller.showsSecureInput = secureInput.isEnabled && controller === focused
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

    /// Settings… opens the settings file until the Settings window arrives.
    @objc func openSettings(_ sender: Any?) {
        openSettingsFile(sender)
    }

    @objc func openSettingsFile(_ sender: Any?) {
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
        for controller in windows {
            controller.apply(configStore.config)
            controller.settingsProblems = configStore.diagnostics.count
        }
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
