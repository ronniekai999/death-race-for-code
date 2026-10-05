import AppCore
import AppKit
import ConfigKit
import LegendsUI
import PTYKit
import RenderKit
import SSHKit
import SessionKit
import Vault

/// Opens windows, owns their controllers, and answers the app-wide menu items.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, WindowHost {
    let configStore: ConfigStore
    private(set) var windows: [PitLaneWindowController] = []
    private let about = AboutWindow()
    private lazy var secureInput = SecureInputController(mode: configStore.config.secureKeyboardEntry)
    /// Lucid Dreams, the notch quick-terminal, its global hotkey, and the menu-bar item that
    /// also opens it; all set up at launch.
    private var lucidDreams: LucidDreamsController?
    private var hotKey: HotKeyController?
    private var lucidStatusItem: NSStatusItem?
    /// Where the next new window's top-left corner goes, so windows cascade.
    private var cascadePoint: NSPoint?
    /// Reads the settings file again whenever anything changes it.
    private(set) var watcher: ConfigWatcher?
    /// The Settings window, while it is open.
    private(set) var settingsWindow: SettingsWindowController?
    let ids = IDSource()
    let makeSession: SessionMaker
    /// Where Hear Me Calling's recent picks are kept.
    private let defaults: UserDefaults
    /// WRLD, made once the app has launched: tests that make an AppDelegate never touch your
    /// vault, your ssh config or your Keychain.
    private(set) var wrld: WRLDService?
    var connections: (any HostConnecting)? { wrld }
    static let recentPicksKey = "HearMeCallingRecentPicks"

    /// Tests pass sessions that run no shell, and a settings file and defaults of their own.
    init(
        makeSession: @escaping SessionMaker = PaneController.realSession, configStore: ConfigStore = ConfigStore(),
        defaults: UserDefaults = .standard
    ) {
        self.makeSession = makeSession
        self.configStore = configStore
        self.defaults = defaults
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The bundled fonts, for this process only, before any window asks for one.
        FontRegistry.registerBundledFonts()
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
        let wrld = WRLDService(
            home: NSHomeDirectory(), helper: WRLDService.bundledHelper, secrets: KeychainSecretStore(),
            presence: DeviceOwnerPresence(), presenter: SheetPromptPresenter())
        self.wrld = wrld
        wrld.checksHosts = configStore.config.checkHosts
        wrld.readsHostOS = configStore.config.readHostOS
        watchWRLDFiles(wrld)
        // Masters a crash left running hold their tunnels' ports: end them first.
        Task { await wrld.cleanUpLeftovers() }
        if windows.isEmpty { newWindow(nil) }
        NSApp.activate()
        configStore.reportProblems(in: windows.first?.window)
        watchSettingsFile()
        startLucidDreams()
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

    /// Quitting with programs running in any pane, sessions on hosts among them, asks once
    /// for all of them; then every ssh master ends before the app does.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = configStore.config.confirmClose ? allPanes.filter { $0.isRunning } : []
        let connected = !(wrld?.openConnections.isEmpty ?? true)
        // Any master, even one still connecting, means there's something to shut down; quit
        // through the Task below (which may skip the question) rather than leaving an orphan.
        guard !running.isEmpty || connected || (wrld?.hasMasters ?? false) else { return .terminateNow }
        let tunnels = configStore.config.confirmClose ? (wrld?.openTunnelCount ?? 0) : 0
        Task {
            var programs: [String] = []
            for pane in running {
                if let program = await pane.runningProgram() { programs.append(program) }
            }
            if !programs.isEmpty || tunnels > 0 {
                let alert = NSAlert()
                alert.messageText = "Goodbye & Good Riddance?"
                alert.informativeText = Self.quitQuestion(programs: programs, tunnels: tunnels)
                alert.addButton(withTitle: "Quit")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    return NSApp.reply(toApplicationShouldTerminate: false)
                }
            }
            // Maze's ssh subsystems end before their masters do, so none is left behind.
            for controller in mazeWindows.values { await controller.shutDown() }
            mazeWindows = [:]
            await wrld?.shutDown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// "vim is still running, and 2 tunnels are open. Quit anyway?"
    static func quitQuestion(programs: [String], tunnels: Int) -> String {
        var parts: [String] = []
        if programs.count == 1 { parts.append("\(programs[0]) is still running") }
        if programs.count > 1 {
            parts.append("\(ListFormatter.localizedString(byJoining: programs)) are still running")
        }
        if tunnels == 1 { parts.append("1 tunnel is open") }
        if tunnels > 1 { parts.append("\(tunnels) tunnels are open") }
        return parts.joined(separator: ", and ") + ". Quit anyway?"
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
        for watcher in wrldWatchers { watcher.stop() }
        secureInput.update(appIsActive: false, focusedTabReadsPassword: false)
        hotKey?.stop()
        lucidDreams?.shutDown()
        for pane in allPanes { pane.shutDown() }
    }

    // MARK: - WRLD

    /// The New Host sheet while it's open.
    private var newHostSheet: NewHostSheet?
    /// wrld.json and ~/.ssh/config, watched.
    private var wrldWatchers: [ConfigWatcher] = []
    /// The WRLD window, while it's open.
    private(set) var wrldWindow: WRLDWindowController?

    /// ⌘O: the WRLD window, made on first use.
    @objc func openWRLD(_ sender: Any?) {
        showWRLD(nil)
    }

    func showWRLD(at place: WRLDBoard.Place, selecting host: HostID?) {
        showWRLD(place)
        if let host { wrldWindow?.model.selected = host }
    }

    static let sidebarKey = "WRLDSidebarShown"

    var sidebarPreferred: Bool {
        get { defaults.bool(forKey: Self.sidebarKey) }
        set { defaults.set(newValue, forKey: Self.sidebarKey) }
    }

    /// The WRLD window at `place`, when given.
    func showWRLD(_ place: WRLDBoard.Place?) {
        guard let wrld else { return }
        let controller =
            wrldWindow ?? WRLDWindowController(wrld: wrld, host: self, chrome: Chrome(configStore.config.namedTheme))
        if wrldWindow == nil {
            controller.onClose = { [weak self, weak controller] in
                // Released once AppKit has finished closing it.
                Task { @MainActor in
                    if let self, self.wrldWindow === controller { self.wrldWindow = nil }
                }
            }
            wrldWindow = controller
        }
        controller.show(place)
    }

    /// The Pit Lane window in front, or a new one when none is open.
    private var frontWindow: PitLaneWindowController {
        if let front = NSApp.orderedWindows.lazy.compactMap({ $0.windowController as? PitLaneWindowController })
            .first
        {
            return front
        }
        if let any = windows.first { return any }
        newWindow(nil)
        return windows[windows.count - 1]
    }

    // MARK: - Maze

    /// The Maze windows, one per host, while they're open.
    private(set) var mazeWindows: [HostRef: MazeWindowController] = [:]
    /// Hosts whose files are opening: a second Open in Maze waits rather than making a
    /// second connection.
    private var openingMaze: Set<HostRef> = []

    /// Open in Maze: the files of the host the pane in front runs on.
    @objc func openMaze(_ sender: Any?) {
        guard let host = frontPitLaneWindow?.activePane?.launch.host else { return }
        showMaze(host)
    }

    /// Maze on `host`: its window when one is open, else the host's files and a window on
    /// them. The window owns the connection from then on.
    func showMaze(_ host: HostRef) {
        if let controller = mazeWindows[host] {
            controller.show()
            return
        }
        guard let wrld, !openingMaze.contains(host) else { return }
        openingMaze.insert(host)
        Task {
            // In a `defer`: a host whose files never open must still be openable again, and
            // `openSFTP` is a long await on a connection that may not answer.
            defer { openingMaze.remove(host) }
            let files = await wrld.openSFTP(host)
            guard let files else {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Maze couldn't open \(wrld.name(of: host))'s files."
                alert.informativeText =
                    "The host may be unreachable, or it may not offer the sftp subsystem. Connecting a pane to it says more."
                alert.runModal()
                return
            }
            let controller = MazeWindowController(
                host: host, name: wrld.name(of: host), files: files, wrld: wrld,
                chrome: Chrome(configStore.config.namedTheme))
            controller.onClose = { [weak self, weak controller] in
                // Released once AppKit has finished closing it.
                Task { @MainActor in
                    guard let self, self.mazeWindows[host] === controller else { return }
                    self.mazeWindows[host] = nil
                }
            }
            mazeWindows[host] = controller
            controller.show()
        }
    }

    /// Hand edits to wrld.json and changes to ~/.ssh/config apply at once, as the settings
    /// file's do.
    private func watchWRLDFiles(_ wrld: WRLDService) {
        wrldWatchers = [wrld.vaultPath, NSHomeDirectory() + "/.ssh/config"].map { path in
            let watcher = ConfigWatcher(file: URL(fileURLWithPath: path))
            watcher.onChange = { [weak wrld] in
                wrld?.reload()
                WRLDService.changed()
            }
            watcher.start()
            return watcher
        }
    }

    /// "New Host…": a sheet on the window in front; the host opens in a new tab once added.
    @objc func newHost(_ sender: Any?) {
        guard let wrld, newHostSheet == nil else { return }
        let parent = NSApp.keyWindow ?? NSApp.mainWindow
        let sheet = NewHostSheet(
            jumpHosts: wrld.jumpHostChoices, parent: parent,
            add: { draft in
                // Name the thrown type: a closure doesn't infer it, so `error` would be
                // `any Error` and wouldn't fit `Result<_, WRLDService.AddFailure>`.
                do throws(WRLDService.AddFailure) {
                    return .success(try await wrld.add(draft))
                } catch {
                    return .failure(error)
                }
            },
            finished: { [weak self] id in
                self?.newHostSheet = nil
                guard let id else { return }
                // The sheet's parent may be the WRLD window or Settings, not a Pit Lane
                // window; open the host in the frontmost one and bring it forward, so the new
                // tab isn't hidden behind a background window.
                let controller = self?.windows.first { $0.window === parent } ?? self?.frontWindow
                controller?.open(.vault(id), beside: false)
                controller?.window?.makeKeyAndOrderFront(nil)
            })
        newHostSheet = sheet
        sheet.show()
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
        // The status bar's "2 settings could not be used": which, and why.
        controller.onSettingsProblemsClick = { [weak self, weak controller] in
            self?.configStore.reportProblems(in: controller?.window)
        }
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

    // MARK: - Lucid Dreams

    /// The quick-terminal panel, its ⌥Space hotkey, and a menu-bar item that also opens it.
    private func startLucidDreams() {
        let lucid = LucidDreamsController(
            config: { [weak self] in self?.configStore.config ?? Config() }, makeSession: makeSession, ids: ids,
            directory: { [weak self] in self?.frontPitLaneWindow?.activePane?.directory })
        lucidDreams = lucid
        let hotKey = HotKeyController(onTrigger: { [weak self] in self?.lucidDreams?.toggle() })
        hotKey.apply(configStore.config.lucidDreamsHotkey)
        self.hotKey = hotKey
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "moon.stars", accessibilityDescription: "Lucid Dreams")
        item.button?.toolTip = "Lucid Dreams"
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Lucid Dreams", action: #selector(toggleLucidDreams(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        item.menu = menu
        lucidStatusItem = item
    }

    /// ⌥Space, the Shell-menu item, Hear Me Calling and the menu-bar icon all land here.
    @objc func toggleLucidDreams(_ sender: Any?) {
        lucidDreams?.toggle()
    }

    /// The frontmost Pit Lane window, without opening one (for the quick terminal's directory).
    private var frontPitLaneWindow: PitLaneWindowController? {
        NSApp.orderedWindows.lazy.compactMap { $0.windowController as? PitLaneWindowController }.first ?? windows.first
    }

    // MARK: - Menu actions

    @objc func showAbout(_ sender: Any?) {
        about.show()
    }

    @objc func openSettings(_ sender: Any?) {
        showSettings()
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

    /// Reload Settings: read the file, apply it, and say what could not be used.
    @objc func reloadConfiguration(_ sender: Any?) {
        configStore.load()
        applyConfiguration()
        configStore.reportProblems(in: NSApp.keyWindow)
    }

    // MARK: - Settings

    /// The Settings window, made on first use, at `page` when given.
    func showSettings(page: SettingsCatalog.Page? = nil) {
        let controller = settingsWindow ?? makeSettingsWindow()
        settingsWindow = controller
        controller.show(page: page)
    }

    private func makeSettingsWindow() -> SettingsWindowController {
        let chrome = Chrome(configStore.config.namedTheme)
        let model = SettingsModel(
            config: configStore.config, palette: LegendsPalette(chrome), filePath: configStore.url.path)
        model.onSet = { [weak self] setting, value in self?.saveFromSettings(setting, value) }
        model.onOpenFile = { [weak self] in self?.openSettingsFile(nil) }
        model.onRevealFile = { [weak self] in self?.revealSettingsFile() }
        model.onReload = { [weak self] in self?.reloadConfiguration(nil) }
        model.sampleEnergy = { [weak self] in
            SettingsModel.processSample(frames: self?.framesDrawn ?? 0)
        }
        let controller = SettingsWindowController(model: model, chrome: chrome)
        controller.onClose = { [weak self, weak controller] in
            // Released once AppKit has finished closing it.
            Task { @MainActor in
                if let self, self.settingsWindow === controller { self.settingsWindow = nil }
            }
        }
        return controller
    }

    /// Writes `value` for `setting`, that one line of the file; then everything follows the
    /// file, which still holds the old value if it could not be written.
    func save(_ setting: SettingsCatalog.Setting, _ value: SettingsCatalog.Value) throws {
        defer { applyConfiguration() }
        try configStore.update { SettingsCatalog.set(setting, to: value, in: $0) }
    }

    /// A control in Settings changed. If the file cannot be written, the window says so and
    /// shows the file's value again.
    private func saveFromSettings(_ setting: SettingsCatalog.Setting, _ value: SettingsCatalog.Value) {
        do {
            try save(setting, value)
            settingsWindow?.model.problem = nil
        } catch {
            settingsWindow?.model.problem =
                "Death Race could not save the change to \(configStore.url.path): \(error.localizedDescription)"
        }
    }

    private func revealSettingsFile() {
        do {
            try configStore.createIfMissing()
            NSWorkspace.shared.activateFileViewerSelecting([configStore.url])
        } catch {
            settingsWindow?.model.problem =
                "Death Race could not create \(configStore.url.path): \(error.localizedDescription)"
        }
    }

    /// Edits saved by any editor apply at once. Problems show in the status bar rather than
    /// as a sheet, since nobody asked for this reload.
    func watchSettingsFile() {
        let watcher = ConfigWatcher(file: configStore.url)
        watcher.onChange = { [weak self] in
            guard let self else { return }
            self.configStore.load()
            self.applyConfiguration()
        }
        configStore.onWrite = { [weak watcher] data in watcher?.noteWritten(data) }
        watcher.start()
        self.watcher = watcher
    }

    /// Every window, Secure Keyboard Entry and the Settings window follow the file as it was
    /// last read.
    private func applyConfiguration() {
        let config = configStore.config
        for controller in windows {
            controller.apply(config)
            controller.settingsProblems = configStore.diagnostics.count
        }
        secureInput.setMode(config.secureKeyboardEntry)
        updateSecureInput()
        lucidDreams?.apply(config)
        hotKey?.apply(config.lucidDreamsHotkey)
        settingsWindow?.update(config: config, chrome: Chrome(config.namedTheme))
        wrldWindow?.setChrome(Chrome(config.namedTheme))
        for controller in mazeWindows.values { controller.setChrome(Chrome(config.namedTheme)) }
        wrld?.checksHosts = config.checkHosts
        wrld?.readsHostOS = config.readHostOS
    }

    /// Frames drawn so far by the panes that are open, for the Energy page.
    private var framesDrawn: Int {
        allPanes.reduce(0) { $0 + $1.surface.frameStats.framesDrawn }
    }

    // MARK: - Hear Me Calling

    func places(from controller: PitLaneWindowController) -> [PaletteItem] {
        ([controller] + windows.filter { $0 !== controller }).flatMap { $0.places(isCurrent: $0 === controller) }
    }

    func focus(pane: PaneID, from controller: PitLaneWindowController) {
        guard let owner = windows.first(where: { $0.panes[pane] != nil }) else { return }
        if owner !== controller { owner.window?.makeKeyAndOrderFront(nil) }
        owner.focus(pane: pane)
    }

    func chooseTheme(_ id: String) throws {
        guard let setting = SettingsCatalog.setting("theme") else { return }
        try save(setting, .text(id))
    }

    var recentPicks: [String] {
        defaults.stringArray(forKey: Self.recentPicksKey) ?? []
    }

    func picked(_ id: String) {
        defaults.set(PaletteState.remembering(id, in: recentPicks), forKey: Self.recentPicksKey)
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleLucidDreams(_:)) {
            menuItem.state = (lucidDreams?.isOnScreen ?? false) ? .on : .off
            return true
        }
        // Maze needs a host: off in a local shell.
        if menuItem.action == #selector(openMaze(_:)) {
            return frontPitLaneWindow?.activePane?.launch.host != nil
        }
        guard menuItem.action == #selector(toggleSecureKeyboardEntry(_:)) else { return true }
        menuItem.state = secureInput.isChecked ? .on : .off
        return secureInput.canToggle
    }
}

extension AppDelegate: WRLDWindowHost {
    func connect(_ host: HostRef, beside: Bool) {
        let controller = frontWindow
        controller.window?.makeKeyAndOrderFront(nil)
        controller.open(host, beside: beside)
    }

    func openMaze(for host: HostRef) {
        showMaze(host)
    }

    func typeSnippet(_ command: String, run: Bool, from snippet: SnippetID) {
        let controller = frontWindow
        controller.window?.makeKeyAndOrderFront(nil)
        controller.typeSnippet(command, run: run)
        wrld?.used(snippet)
    }
}
