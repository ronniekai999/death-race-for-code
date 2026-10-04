import AppCore
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

/// What a pane needs of its shell's session; `Session` in the app, a stand-in in tests.
protocol PaneSession: SurfaceSession {
    func foregroundProcess() async -> ForegroundProcess?
    func close()
}

extension Session: PaneSession {}

/// Starts the session for a new pane.
typealias SessionMaker =
    @MainActor (
        _ launch: ShellLaunch, _ configuration: Terminal.Configuration, _ onUpdate: @escaping @Sendable () -> Void
    ) throws -> any PaneSession

/// One pane: a terminal view and the shell running in it. It keeps what the window shows
/// about the shell (title, directory, program, how it ended) and does what the shell asks
/// of the app (bell, clipboard).
@MainActor
final class PaneController {
    let id: PaneID
    let surface: TerminalSurfaceView
    private(set) var session: (any PaneSession)?
    private var config: Config
    /// The font size ⌘+ and ⌘− chose for this pane; nil follows the settings.
    private var fontSizeOverride: Double?
    private let makeSession: SessionMaker
    let shellName: String

    /// The title the program set (OSC 0/2), or empty.
    private(set) var title = ""
    /// Where the shell said it is (OSC 7).
    private(set) var reportedDirectory: String?
    /// Who was in the foreground when last asked.
    private(set) var foreground: ForegroundProcess?
    /// How the shell ended, once it has.
    private(set) var end: ShellEnd?
    private var refreshes: [DispatchWorkItem] = []

    /// The title, program or directory changed.
    var onChange: (() -> Void)?
    /// The shell ended.
    var onEnd: ((ShellEnd) -> Void)?
    /// The bell rang (after it was rung as the settings say).
    var onBell: (() -> Void)?
    /// The screen changed.
    var onOutput: (() -> Void)?
    /// The terminal view became first responder.
    var onActivated: (() -> Void)?
    /// The terminal view gained or lost keyboard focus.
    var onFocusChange: (() -> Void)?
    /// The program started or stopped reading a password.
    var onPasswordInputChange: (() -> Void)?
    /// Shows a sheet on the pane's window; nil without one.
    var presentAlert: (@MainActor (NSAlert) async -> NSApplication.ModalResponse?)?

    static let realSession: SessionMaker = { launch, configuration, onUpdate in
        try Session(launch: launch, configuration: configuration, onUpdate: onUpdate)
    }

