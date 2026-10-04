import AppKit
import ConfigKit
import Foundation
import PTYKit
import RenderKit
import SessionKit
import SurfaceCore
import TerminalUI
import VTCore
import os

/// One tab: a window with a terminal view and the shell running in it. Tabs are native window
/// tabs: each is a window with its own controller, and AppKit groups them by their tabbing
/// identifier.
@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    static let tabbingIdentifier = "terminal"
    private static let fontSizes = 6.0...144.0

    let surface: TerminalSurfaceView
    private(set) var session: Session?
    private var config: Config
    /// The font size ⌘+ and ⌘− chose for this window; nil follows the settings.
    private var fontSizeOverride: Double?
    /// Where the shell said it is (OSC 7), for new tabs and the title bar's proxy icon.
    private(set) var workingDirectory: String?
    /// The user agreed to close this tab with a program running in it.
    private var closeConfirmed = false
    private let shellName: String
    private let onClose: (TerminalWindowController) -> Void
    private let onNewTab: (TerminalWindowController) -> Void
    /// The window gained or lost focus, or its program started or stopped reading a
    /// password: what Secure Keyboard Entry follows.
    var onInputStateChange: (() -> Void)?
    /// A lock in the title bar while Secure Keyboard Entry is on for this window.
    private let lockAccessory = TerminalWindowController.makeLockAccessory()

    /// A new tab running the configured command (or the login shell) in `directory`, or
    /// where the settings say when nil.
    init(
        config: Config, directory: String?, onNewTab: @escaping (TerminalWindowController) -> Void,
        onClose: @escaping (TerminalWindowController) -> Void
    ) {
        self.config = config
        self.onNewTab = onNewTab
        self.onClose = onClose
        let launch = Self.launch(config: config, directory: directory)
        shellName = launch.executable.split(separator: "/").last.map(String.init) ?? "Shell"
        let surface = TerminalSurfaceView(
            fonts: FontSet(family: config.fontFamily, size: CGFloat(config.fontSize)), theme: config.theme,
            padding: (config.windowPaddingX, config.windowPaddingY), scale: NSScreen.main?.backingScaleFactor ?? 2)
        self.surface = surface
        let window = TerminalWindow(
            contentRect: NSRect(
                origin: .zero, size: surface.size(columns: config.windowSize.columns, rows: config.windowSize.rows)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.tabbingIdentifier = Self.tabbingIdentifier
        // The controller owns the window; AppKit must not also release it when it closes.
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = surface
        window.initialFirstResponder = surface
        window.title = shellName
        super.init(window: window)
        window.delegate = self
        window.addTitlebarAccessoryViewController(lockAccessory)
        applySettings()
        surface.onTitleChange = { [weak self] title in self?.titleChanged(title) }
        surface.onEvents = { [weak self] events in self?.handle(events) }
        surface.onExit = { [weak self] status in self?.shellExited(status) }
        surface.onPasswordInputChange = { [weak self] in self?.onInputStateChange?() }
        start(launch)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalWindowController is created in code")
    }

    // MARK: - The shell

    private func start(_ launch: ShellLaunch) {
        let grid = surface.grid
        let terminal = Terminal.Configuration(
            columns: grid.columns, rows: grid.rows, scrollbackLimitBytes: config.scrollbackLimit,
            palette: config.theme.palette, version: DeathRaceApplication.version,
            cellPixelWidth: surface.cell.width, cellPixelHeight: surface.cell.height)
        let surface = self.surface
        do {
            let session = try Session(
                launch: launch, configuration: terminal,
                onUpdate: { [weak surface] in
                    // On the session's thread: hop to the main thread, where the view lives.
                    let target = surface
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { target?.sessionDidUpdate() }
                    }
                })
            self.session = session
            surface.attach(session)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "The shell did not start"
            alert.informativeText = "Death Race could not run \(launch.executable): \(error)"
            if let window { alert.beginSheetModal(for: window, completionHandler: nil) }
        }
    }

    /// What a new tab runs: `command` from the settings, or the user's login shell, in the
    /// directory asked for or the configured one.
    static func launch(config: Config, directory: String?) -> ShellLaunch {
        let environment = ShellLaunch.processEnvironment()
        let home = environment["HOME"] ?? NSHomeDirectory()
        var launch = ShellLaunch.loginShell(inheriting: environment, appVersion: DeathRaceApplication.version)
        if let words = config.commandArguments, let program = resolve(words[0], path: environment["PATH"]) {
            launch.executable = program
            launch.arguments = words
        }
        switch config.workingDirectory {
        case .inherit: launch.workingDirectory = directory ?? home
        case .home: launch.workingDirectory = home
        case .path(let path):
            launch.workingDirectory = path == "~" ? home : path.hasPrefix("~/") ? home + String(path.dropFirst()) : path
        }
        return launch
    }

    /// The program's path: as given when it has a slash, else found on PATH.
    static func resolve(_ program: String, path: String?) -> String? {
        if program.contains("/") { return access(program, X_OK) == 0 ? program : nil }
        let directories = (path ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin").split(separator: ":")
        for directory in directories {
            let candidate = "\(directory)/\(program)"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        return nil
    }

    /// Shown while Secure Keyboard Entry is on and this is the focused window.
    var showsSecureInputLock = false {
        didSet { lockAccessory.isHidden = !showsSecureInputLock }
    }

    private static func makeLockAccessory() -> NSTitlebarAccessoryViewController {
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secure Keyboard Entry is on")
        image.contentTintColor = .secondaryLabelColor
        image.toolTip = "Secure Keyboard Entry is on: other apps cannot read what you type."
        image.frame = NSRect(x: 0, y: 0, width: 30, height: 20)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = image
        accessory.layoutAttribute = .trailing
        accessory.isHidden = true
        return accessory
    }

    private func titleChanged(_ title: String) {
        window?.title = title.isEmpty ? shellName : title
    }

    private func handle(_ events: [TerminalEvent]) {
        for event in events {
            switch event {
            case .bell:
                ring()
            case .clipboardWrite(_, let contents):
                writeClipboard(String(decoding: contents, as: UTF8.self))
            case .workingDirectoryChanged(let report):
                guard
                    let path = WorkingDirectoryURL.path(
                        from: report, localHostNames: [ProcessInfo.processInfo.hostName])
                else { continue }
                workingDirectory = path
                window?.representedURL = URL(fileURLWithPath: path)
            default:
                break
            }
        }
    }

    /// Where a tab opened beside this one starts: where the shell last said it is (OSC 7),
    /// else the directory of the program in the foreground. (The zsh that comes with macOS
    /// reports OSC 7 only inside Terminal.)
    func currentDirectory() async -> String? {
        if let workingDirectory { return workingDirectory }
        return await session?.foregroundProcess()?.workingDirectory
    }

    /// The bell: a sound, a flash or nothing, as the settings say; when the app is in the
    /// background, its Dock icon bounces once too.
    private func ring() {
        switch config.bell {
        case .system: NSSound.beep()
        case .visual: surface.flash()
        case .silent: return
        }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// A program set the clipboard (OSC 52, as tmux and Neovim do, also over ssh). Only the
    /// focused tab of the active app may, as `clipboard-write` allows; with `ask`, a sheet
    /// shows the text first.
    private func writeClipboard(_ text: String) {
        guard !text.isEmpty, surface.isFocused, config.clipboardWrite != .deny else { return }
        guard config.clipboardWrite == .ask else { return Self.setClipboard(text) }
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Let the program in this tab copy text to the clipboard?"
        alert.informativeText = PasteWarning.visible(text, limit: 300)
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Don’t Copy")
        Task {
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            Self.setClipboard(text)
        }
    }

    private static func setClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The shell ended: a clean exit closes the tab; anything else stays, with why.
    private func shellExited(_ status: Session.Status) {
        guard case .exited(let exit) = status else { return }
        switch exit {
        case .exited(code: 0)?:
            window?.close()
        case .exited(let code)?:
            window?.subtitle = "The shell exited with status \(code)."
        case .signaled(let signal)?:
            window?.subtitle = "The shell was ended by signal \(signal)."
        case nil:
            window?.subtitle = "The shell exited."
        }
    }

    // MARK: - Settings

    /// Applies reloaded settings. Fonts, colors, padding, the cursor, keys and the mouse
    /// change at once; the window size and the settings for new tabs wait for new windows
    /// and tabs.
    func apply(_ newConfig: Config) {
        let fontChanged = newConfig.fontFamily != config.fontFamily || newConfig.fontSize != config.fontSize
        config = newConfig
        if fontChanged { applyFonts() }
        applySettings()
    }

    private func applySettings() {
        surface.theme = config.theme
        surface.padding = (config.windowPaddingX, config.windowPaddingY)
        surface.fontThicken = config.fontThicken
        surface.cursorStyle = config.cursorStyle
        surface.cursorBlink = config.cursorStyleBlink
        surface.optionAsMeta = config.optionAsMeta
        surface.mouseScrollMultiplier = config.mouseScrollMultiplier
        surface.mouseScrollAlternate = config.mouseScrollAlternate
        surface.pasteProtection = config.pasteProtection
        surface.copyOnSelect = config.copyOnSelect
        window?.backgroundColor = config.theme.palette.background.nsColor
        updateResizeIncrements()
    }

    private func applyFonts() {
        let size = fontSizeOverride ?? config.fontSize
        surface.setFonts(FontSet(family: config.fontFamily, size: CGFloat(size)))
        updateResizeIncrements()
    }

    /// Resizing by hand moves in whole cells, so no sliver of a cell is ever left over.
    private func updateResizeIncrements() {
        guard let window else { return }
        window.contentResizeIncrements = surface.cellSize
        window.contentMinSize = surface.size(columns: 20, rows: 4)
    }

    // MARK: - Actions

    override func newWindowForTab(_ sender: Any?) {
        onNewTab(self)
    }

    @objc func increaseFontSize(_ sender: Any?) {
        setFontSize((fontSizeOverride ?? config.fontSize) + 1)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        setFontSize((fontSizeOverride ?? config.fontSize) - 1)
    }

    @objc func resetFontSize(_ sender: Any?) {
        fontSizeOverride = nil
        applyFonts()
    }

    private func setFontSize(_ size: Double) {
        let clamped = min(max(size.rounded(), Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
        guard clamped != (fontSizeOverride ?? config.fontSize) else { return }
        fontSizeOverride = clamped == config.fontSize ? nil : clamped
        applyFonts()
    }

    #if DEBUG
        /// Debug › Log Frame Stats: this tab's drawing and latency numbers, to the log (for
        /// `log stream`) and in a sheet.
        @objc func logFrameStats(_ sender: Any?) {
            let summary = surface.frameStats.summary
            Logger(subsystem: "local.deathraceforcode.DeathRace", category: "Stats")
                .notice("\(summary, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Frame Stats"
            alert.informativeText = summary
            if let window { alert.beginSheetModal(for: window, completionHandler: nil) }
        }
    #endif

    // MARK: - NSWindowDelegate

    /// Closing a tab with a program running in it, anything but the shell at its prompt,
    /// asks first (`confirm-close`). Finding out takes a moment, so the window says no for
    /// now and closes itself once it knows.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard config.confirmClose, !closeConfirmed, let session, session.status == .running else { return true }
        Task { await confirmClose() }
        return false
    }

    private func confirmClose() async {
        guard let window, window.attachedSheet == nil else { return }
        guard let process = await session?.foregroundProcess(), !process.isShell else { return closeNow() }
        let alert = NSAlert()
        alert.messageText = "Goodbye & Good Riddance?"
        alert.informativeText =
            "\(process.name.isEmpty ? "A program" : process.name) is still running in this tab. Close it anyway?"
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        if await alert.beginSheetModal(for: window) == .alertFirstButtonReturn { closeNow() }
    }

    private func closeNow() {
        closeConfirmed = true
        window?.close()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        surface.focusChanged()
        onInputStateChange?()
    }

    func windowDidResignKey(_ notification: Notification) {
        surface.focusChanged()
        onInputStateChange?()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        surface.visibilityChanged()
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        surface.shutDown()
        session?.close()
        onClose(self)
    }
}

/// A terminal window. It takes the tab shortcuts before the view or the menus see them.
///
/// Keys are matched by position, so the shortcuts work on layouts whose number row or
/// brackets type other characters (AZERTY, German).
final class TerminalWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let tabs = tabGroup?.windows, tabs.count > 1 else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘1 to ⌘8 show that tab and ⌘9 the last one, as in browsers.
        if modifiers == .command, let number = Self.numberKeys[event.keyCode], number == 9 || number <= tabs.count {
            tabs[number == 9 ? tabs.count - 1 : number - 1].makeKeyAndOrderFront(nil)
            return true
        }
        // ⌘⇧[ and ⌘⇧] show the previous and next tab, as in Terminal.
        if modifiers == [.command, .shift], event.keyCode == Self.leftBracket || event.keyCode == Self.rightBracket {
            if event.keyCode == Self.leftBracket { selectPreviousTab(nil) } else { selectNextTab(nil) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The number row's virtual key codes (kVK_ANSI_1 … kVK_ANSI_9).
    private static let numberKeys: [UInt16: Int] = [
        0x12: 1, 0x13: 2, 0x14: 3, 0x15: 4, 0x17: 5, 0x16: 6, 0x1A: 7, 0x1C: 8, 0x19: 9,
    ]
    /// kVK_ANSI_LeftBracket and kVK_ANSI_RightBracket.
    private static let leftBracket: UInt16 = 0x21
    private static let rightBracket: UInt16 = 0x1E
}
