import AppCore
import AppKit
import ConfigKit
import Foundation
import PTYKit
import RenderKit
import SSHKit
import SessionKit
import SurfaceCore
import TerminalUI
import VTCore
import Vault
import os

/// What a pane needs of its shell's session. It is SessionKit's `ShellSession`: `Session` in
/// this process, `RemoteSession` when the daemon is holding the shell, a stand-in in tests.
typealias PaneSession = ShellSession

/// Starts the session for a new pane.
///
/// `mayOutliveTheApp` says whether this pane's shell is one the session daemon may keep: a
/// local shell is, a session on a host is not, because it runs through an ssh connection this
/// app owns and goes when it does.
typealias SessionMaker =
    @MainActor (
        _ launch: ShellLaunch, _ configuration: Terminal.Configuration, _ mayOutliveTheApp: Bool,
        _ onUpdate: @escaping @Sendable () -> Void
    ) throws -> any PaneSession

/// One pane: a terminal view and the shell running in it, or a session on a host. It keeps
/// what the window shows about it (title, directory, program, how it ended, what it says
/// along its bottom) and does what the program asks of the app (bell, clipboard).
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
    /// What the pane runs: a shell, or a session on a host.
    private(set) var launch: PaneLaunch
    private let connections: (any HostConnecting)?
    /// What the pane says along its bottom: connecting, why it couldn't, how it ended.
    private(set) var banner: PaneBanner?
    /// Why the last connection didn't come up, for what its banner's buttons do.
    private var failure: ConnectionFailure?
    private var connecting: Task<Void, Never>?

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
    /// The link ⌘ is held over changed.
    var onLinkHover: (() -> Void)?
    /// Shows a sheet on the pane's window; nil without one.
    var presentAlert: (@MainActor (NSAlert) async -> NSApplication.ModalResponse?)?
    /// The banner changed.
    var onBannerChange: (() -> Void)?

    /// A shell in this process, which is what every phase before Legends Never Die did and
    /// what the app falls back to whenever the daemon cannot be used.
    static let realSession: SessionMaker = { launch, configuration, _, onUpdate in
        try Session(launch: launch, configuration: configuration, onUpdate: onUpdate)
    }

    init(
        id: PaneID, config: Config, directory: String?, scale: CGFloat,
        makeSession: @escaping SessionMaker = PaneController.realSession, launch paneLaunch: PaneLaunch = .shell,
        connections: (any HostConnecting)? = nil, bests: BestsService? = nil, notifier: (any Notifier)? = nil
    ) {
        self.id = id
        self.config = config
        self.makeSession = makeSession
        self.launch = paneLaunch
        self.connections = connections
        self.bests = bests
        self.notifier = notifier
        let launch = ShellLaunchPlan.launch(
            config: config, directory: directory, appVersion: DeathRaceApplication.version)
        if let host = paneLaunch.host {
            shellName = connections?.name(of: host) ?? "ssh"
        } else {
            shellName = launch.executable.split(separator: "/").last.map(String.init) ?? "Shell"
        }
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
        surface.onHoverLink = { [weak self] _ in self?.onLinkHover?() }
        surface.onOpenLink = { [weak self] link in self?.open(link) }
        switch paneLaunch {
        case .shell: start(launch)
        case .connection(let host): connect(host)
        case .plainSSH(let host): startPlain(host)
        }
    }

    // MARK: - A session on a host

    /// The host's name, for a pane on one.
    var hostName: String? { launch.host.map { connections?.name(of: $0) ?? shellName } }

    /// Connects, saying so along the bottom, and starts the session once the master is up.
    private func connect(_ host: HostRef) {
        guard let connections else {
            return setBanner(.failed(.other("WRLD isn't available."), host: shellName, address: nil))
        }
        let name = connections.name(of: host)
        setBanner(.connecting(to: name))
        connecting?.cancel()
        let id = self.id
        connecting = Task { [weak self] in
            let result = await connections.connect(host, for: id)
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .ready(let launch):
                self.setBanner(nil)
                self.start(launch)
                // The host's on-connect snippet, typed as the session starts: through the
                // master there's no login in the pane for it to answer by mistake.
                if let command = connections.onConnectCommand(for: host) {
                    for input in TypedInput.snippet(command, run: true) { self.surface.receive(input) }
                }
            case .failed(let failure):
                self.failure = failure
                self.setBanner(.failed(failure, host: name, address: connections.address(of: host)))
            }
        }
    }

    /// ssh on its own in the pane: it asks for passwords there, as in Terminal.
    private func startPlain(_ host: HostRef) {
        guard let connections else { return }
        setBanner(nil)
        connecting?.cancel()
        connecting = Task { [weak self] in
            guard let launch = await connections.plainLaunch(host), let self, !Task.isCancelled else { return }
            self.start(launch)
        }
    }

    private func setBanner(_ banner: PaneBanner?) {
        guard banner != self.banner else { return }
        self.banner = banner
        onBannerChange?()
    }

    /// A button on the banner.
    func press(_ button: PaneBanner.Button) {
        switch button {
        case .cancel:
            // Stop the pane's own connect task too, not just the pool's startup, so nothing
            // finishes connecting for a pane you cancelled.
            connecting?.cancel()
            if let host = launch.host { connections?.cancel(host) }
        case .reconnect, .restart:
            restart()
        case .plainSSH:
            guard let host = launch.host else { return }
            launch = .plainSSH(host)
            restart()
        case .allowLocalNetwork:
            NSWorkspace.shared.open(Self.localNetworkSettings)
        case .forgetHostKey:
            forgetHostKey()
        }
    }

    /// After a host's key changed: both keys side by side, a plain warning, and only then
    /// the old key forgotten and the connection tried again, where ssh asks about the new
    /// key as for a host it has never seen.
    private func forgetHostKey() {
        guard case .hostKeyChanged(let fingerprint, _, let removal?) = failure, let connections else { return }
        let name = hostName ?? shellName
        let host = launch.host
        Task {
            let old = await connections.knownKeys(removal, for: host).map { "\($0.fingerprint) (\($0.type))" }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Forget the key ssh trusted for \(name)?"
            alert.informativeText = [
                "It trusted: \(old.isEmpty ? "a key no longer in the file" : old.joined(separator: ", ")).",
                "It was sent: \(fingerprint ?? "a different key").",
                "A server that was reinstalled gets a new key. So does one someone is pretending to be: check the new one with whoever runs \(name) before you trust it. ssh asks about it as you reconnect.",
            ].joined(separator: "\n\n")
            alert.addButton(withTitle: "Forget the Old Key")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            guard await presentAlert?(alert) == .alertFirstButtonReturn else { return }
            if let problem = await connections.forgetKey(removal, for: host) {
                let failed = NSAlert()
                failed.messageText = "ssh-keygen didn’t forget the key"
                failed.informativeText = problem
                _ = await presentAlert?(failed)
                return
            }
            restart()
        }
    }

    /// System Settings, at Privacy & Security › Local Network.
    static let localNetworkSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

    // MARK: - The shell

    private func start(_ launch: ShellLaunch) {
        let grid = surface.grid
        let terminal = Terminal.Configuration(
            columns: grid.columns, rows: grid.rows, scrollbackLimitBytes: config.scrollbackLimit,
            palette: config.theme.palette, version: DeathRaceApplication.version,
            cellPixelWidth: surface.cell.width, cellPixelHeight: surface.cell.height)
        let surface = self.surface
        do {
            let session = try makeSession(launch, terminal, self.launch.host == nil) { [weak self] in
                // On the session's thread: hop to the main thread, where the view lives. `self`
                // (a @MainActor class) is Sendable and may cross into this @Sendable callback;
                // the view, an NSView subclass, is not, so we reach it through `self` on main.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.surface.sessionDidUpdate() }
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

    /// A new shell in the same place after the last one ended badly, or a new connection.
    func restart() {
        failure = nil
        session?.close()
        title = ""
        foreground = nil
        end = nil
        setBanner(nil)
        switch launch {
        case .shell:
            start(
                ShellLaunchPlan.launch(config: config, directory: directory, appVersion: DeathRaceApplication.version))
        case .connection(let host): connect(host)
        case .plainSSH(let host): startPlain(host)
        }
        onChange?()
    }

    /// Lets go of the pane. `leaving` is the app quitting rather than this pane closing, and
    /// it is the only time a shell is left running instead of hung up.
    ///
    /// Every call site has to say which it means. Getting one wrong is how this feature either
    /// kills a shell someone expected to keep, or keeps one they expected to be rid of.
    func shutDown(leaving: Bool = false) {
        for work in refreshes { work.cancel() }
        connecting?.cancel()
        surface.shutDown()
        if leaving, survivesQuit {
            session?.detach()
        } else {
            session?.close()
        }
        if launch.host != nil { connections?.release(id) }
    }

    /// Which session this pane holds, for the record of where each one belonged; nil before
    /// it has one, and for a pane whose connection failed.
    var sessionID: SessionID? { session?.id }

    /// Whether this pane's shell will still be running after the app quits: a local one, held
    /// by the daemon. A pane on a host never is.
    var survivesQuit: Bool {
        launch.host == nil && session?.outlivesItsClient == true
    }

    var isRunning: Bool { session?.status == .running }

    /// Nothing typed here reaches a program: the session ended, or the connection failed.
    var isDone: Bool { end != nil || (session == nil && banner?.isWorking == false) }

    /// Where the pane is: where the shell last said, else the directory of the program in
    /// the foreground when last asked. (The zsh that comes with macOS sends OSC 7 only
    /// inside Terminal.) Nil on a host: its directories aren't this Mac's.
    var directory: String? {
        guard launch.host == nil else { return nil }
        return reportedDirectory ?? foreground?.workingDirectory
    }

    /// The program in the foreground, for the status bar; on a host, the host.
    var programName: String? {
        if let hostName { return hostName }
        return foreground.map { $0.name.isEmpty ? shellName : $0.name }
    }

    /// The directory for a pane or tab opened from this one: asked of the session now.
    func currentDirectory() async -> String? {
        guard launch.host == nil else { return nil }
        if let reportedDirectory { return reportedDirectory }
        return await session?.foregroundProcess()?.workingDirectory ?? directory
    }

    /// What closing would end, to name it: anything but the shell at its prompt, and any
    /// session on a host, whose programs can't be seen from here. Nil when there is nothing
    /// to lose.
    func runningProgram() async -> String? {
        if let hostName { return isRunning ? "\(hostName)’s session" : nil }
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
            case .progress(let report):
                // OSC 9;4's five states collapse to the two a 3 pt fill can carry. `cleared`
                // is nil rather than zero: a bar at zero reads as stuck, and the program means
                // "forget it".
                progress =
                    switch report {
                    case .cleared: nil
                    case .normal(let percent): TabProgress(fraction: Double(percent) / 100)
                    case .error(let percent): TabProgress(fraction: percent.map { Double($0) / 100 }, failed: true)
                    case .indeterminate: TabProgress(fraction: nil)
                    case .paused(let percent): TabProgress(fraction: percent.map { Double($0) / 100 })
                    }
                onChange?()
            case .notification:
                // A program said something itself. Ring Ring stays quiet about the command it
                // was part of; the flag clears when that command ends.
                programNotified = true
            case .promptMark(.commandEnd, let rowID):
                // The record is on the row, not in the event: the mark carries only the exit
                // code, while the duration and the text come from `OSC 633;E` and `dur=`. The
                // row is in view at the moment a command ends, because the cursor is on it.
                guard let mirror = surface.model?.mirror,
                    let row = mirror.lines.firstIndex(where: { $0.id == rowID }),
                    let command = mirror.lines[row].command
                else { continue }
                // Which line that row is, taken here and only here: it is the one moment the
                // row is certainly in view, and the number stays with the line for good, so a
                // tap on the bar can still find the command after it has scrolled away.
                lastCommandLine = mirror.viewportTopLine &+ UInt64(row)
                finished(command)
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
        if let host = launch.host {
            connections?.release(id)
            let plain = launch == .plainSSH(host)
            setBanner(PaneBanner.ended(exit, host: hostName ?? shellName, plain: plain))
        } else if end.isFailure {
            setBanner(PaneBanner(message: end.sentence, buttons: [.restart]))
        }
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

    // MARK: - Links

    /// A ⌘-clicked link, as the link policy says: web and mail links open; a file on this Mac
    /// is shown in Finder, never opened; another scheme asks first, naming the app it would
    /// open; the rest are refused, saying why. A program's link whose text names another
    /// site than the one it opens asks first too.
    func open(_ link: LinkHit) {
        let shown = LinkPolicy.shown(link.uri)
        switch LinkPolicy.action(for: link.uri, localHostNames: [ProcessInfo.processInfo.hostName]) {
        case .open(let uri):
            guard let url = URL(string: uri) else { return refuse(link, "It is not an address a browser takes.") }
            if link.isExplicit && LinkPolicy.misleads(text: link.text, target: uri) {
                confirm(
                    "This link goes somewhere other than its text says",
                    detail: "Its text says “\(LinkPolicy.visibleText(link.text))”, but it opens \(shown).",
                    button: "Open Link"
                ) { NSWorkspace.shared.open(url) }
            } else {
                NSWorkspace.shared.open(url)
            }
        case .reveal(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .confirm(let scheme):
            guard let url = URL(string: link.uri), let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
                return refuse(link, "No app on this Mac opens \(scheme): links.")
            }
            let name = FileManager.default.displayName(atPath: app.path)
            confirm("Open this link in \(name)?", detail: shown, button: "Open in \(name)") {
                NSWorkspace.shared.open(url)
            }
        case .refuse(let reason):
            refuse(link, Self.reason(reason))
        }
    }

    private static func reason(_ refusal: LinkRefusal) -> String {
        switch refusal {
        case .malformed: "It is not a complete address."
        case .tooLong: "It is longer than any browser takes."
        case .script: "Links that run code in a browser (javascript: and data:) are never opened."
        case .otherComputer(let host): "It is a file on \(host), not on this Mac."
        }
    }

    private func refuse(_ link: LinkHit, _ why: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Death Race won’t open this link"
        alert.informativeText = "\(why)\n\n\(LinkPolicy.shown(link.uri))"
        Task { _ = await presentAlert?(alert) }
    }

    private func confirm(_ question: String, detail: String, button: String, then open: @escaping @MainActor () -> Void)
    {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        Task {
            guard await presentAlert?(alert) == .alertFirstButtonReturn else { return }
            open()
        }
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
        surface.starfield = config.starfield && config.namedTheme.hasStars
        applyConversations()
        surface.frameRatePolicy = FrameRatePolicy(
            followsLowPowerMode: config.followLowPowerMode, capsOutput: config.outputFrameRateCap)
    }

    /// Conversations, on or off, and everything it needs: the colors the rail and the band are
    /// drawn in, and the one closure that turns what the shell said into a picture.
    ///
    /// The words and the records they are compared against are decided here rather than in the
    /// view, because they are the app's: `TerminalUI` has no business knowing what "faster than
    /// your best" means, and does not depend on `AppCore`, which does.
    private func applyConversations() {
        guard config.shellIntegration, config.conversations else {
            surface.blockColors = nil
            surface.makeBadge = nil
            return
        }
        surface.blockColors = Chrome(config.namedTheme).blockColors
        // `[weak self]` and nothing else captured, the shape every other callback here takes:
        // the work is a method of this class, so it stays on the main actor where the chrome
        // and the records live, and a theme or a threshold changed since is read rather than
        // remembered.
        surface.makeBadge = { [weak self] command, scale in self?.badge(for: command, scale: scale) }
    }

    private func badge(for command: CommandRecord, scale: CGFloat) -> CommandBadge? {
        let best = command.text.isEmpty ? nil : bests?.best(for: command.text)
        guard
            let words = FastLabel.words(
                milliseconds: command.durationMilliseconds, exitCode: command.exitCode, bestMilliseconds: best,
                thresholdMilliseconds: UInt32(clamping: config.fastThresholdMilliseconds))
        else { return nil }
        let isBest = FastLabel.isPersonalBest(
            milliseconds: command.durationMilliseconds, exitCode: command.exitCode, bestMilliseconds: best)
        guard let picture = Chrome(config.namedTheme).badge(words, isPersonalBest: isBest, scale: scale) else {
            return nil
        }
        return CommandBadge(picture: picture, isPersonalBest: isBest)
    }

    /// The app's record of how fast each command has been, shared by every pane and kept on
    /// disk. Records are set from `promptMark` events, which arrive once per command, rather
    /// than from the rows a frame happens to show: a row is drawn again whenever the screen
    /// moves, and a time already recorded would then be offered as the thing to beat.
    ///
    /// Nil in a pane built without one — the chrome previews and most window tests — and the
    /// badge then simply has nothing to compare against.
    private let bests: BestsService?
    /// Ring Ring's delivery, nil where there is none.
    private let notifier: (any Notifier)?

    /// What the last command in this pane did, for the status bar's Fast run and the health
    /// count. Nil in a pane whose shell says nothing about commands.
    private(set) var lastCommand: CommandOutcome?
    /// The line the last command ended on, so a tap on the Fast run can scroll back to it.
    /// Kept here rather than on `CommandOutcome`, which is portable and has no business
    /// carrying a number that only means something to a view.
    private(set) var lastCommandLine: UInt64?

    /// A command ended: remember its time, tell the bar, and say so out loud if it is worth
    /// interrupting for.
    private func finished(_ command: CommandRecord) {
        let beaten = bests?.record(command)
        lastCommand = CommandOutcome(
            text: command.text, milliseconds: command.durationMilliseconds, exitCode: command.exitCode,
            // What it beat, so the bar can say by how much; `record` answers that only when the
            // run actually won, which is the same rule the badge follows.
            bestMilliseconds: beaten,
            thresholdMilliseconds: UInt32(clamping: config.fastThresholdMilliseconds))
        onChange?()

        // Cleared here, before anything can return: the flag is about the command that just
        // ended, and a pane with no notifier would otherwise keep it set for good.
        let saidSoItself = programNotified
        programNotified = false

        guard let notifier else { return }
        // Watched means: this pane is on screen, in the tab in front, in a window you can see.
        // The window controller keeps that answer, because a pane cannot see its own tab.
        let notice = RingRing.notice(
            for: RingRing.Finished(
                command: command.text, milliseconds: command.durationMilliseconds, exitCode: command.exitCode,
                wasWatched: isWatched?() ?? false, programNotified: saidSoItself),
            thresholdSeconds: UInt32(clamping: config.ringRingThresholdSeconds))
        if let notice { notifier.deliver(notice, paneID: UInt64(id.value)) }
    }

    /// Whether this pane is the one being looked at, asked of the window rather than guessed.
    var isWatched: (() -> Bool)?

    /// The program sent its own `OSC 9` since the last command ended, so Ring Ring stays quiet
    /// about this one: two notifications for one command is worse than none.
    private var programNotified = false

    /// What a program in this pane last reported about its own progress, for its tab's pill.
    private(set) var progress: TabProgress?

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