    init(
        id: PaneID, config: Config, directory: String?, scale: CGFloat,
        makeSession: @escaping SessionMaker = PaneController.realSession
    ) {
        self.id = id
        self.config = config
        self.makeSession = makeSession
        let launch = ShellLaunchPlan.launch(
            config: config, directory: directory, appVersion: DeathRaceApplication.version)
        shellName = launch.executable.split(separator: "/").last.map(String.init) ?? "Shell"
        surface = TerminalSurfaceView(
            fonts: FontSet(
                family: config.fontFamily, size: CGFloat(config.fontSize), italicFamily: config.fontFamilyItalic),
            theme: config.theme,
            padding: (config.windowPaddingX, config.windowPaddingY), scale: scale)
        applySettings()
        surface.onTitleChange = { [weak self] title in
            self?.title = title
            self?.onChange?()
        }
        surface.onEvents = { [weak self] events in self?.handle(events) }
        surface.onExit = { [weak self] status in self?.ended(status) }
        surface.onPasswordInputChange = { [weak self] in self?.onPasswordInputChange?() }
        surface.onFirstResponder = { [weak self] in self?.onActivated?() }
        surface.onFocusChange = { [weak self] focused in
            if focused { self?.refreshForeground() }
            self?.onFocusChange?()
        }
        surface.onOutput = { [weak self] in self?.onOutput?() }
        surface.onReturnKey = { [weak self] in self?.refreshSoon() }
        start(launch)
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
            let session = try makeSession(launch, terminal) { [weak surface] in
                // On the session's thread: hop to the main thread, where the view lives.
                let target = surface
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { target?.sessionDidUpdate() }
                }
            }
            self.session = session
            end = nil
            surface.attach(session)
        } catch {
            end = .unknown
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "The shell did not start"
            alert.informativeText = "Death Race could not run \(launch.executable): \(error)"
            Task { _ = await presentAlert?(alert) }
        }
    }

    /// A new shell in the same place, after the last one ended badly.
    func restart() {
        session?.close()
        title = ""
        foreground = nil
        let launch = ShellLaunchPlan.launch(
            config: config, directory: directory, appVersion: DeathRaceApplication.version)
        start(launch)
        onChange?()
    }

    func shutDown() {
        for work in refreshes { work.cancel() }
        surface.shutDown()
        session?.close()
    }

    var isRunning: Bool { session?.status == .running }

    /// Where the pane is: where the shell last said, else the directory of the program in
    /// the foreground when last asked. (The zsh that comes with macOS sends OSC 7 only
    /// inside Terminal.)
    var directory: String? { reportedDirectory ?? foreground?.workingDirectory }

    /// The program in the foreground, for the status bar.
    var programName: String? { foreground.map { $0.name.isEmpty ? shellName : $0.name } }

    /// The directory for a pane or tab opened from this one: asked of the session now.
    func currentDirectory() async -> String? {
        if let reportedDirectory { return reportedDirectory }
        return await session?.foregroundProcess()?.workingDirectory ?? directory
    }

    /// The program to name when closing would end it: anything but the shell at its
    /// prompt. Nil when there is nothing to lose.
    func runningProgram() async -> String? {
        guard isRunning, let process = await session?.foregroundProcess(), !process.isShell else { return nil }
        return process.name.isEmpty ? "A program" : process.name
    }

    /// Asks the session who is in the foreground.
    func refreshForeground() {
        Task { [weak self] in
            guard let process = await self?.session?.foregroundProcess() else { return }
            guard let self, process != self.foreground else { return }
            self.foreground = process
            self.onChange?()
        }
    }

    /// After Return a program may start or the directory change, but not at once: look
    /// twice, soon and a little later.
    private func refreshSoon() {
        for work in refreshes { work.cancel() }
        refreshes = [0.15, 1.0].map { delay in
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.refreshForeground() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private func handle(_ events: [TerminalEvent]) {
        for event in events {
            switch event {
            case .bell:
                ring()
                onBell?()
            case .clipboardWrite(_, let contents):
                writeClipboard(String(decoding: contents, as: UTF8.self))
            case .workingDirectoryChanged(let report):
                guard
                    let path = WorkingDirectoryURL.path(
                        from: report, localHostNames: [ProcessInfo.processInfo.hostName])
                else { continue }
                reportedDirectory = path
                onChange?()
            default:
                break
            }
        }
    }

    private func ended(_ status: Session.Status) {
        guard case .exited(let exit) = status else { return }
        let end: ShellEnd
        switch exit {
        case .exited(let code)?: end = .exited(code: code)
        case .signaled(let signal)?: end = .signaled(signal)
        case nil: end = .unknown
        }
        self.end = end
        onEnd?(end)
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
    /// focused pane of the active app may, as `clipboard-write` allows; with `ask`, a
    /// sheet shows the text first.
    private func writeClipboard(_ text: String) {
        guard !text.isEmpty, surface.isFocused, config.clipboardWrite != .deny else { return }
        guard config.clipboardWrite == .ask else { return Self.setClipboard(text) }
        let alert = NSAlert()
        alert.messageText = "Let the program in this pane copy text to the clipboard?"
        alert.informativeText = PasteWarning.visible(text, limit: 300)
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Don’t Copy")
        Task {
            guard await presentAlert?(alert) == .alertFirstButtonReturn else { return }
            Self.setClipboard(text)
        }
    }

    private static func setClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Settings

    /// Applies reloaded settings: fonts, colors, padding, the cursor, keys and the mouse
    /// change at once; the rest waits for new panes.
    func apply(_ newConfig: Config) {
        let fontChanged =
            newConfig.fontFamily != config.fontFamily || newConfig.fontSize != config.fontSize
            || newConfig.fontFamilyItalic != config.fontFamilyItalic
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
    }

    private func applyFonts() {
        surface.setFonts(
            FontSet(
                family: config.fontFamily, size: CGFloat(fontSizeOverride ?? config.fontSize),
                italicFamily: config.fontFamilyItalic))
    }

    static let fontSizes = 6.0...144.0

    func changeFontSize(by step: Double) {
        let size = (fontSizeOverride ?? config.fontSize) + step
        let clamped = min(max(size.rounded(), Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
        guard clamped != (fontSizeOverride ?? config.fontSize) else { return }
        fontSizeOverride = clamped == config.fontSize ? nil : clamped
        applyFonts()
    }

    func resetFontSize() {
        guard fontSizeOverride != nil else { return }
        fontSizeOverride = nil
        applyFonts()
    }

    #if DEBUG
        var frameStatsSummary: String { surface.frameStats.summary }

        func logFrameStats() {
            Logger(subsystem: "local.deathraceforcode.DeathRace", category: "Stats")
                .notice("\(self.frameStatsSummary, privacy: .public)")
        }
    #endif
}
