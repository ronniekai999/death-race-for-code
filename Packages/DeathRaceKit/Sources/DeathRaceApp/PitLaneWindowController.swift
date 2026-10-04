import AppCore
import AppKit
import ConfigKit
import Foundation
import LegendsUI
import SSHKit
import SurfaceCore
import TerminalUI
import VTCore
import Vault

/// Hands out pane and tab numbers, unique across windows, so a tab keeps its identity
/// when it moves to another window.
@MainActor
final class IDSource {
    private var next = 1

    func pane() -> PaneID {
        defer { next += 1 }
        return PaneID(next)
    }

    func tab() -> TabID {
        defer { next += 1 }
        return TabID(next)
    }
}

/// What a window asks of the app: windows for tabs that move out, and a word when it
/// closes or when Secure Keyboard Entry might change.
@MainActor
protocol WindowHost: AnyObject {
    var ids: IDSource { get }
    var makeSession: SessionMaker { get }
    func windowClosed(_ controller: PitLaneWindowController)
    func inputStateChanged()
    func open(
        detached tab: TabModel, panes: [PaneController], area: PaneAreaView, from controller: PitLaneWindowController)

    // Hear Me Calling's reach beyond its window.
    /// Every window's panes, `controller`'s first.
    func places(from controller: PitLaneWindowController) -> [PaletteItem]
    /// Brings forward the window holding `pane` and gives the pane the keys.
    func focus(pane: PaneID, from controller: PitLaneWindowController)
    /// WRLD, for panes on hosts; nil where there is none.
    var connections: (any HostConnecting)? { get }
    /// The WRLD window at `place`, with `host` in its inspector when given.
    func showWRLD(at place: WRLDBoard.Place, selecting host: HostID?)
    /// Whether a new window opens with the WRLD sidebar: as the last one was left.
    var sidebarPreferred: Bool { get set }
    /// Writes `theme = id` for every window.
    func chooseTheme(_ id: String) throws
    func showSettings(page: SettingsCatalog.Page?)
    /// Earlier picks, most recent first.
    var recentPicks: [String] { get }
    func picked(_ id: String)
}

extension WindowHost {
    /// No WRLD: previews and window tests that don't connect anywhere.
    var connections: (any HostConnecting)? { nil }
    func showWRLD(at place: WRLDBoard.Place, selecting host: HostID?) {}
    var sidebarPreferred: Bool {
        get { false }
        set {}
    }
}

/// One window: tabs of split panes under the Pit Lane chrome. The tabs and panes live in a
/// `WindowModel`; this keeps the views and the panes' controllers in step with it.
@MainActor
final class PitLaneWindowController: NSWindowController, NSWindowDelegate, WindowShortcuts {
    private(set) var model = WindowModel()
    private(set) var panes: [PaneID: PaneController] = [:]
    private var areas: [TabID: PaneAreaView] = [:]
    private var activity: [TabID: TabActivity] = [:]
    private var quietChecks: [TabID: DispatchWorkItem] = [:]
    private(set) var config: Config
    private var chrome: Chrome
    let root: PitLaneRootView
    private weak var host: (any WindowHost)?
    private let ids: IDSource
    private let makeSession: SessionMaker
    /// The user agreed to close the window with programs running in it.
    private var closeConfirmed = false
    /// A question is on screen: further close requests wait for its answer.
    private var confirming = false
    /// The last branch read, by directory, so the status bar can draw at once.
    private var branches: [String: String] = [:]
    private var branchRead: [String: Date] = [:]
    /// Hear Me Calling, while it is open.
    private(set) var hearMeCalling: HearMeCallingOverlay?
    /// The theme Hear Me Calling shows on this window while its row is highlighted.
    private var previewThemeID: String?
    /// A Wishing Well sheet, while one is open.
    private var wishingWellSheet: WishingWellSheet?

    /// Shown while Secure Keyboard Entry is on and this is the key window.
    var showsSecureInput = false {
        didSet { if showsSecureInput != oldValue { refreshStatus() } }
    }
    /// Settings lines the last automatic reload could not use.
    var settingsProblems = 0 {
        didSet { if settingsProblems != oldValue { refreshStatus() } }
    }
    var onSettingsProblemsClick: (() -> Void)?

    /// A new window with one tab, in `directory` (with `working-directory = inherit`).
    convenience init(config: Config, host: any WindowHost, directory: String?) {
        self.init(config: config, host: host)
        let pane = makePane(directory: directory)
        let tab = TabModel(id: ids.tab(), pane: pane.id)
        sizeWindow(toFit: pane)
        install(tab, panes: [pane], area: nil)
    }

    /// A window for a tab moved out of another one.
    convenience init(
        config: Config, host: any WindowHost, adopting tab: TabModel, panes: [PaneController], area: PaneAreaView
    ) {
        self.init(config: config, host: host)
        if let pane = panes.first { sizeWindow(toFit: pane) }
        install(tab, panes: panes, area: area)
    }

    private init(config: Config, host: any WindowHost) {
        self.config = config
        self.host = host
        ids = host.ids
        makeSession = host.makeSession
        chrome = Chrome(config.namedTheme)
        root = PitLaneRootView(chrome: chrome)
        let window = PitLaneWindow.make(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600))
        super.init(window: window)
        window.delegate = self
        window.shortcuts = self
        window.contentView = root
        let strip = root.titleBar.strip
        strip.onSelect = { [weak self] id in self?.select(id) }
        strip.onClose = { [weak self] id in self?.requestClose(tab: id) }
        strip.onDetach = { [weak self] id in self?.detach(id) }
        strip.onMove = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        strip.onNewTab = { [weak self] in self?.newTab(nil) }
        root.statusBar.onTap = { [weak self] tap in
            switch tap {
            case .settingsProblems: self?.onSettingsProblemsClick?()
            }
        }
        applyChrome()
        tunnelsObserver = NotificationCenter.default.addObserver(
            forName: .tunnelsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStatus()
                self?.refreshSidebar()
            }
        }
        wrldObserver = NotificationCenter.default.addObserver(forName: .wrldChanged, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSidebar() }
        }
        root.titleBar.sidebarButton.isHidden = host.connections == nil
        root.titleBar.sidebarButton.onClick = { [weak self] in self?.toggleSidebar(nil) }
        if host.connections != nil && host.sidebarPreferred { setSidebar(shown: true) }
    }

    /// Recounts the status bar's tunnels when one opens or closes. Set once, on the main
    /// thread; read only by deinit, and removing an observer is safe from any thread.
    nonisolated(unsafe) private var tunnelsObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var wrldObserver: (any NSObjectProtocol)?

    deinit {
        if let tunnelsObserver { NotificationCenter.default.removeObserver(tunnelsObserver) }
        if let wrldObserver { NotificationCenter.default.removeObserver(wrldObserver) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PitLaneWindowController is created in code")
    }

    private var pitLaneWindow: PitLaneWindow? { window as? PitLaneWindow }

    var activePane: PaneController? { model.activePane.flatMap { panes[$0] } }

    // MARK: - Building tabs and panes

    private func makePane(directory: String?, launch: PaneLaunch = .shell) -> PaneController {
        PaneController(
            id: ids.pane(), config: config, directory: directory,
            scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, makeSession: makeSession,
            launch: launch, connections: launch.host == nil ? nil : host?.connections)
    }

    /// The panes' callbacks lead to this window; a tab moving in brings panes whose
    /// callbacks led to their old one.
    private func wire(_ pane: PaneController) {
        let id = pane.id
        pane.onChange = { [weak self] in self?.paneChanged(id) }
        pane.onEnd = { [weak self] end in self?.paneEnded(id, end) }
        pane.onBell = { [weak self] in self?.paneRang(id) }
        pane.onOutput = { [weak self] in self?.paneOutput(id) }
        pane.onActivated = { [weak self] in self?.paneActivated(id) }
        pane.onFocusChange = { [weak self] in
            self?.refreshStatus()
            self?.host?.inputStateChanged()
        }
        pane.onPasswordInputChange = { [weak self] in self?.host?.inputStateChanged() }
        pane.onLinkHover = { [weak self] in self?.refreshStatus() }
        pane.presentAlert = { [weak self] alert in await self?.present(alert) }
        pane.onBannerChange = { [weak self] in self?.showBanner(of: id) }
        pane.surface.onTyped = { [weak self] input in self?.typed(input, in: id) }
        pane.surface.pasteAlsoGoesTo = { [weak self] in self?.armedModes(besides: id) ?? [] }
        pane.surface.contextMenuItems = { [weak self] in self?.contextMenuItems(for: id) ?? [] }
        panes[id] = pane
    }

    /// A card's callbacks lead to this window; a tab moving in brings cards whose callbacks
    /// led to their old one.
    private func wire(_ card: PaneCardView) {
        let id = card.pane
        card.onToggleArmed = { [weak self] in self?.toggleArmed(of: id) }
    }

    /// The pane's banner on its card, its buttons answered by the pane.
    private func showBanner(of id: PaneID) {
        guard let pane = panes[id], let tab = model.tab(containing: id) else { return }
        areas[tab.id]?.cards[id]?.showBanner(pane.banner) { [weak self] button in self?.pressed(button, in: id) }
        // A connection that failed is one fewer pane typing reaches.
        if tab.isArmed { refreshStatus() }
    }

    private func pressed(_ button: PaneBanner.Button, in id: PaneID) {
        guard let pane = panes[id], let tab = model.tab(containing: id) else { return }
        // These ask or wait first: the tab's mark stays until something is tried again.
        if button != .cancel && button != .allowLocalNetwork && button != .forgetHostKey {
            activity[tab.id]?.failure = nil
            refreshTabs()
        }
        pane.press(button)
        window?.makeFirstResponder(pane.surface)
    }

    /// Adds a tab, with its panes and their views, and shows it.
    private func install(_ tab: TabModel, panes tabPanes: [PaneController], area existing: PaneAreaView?) {
        for pane in tabPanes { wire(pane) }
        let area = existing ?? PaneAreaView(tree: tab.tree)
        area.tree = tab.tree
        area.zoomedPane = tab.zoomedPane
        if existing == nil {
            for pane in tabPanes { area.add(PaneCardView(pane: pane.id, surface: pane.surface, chrome: chrome)) }
        }
        for card in area.cards.values { wire(card) }
        for pane in tabPanes where pane.banner != nil {
            area.cards[pane.id]?.showBanner(pane.banner) { [weak self] button in self?.pressed(button, in: pane.id) }
        }
        area.setChrome(chrome)
        area.showsStars = showsStars
        let id = tab.id
        area.onDividerDrag = { [weak self] path, position in self?.dragDivider(in: id, at: path, to: position) }
        area.onDividerDoubleClick = { [weak self] in
            guard let self, self.model.activeTabID == id else { return }
            self.equalizePanes(nil)
        }
        area.onStopArmed = { [weak self] in self?.stopArmed(id) }
        areas[tab.id] = area
        root.tabArea.addSubview(area)
        root.needsLayout = true
        model.insert(tab, at: model.activeIndex.map { $0 + 1 })
        activity[tab.id] = TabActivity()
        show(tab.id)
    }

    /// Sizes a new window for `window-size` cells in its first pane, beside the sidebar
    /// when it shows.
    private func sizeWindow(toFit pane: PaneController) {
        guard let window else { return }
        let header = config.paneHeaders == .always
        let surface = pane.surface.size(columns: config.windowSize.columns, rows: config.windowSize.rows)
        var size = PitLaneRootView.windowSize(forSurface: surface, header: header)
        size.width += root.leadingColumnWidth
        window.setContentSize(size)
        window.contentMinSize = PitLaneRootView.windowSize(
            forSurface: pane.surface.size(columns: 20, rows: 4), header: header)
    }

    // MARK: - Tabs

    @objc func newTab(_ sender: Any?) {
        // A new tab starts where the active pane is (with `working-directory = inherit`),
        // which takes a question to its session.
        Task {
            let directory = await activePane?.currentDirectory()
            let pane = makePane(directory: directory)
            install(TabModel(id: ids.tab(), pane: pane.id), panes: [pane], area: nil)
        }
    }

    private func select(_ tab: TabID) {
        guard tab != model.activeTabID else { return }
        model.selectTab(tab)
        show(tab)
    }

    /// Shows the active tab's panes, hides the others', and gives the keys to its active
    /// pane.
    private func show(_ tab: TabID) {
        for (id, area) in areas where area.isHidden != (id != tab) { area.isHidden = id != tab }
        activity[tab]?.shown()
        if let pane = model.activePane, let surface = panes[pane]?.surface, window?.firstResponder !== surface {
            window?.makeFirstResponder(surface)
        }
        refreshCards()
        refreshTabs()
        refreshStatus()
    }

    func selectTab(number: Int) -> Bool {
        let before = model.activeTabID
        guard model.selectTab(number: number) else { return false }
        if let tab = model.activeTabID, tab != before { show(tab) }
        return true
    }

    func stepTab(forward: Bool) {
        guard model.tabs.count > 1 else { return }
        if forward { model.selectNextTab() } else { model.selectPreviousTab() }
        if let tab = model.activeTabID { show(tab) }
    }

    @objc func showNextTab(_ sender: Any?) { stepTab(forward: true) }
    @objc func showPreviousTab(_ sender: Any?) { stepTab(forward: false) }

    private func moveTab(from: Int, to: Int) {
        model.moveTab(from: from, to: to)
        refreshTabs()
    }

    /// Move Tab to New Window: the tab's views and sessions go along untouched.
    @objc func detachTab(_ sender: Any?) {
        if let tab = model.activeTabID { detach(tab) }
    }

    private func detach(_ id: TabID) {
        guard model.tabs.count > 1, let host, let tab = model.removeTab(id), let area = areas.removeValue(forKey: id)
        else { return }
        let moving = tab.panes.compactMap { panes.removeValue(forKey: $0) }
        activity[id] = nil
        quietChecks.removeValue(forKey: id)?.cancel()
        area.removeFromSuperview()
        area.isHidden = false
        host.open(detached: tab, panes: moving, area: area, from: self)
        if let active = model.activeTabID { show(active) }
    }

    // MARK: - Panes

    private func paneActivated(_ id: PaneID) {
        let tabBefore = model.activeTabID
        model.activate(id)
        if model.activeTabID != tabBefore, let tab = model.activeTabID { show(tab) }
        refreshCards()
        refreshTabs()
        refreshStatus()
    }

    private func paneChanged(_ id: PaneID) {
        guard let tab = model.tab(containing: id) else { return }
        refreshCards()
        // An armed tab's pill names every armed pane.
        if tab.isArmed && tab.activePane != id { return refreshTabs() }
        guard tab.activePane == id else { return }
        refreshTabs()
        if tab.id == model.activeTabID { refreshStatus(rereadBranch: true) }
    }

    /// Output in a background tab starts its equalizer.
    private func paneOutput(_ id: PaneID) {
        guard let tab = model.tab(containing: id), tab.id != model.activeTabID else { return }
        let wasBusy = activity[tab.id]?.isBusy(at: Self.now) ?? false
        activity[tab.id, default: TabActivity()].output(at: Self.now)
        if !wasBusy { refreshTabs() }
        scheduleQuietCheck(tab.id)
    }

    /// The equalizer stops once a tab has been quiet for a moment: one check, not a timer.
    private func scheduleQuietCheck(_ tab: TabID) {
        guard quietChecks[tab] == nil, let at = activity[tab]?.quietAt() else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.quietChecks[tab] = nil
                if self.activity[tab]?.isBusy(at: Self.now) == true {
                    self.scheduleQuietCheck(tab)
                } else {
                    self.refreshTabs()
                }
            }
        }
        quietChecks[tab] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(at - Self.now, 0.05), execute: work)
    }

    private func paneRang(_ id: PaneID) {
        guard let tab = model.tab(containing: id), tab.id != model.activeTabID else { return }
        activity[tab.id]?.bell()
        refreshTabs()
    }

    /// A clean exit closes the pane; any other stays on screen saying why (the pane's
    /// banner), and marks its tab.
    private func paneEnded(_ id: PaneID, _ end: ShellEnd) {
        guard let tab = model.tab(containing: id) else { return }
        if !end.isFailure { return closeNow(id) }
        activity[tab.id]?.failure = end
        refreshTabs()
        if tab.isArmed { refreshStatus() }
    }

    // MARK: - Closing

    /// ⌘W: the active pane, then its tab, then the window.
    @objc func closePane(_ sender: Any?) {
        guard let pane = model.activePane else { return }
        confirmClose(of: [pane], in: "pane") { [weak self] in self?.closeNow(pane) }
    }

    /// ⌥⌘W.
    @objc func closeTab(_ sender: Any?) {
        if let tab = model.activeTabID { requestClose(tab: tab) }
    }

    /// ⇧⌘W: as the red button.
    @objc func closeWindow(_ sender: Any?) {
        window?.performClose(sender)
    }

    private func requestClose(tab id: TabID) {
        guard let tab = model.tabs.first(where: { $0.id == id }) else { return }
        confirmClose(of: tab.panes, in: "tab") { [weak self] in
            guard let self else { return }
            for pane in tab.panes { self.closeNow(pane) }
        }
    }

    /// Closes at once: the pane goes, then its tab, then the window, as they empty.
    private func closeNow(_ id: PaneID) {
        guard let tab = model.tab(containing: id), let closed = model.closePane(id) else { return }
        panes.removeValue(forKey: id)?.shutDown()
        switch closed {
        case .pane:
            if let area = areas[tab.id], let updated = model.tabs.first(where: { $0.id == tab.id }) {
                area.remove(id)
                area.tree = updated.tree
                area.zoomedPane = updated.zoomedPane
            }
            if tab.id == model.activeTabID, let next = model.activePane, let surface = panes[next]?.surface {
                window?.makeFirstResponder(surface)
            }
            refreshCards()
            refreshTabs()
            refreshStatus()
        case .tab:
            areas.removeValue(forKey: tab.id)?.removeFromSuperview()
            activity[tab.id] = nil
            quietChecks.removeValue(forKey: tab.id)?.cancel()
            if let active = model.activeTabID { show(active) }
        case .window:
            areas.removeValue(forKey: tab.id)?.removeFromSuperview()
            closeConfirmed = true
            window?.close()
        }
    }

    /// Asks "Goodbye & Good Riddance?" when closing would end programs other than shells at
    /// their prompts (`confirm-close`), naming them; else does `close` at once.
    private func confirmClose(of ids: [PaneID], in place: String, then close: @escaping @MainActor () -> Void) {
        let candidates = ids.compactMap { panes[$0] }.filter { $0.isRunning }
        guard config.confirmClose, !candidates.isEmpty else { return close() }
        guard !confirming else { return }
        confirming = true
        Task {
            defer { confirming = false }
            var running: [String] = []
            for pane in candidates {
                if let program = await pane.runningProgram() { running.append(program) }
            }
            guard !running.isEmpty else { return close() }
            let alert = NSAlert()
            alert.messageText = "Goodbye & Good Riddance?"
            alert.informativeText = Self.closeQuestion(running, place: place)
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            if await present(alert) == .alertFirstButtonReturn { close() }
        }
    }

    /// "vim is still running in this tab. Close it anyway?"
    static func closeQuestion(_ running: [String], place: String) -> String {
        if running.count == 1 { return "\(running[0]) is still running in this \(place). Close it anyway?" }
        let names = ListFormatter.localizedString(byJoining: running)
        return "\(names) are still running in this \(place). Close them anyway?"
    }

    /// A sheet on this window, one at a time.
    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse? {
        guard let window, window.attachedSheet == nil else { return nil }
        return await alert.beginSheetModal(for: window)
    }

    // MARK: - Actions on the active pane

    @objc func increaseFontSize(_ sender: Any?) { activePane?.changeFontSize(by: 1) }
    @objc func decreaseFontSize(_ sender: Any?) { activePane?.changeFontSize(by: -1) }
    @objc func resetFontSize(_ sender: Any?) { activePane?.resetFontSize() }
    @objc func clearToStart(_ sender: Any?) { activePane?.surface.clear(.toStart) }
    @objc func clearScrollback(_ sender: Any?) { activePane?.surface.clear(.scrollback) }

    // MARK: - Hear Me Calling

    /// ⇧⌘P or the title bar's button: opens Hear Me Calling over this window, or closes it.
    @objc func showHearMeCalling(_ sender: Any?) {
        if hearMeCalling != nil { return closeHearMeCalling() }
        guard let host else { return }
        // Found while the active pane has the keys, so the actions are the ones that would
        // work on it.
        let items =
            paletteActions() + host.places(from: self) + (host.connections?.paletteHosts() ?? [])
            + (host.connections?.paletteSnippets() ?? []) + (host.connections?.paletteTunnels() ?? [])
            + PaletteSearch.themes(current: config.themeID) + PaletteSearch.settingsPages
        let model = HearMeCallingModel(
            state: PaletteState(items: items, recent: host.recentPicks), palette: LegendsPalette(chrome))
        let overlay = HearMeCallingOverlay(model: model, chrome: chrome)
        model.onPreview = { [weak self] theme in self?.previewTheme(theme) }
        model.onChoose = { [weak self] item in self?.choose(item) }
        model.onAlternate = { [weak self] item in self?.chooseAlternate(item) }
        overlay.onDismiss = { [weak self] in self?.closeHearMeCalling() }
        overlay.frame = root.bounds
        root.addSubview(overlay)
        hearMeCalling = overlay
        overlay.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(overlay.field)
    }

    /// Closes Hear Me Calling: the window's own theme comes back unless one was chosen, and
    /// the active pane has the keys again.
    func closeHearMeCalling(restoringTheme: Bool = true) {
        guard let overlay = hearMeCalling else { return }
        hearMeCalling = nil
        overlay.detach()
        if restoringTheme { previewTheme(nil) }
        if let pane = activePane { window?.makeFirstResponder(pane.surface) }
    }

    private func choose(_ item: PaletteItem) {
        host?.picked(item.id)
        switch item.target {
        case .action(let id):
            closeHearMeCalling()
            let action = MainMenu.selector(id)
            NSApp.sendAction(action, to: target(for: action), from: nil)
        case .pane(_, let pane):
            closeHearMeCalling()
            host?.focus(pane: pane, from: self)
        case .theme(let id):
            // The preview becomes the setting, so there is nothing to put back.
            previewThemeID = nil
            closeHearMeCalling(restoringTheme: false)
            do {
                try host?.chooseTheme(id)
            } catch {
                apply(config)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Death Race could not save the theme"
                alert.informativeText = error.localizedDescription
                Task { _ = await present(alert) }
            }
        case .settings(let page):
            closeHearMeCalling()
            host?.showSettings(page: page)
        case .host(let ref):
            closeHearMeCalling()
            open(ref, beside: false)
        case .snippet(let id):
            closeHearMeCalling()
            useSnippet(id, run: false)
        case .tunnel(let id):
            closeHearMeCalling()
            let connections = host?.connections
            Task { await connections?.toggleTunnel(id) }
        }
    }

    /// ⌘↵ on a row that has a second action: a host opens beside the active pane, and a
    /// snippet runs.
    private func chooseAlternate(_ item: PaletteItem) {
        switch item.target {
        case .host(let ref):
            host?.picked(item.id)
            closeHearMeCalling()
            open(ref, beside: true)
        case .snippet(let id):
            host?.picked(item.id)
            closeHearMeCalling()
            useSnippet(id, run: true)
        default:
            return
        }
    }

    /// The menus' actions that would do something now, as the menus would show them.
    private func paletteActions() -> [PaletteItem] {
        PaletteSearch.actions.filter { item in
            guard case .action(let id) = item.target, id != .hearMeCalling else { return false }
            let action = MainMenu.selector(id)
            guard let target = target(for: action) else { return false }
            let menuItem = NSMenuItem(title: item.title, action: action, keyEquivalent: "")
            if let validator = target as? any NSMenuItemValidation { return validator.validateMenuItem(menuItem) }
            if let validator = target as? any NSUserInterfaceValidations {
                return validator.validateUserInterfaceItem(menuItem)
            }
            return true
        }
    }

    /// Who takes `action` in this window, as a menu would find it: the responder chain from
    /// the window's first responder, the window's delegate, then the app and its delegate.
    private func target(for action: Selector) -> AnyObject? {
        var responder: NSResponder? = window?.firstResponder
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        if let delegate = window?.delegate as? NSObject, delegate.responds(to: action) { return delegate }
        if NSApp.responds(to: action) { return NSApp }
        if let delegate = NSApp.delegate as? NSObject, delegate.responds(to: action) { return delegate }
        return nil
    }

    private func previewTheme(_ id: String?) {
        guard id != previewThemeID else { return }
        previewThemeID = id
        apply(config)
    }

    /// This window's panes for Hear Me Calling: each tab's label, where it is ("Tab 2,
    /// pane 3"), and in the window in use a one-pane tab's ⌘ key.
    func places(isCurrent: Bool) -> [PaletteItem] {
        let count = model.tabs.count
        return model.tabs.enumerated().flatMap { index, tab in
            tab.panes.enumerated().compactMap { number, id -> PaletteItem? in
                guard let pane = panes[id] else { return nil }
                let title = TabLabel.text(
                    title: pane.title, program: pane.programName ?? pane.shellName, directory: pane.directory,
                    home: Self.home)
                var place = "Tab \(index + 1)"
                if tab.panes.count > 1 { place += ", pane \(number + 1)" }
                if !isCurrent { place += " in another window" }
                let shortcut =
                    isCurrent && tab.panes.count == 1 ? PaletteSearch.tabShortcut(index: index, count: count) : nil
                return PaletteSearch.pane(
                    id, in: tab.id, title: title,
                    directory: pane.directory.map { abbreviatingHome($0, home: Self.home) },
                    place: place, shortcut: shortcut)
            }
        }
    }

    /// Hear Me Calling's pick: the pane's tab is shown, zoomed out if another pane filled
    /// it, and the pane takes the keys.
    func focus(pane id: PaneID) {
        guard let tab = model.tab(containing: id) else { return }
        if tab.id != model.activeTabID { select(tab.id) }
        if let zoomed = tab.zoomedPane, zoomed != id { model.toggleZoom() }
        model.activate(id)
        focusActivePane()
    }

    // MARK: - Splits

    @objc func splitRight(_ sender: Any?) { split(.sideBySide) }
    @objc func splitDown(_ sender: Any?) { split(.stacked) }

    /// ⌘D and ⇧⌘D: the active pane shares its place with a new one, which starts where it
    /// is and takes the keys.
    /// A split from a pane on a host opens on the same host, through the same master.
    private func split(_ axis: SplitAxis) {
        guard let tabID = model.activeTabID else { return }
        Task {
            let directory = await activePane?.currentDirectory()
            let launch = activePane?.launch.forSplit ?? .shell
            guard model.activeTabID == tabID, areas[tabID] != nil else { return }
            add(makePane(directory: directory, launch: launch), splitting: axis)
        }
    }

    /// `pane` beside the active one, with the keys.
    private func add(_ pane: PaneController, splitting axis: SplitAxis) {
        guard let tabID = model.activeTabID, let area = areas[tabID] else { return }
        wire(pane)
        model.split(axis, newPane: pane.id)
        let card = PaneCardView(pane: pane.id, surface: pane.surface, chrome: chrome)
        wire(card)
        area.add(card)
        if pane.banner != nil { showBanner(of: pane.id) }
        focusActivePane()
    }

    /// A session on `host`: in a new tab, or beside the active pane.
    func open(_ host: HostRef, beside: Bool) {
        let pane = makePane(directory: nil, launch: .connection(host))
        if beside, model.activeTabID != nil {
            add(pane, splitting: .sideBySide)
        } else {
            install(TabModel(id: ids.tab(), pane: pane.id), panes: [pane], area: nil)
        }
    }

    @objc func togglePaneZoom(_ sender: Any?) {
        model.toggleZoom()
        focusActivePane()
    }

    @objc func equalizePanes(_ sender: Any?) {
        guard let tab = model.activeTabID, let area = areas[tab] else { return }
        model.equalize(in: area.paneRect, gap: Double(Chrome.paneGap))
        sync(tab)
    }

    @objc func selectNextPane(_ sender: Any?) { _ = stepPane(forward: true) }
    @objc func selectPreviousPane(_ sender: Any?) { _ = stepPane(forward: false) }
    @objc func selectPaneLeft(_ sender: Any?) { focusNeighbor(.left) }
    @objc func selectPaneRight(_ sender: Any?) { focusNeighbor(.right) }
    @objc func selectPaneAbove(_ sender: Any?) { focusNeighbor(.up) }
    @objc func selectPaneBelow(_ sender: Any?) { focusNeighbor(.down) }
    @objc func moveDividerLeft(_ sender: Any?) { moveDivider(.left) }
    @objc func moveDividerRight(_ sender: Any?) { moveDivider(.right) }
    @objc func moveDividerUp(_ sender: Any?) { moveDivider(.up) }
    @objc func moveDividerDown(_ sender: Any?) { moveDivider(.down) }

    /// ⌘] and ⌘[; false in a tab with one pane, so the key goes on.
    func stepPane(forward: Bool) -> Bool {
        guard model.activeTab?.isSplit == true else { return false }
        if forward { model.focusNextPane() } else { model.focusPreviousPane() }
        focusActivePane()
        return true
    }

    /// ⌥⌘1–⌥⌘9.
    func selectPane(number: Int) -> Bool {
        guard model.activeTab?.isSplit == true, model.focusPane(number: number) else { return false }
        focusActivePane()
        return true
    }

    private func focusNeighbor(_ direction: Direction) {
        guard let tab = model.activeTabID, let area = areas[tab],
            model.focusNeighbor(direction, in: area.paneRect, gap: Double(Chrome.paneGap))
        else { return NSSound.beep() }
        focusActivePane()
    }

    /// ⌘⌃ arrows move the nearest divider by two cells.
    private func moveDivider(_ direction: Direction) {
        guard let tab = model.activeTab, let area = areas[tab.id], let pane = activePane else { return }
        let cell = pane.surface.cellSize
        let step = Double(direction == .left || direction == .right ? cell.width : cell.height) * 2
        let tree = tab.tree.resizing(
            tab.activePane, toward: direction, by: step, in: area.paneRect, gap: Double(Chrome.paneGap),
            minimum: minimumPaneSize(pane, header: showsHeaders(tab)))
        model.setTree(tree, of: tab.id)
        sync(tab.id)
    }

    /// A divider dragged with the mouse.
    private func dragDivider(in tab: TabID, at path: [SplitTree.Branch], to position: Double) {
        guard let tabModel = model.tabs.first(where: { $0.id == tab }), let area = areas[tab],
            let pane = panes[tabModel.activePane]
        else { return }
        let tree = tabModel.tree.movingDivider(
            at: path, to: position, in: area.paneRect, gap: Double(Chrome.paneGap),
            minimum: minimumPaneSize(pane, header: showsHeaders(tabModel)))
        model.setTree(tree, of: tab)
        sync(tab)
    }

    /// The least a pane may shrink to: 10 columns by 3 rows, with its card (and header)
    /// around them.
    func minimumPaneSize(_ pane: PaneController, header: Bool) -> (width: Double, height: Double) {
        let size = pane.surface.size(columns: 10, rows: 3)
        let top = header ? Chrome.paneHeaderHeight : Chrome.cardInset
        return (Double(size.width + Chrome.cardInset * 2), Double(size.height + top + Chrome.cardInset))
    }

    /// Whether `tab`'s cards show their headers, as `pane-headers` says.
    func showsHeaders(_ tab: TabModel) -> Bool {
        switch config.paneHeaders {
        case .always: true
        case .never: false
        case .split: tab.isSplit
        }
    }

    /// The N of ⌥⌘N for the pane at `index` in reading order: 1 to 8, and 9 for the last.
    static func paneNumber(_ index: Int, of count: Int) -> Int? {
        if index == count - 1, count >= 9 { return 9 }
        return index < 8 ? index + 1 : nil
    }

    /// The model's tree and zoom, to the tab's view.
    private func sync(_ tab: TabID) {
        guard let tabModel = model.tabs.first(where: { $0.id == tab }), let area = areas[tab] else { return }
        area.tree = tabModel.tree
        area.zoomedPane = tabModel.zoomedPane
    }

    /// After focus moved between panes: the views follow the model, and the keys go to the
    /// active pane.
    private func focusActivePane() {
        guard let tab = model.activeTabID else { return }
        sync(tab)
        if let pane = activePane, window?.firstResponder !== pane.surface { window?.makeFirstResponder(pane.surface) }
        refreshCards()
        refreshTabs()
        refreshStatus()
    }

    #if DEBUG
        /// Debug › Log Frame Stats: the active pane's drawing and latency numbers, to the log
        /// (for `log stream`) and in a sheet.
        @objc func logFrameStats(_ sender: Any?) {
            guard let pane = activePane else { return }
            pane.logFrameStats()
            let alert = NSAlert()
            alert.messageText = "Frame Stats"
            alert.informativeText = pane.frameStatsSummary
            Task { _ = await present(alert) }
        }
    #endif

    // MARK: - Armed and Dangerous

    /// ⇧⌘I: typing in any of the active tab's panes goes to all of them, or stops doing so.
    @objc func toggleArmed(_ sender: Any?) {
        model.toggleArmed()
        armedChanged()
    }

    /// The banner's Stop.
    private func stopArmed(_ tab: TabID) {
        model.disarm(tab)
        armedChanged()
    }

    /// A header's "receiving input" or "left out": the pane is left out, or put back.
    private func toggleArmed(of pane: PaneID) {
        guard let tab = model.tab(containing: pane), tab.isArmed else { return }
        model.setArmed(pane, tab.unarmed.contains(pane))
        armedChanged()
    }

    private func armedChanged() {
        refreshCards()
        refreshTabs()
        refreshStatus()
    }

    /// Typing in an armed pane goes to the tab's other armed panes too, each encoding it for
    /// its own program.
    private func typed(_ input: TypedInput, in pane: PaneID) {
        guard let tab = model.tab(containing: pane) else { return }
        for target in tab.broadcastTargets(from: pane) { panes[target]?.surface.receive(input) }
    }

    /// The modes of the other panes a paste in `pane` goes to, so the paste question asks
    /// once for all of them.
    private func armedModes(besides pane: PaneID) -> [TerminalModes] {
        guard let tab = model.tab(containing: pane) else { return [] }
        return tab.broadcastTargets(from: pane).compactMap { panes[$0]?.surface.model?.mirror.modes }
    }

    /// What the pill and the banner call each armed pane: its host, else its program.
    private func armedNames(_ tab: TabModel) -> [String] {
        tab.armedPanes.compactMap { id in panes[id].map { $0.programName ?? $0.shellName } }
    }

    // MARK: - The WRLD sidebar

    /// The sidebar, while it shows in this window.
    private var sidebar: WRLDSidebarView?
    private var sidebarQuery = ""
    private var expandedGroups: Set<GroupID> = []
    /// Counted among what shows WRLD: the sidebar is out, in a window on screen.
    private var sidebarCounted = false

    /// ⌃⌘S, or the title bar's button: the WRLD sidebar in this window, or not; new windows
    /// open as this one was left.
    @objc func toggleSidebar(_ sender: Any?) {
        guard host?.connections != nil else { return }
        setSidebar(shown: sidebar == nil)
        host?.sidebarPreferred = sidebar != nil
    }

    private func setSidebar(shown: Bool) {
        if shown, sidebar == nil {
            let view = WRLDSidebarView(chrome: chrome)
            view.onRow = { [weak self] row, command in self?.sidebarRow(row, commandHeld: command) }
            view.menuForRow = { [weak self] row in self?.sidebarMenu(row) }
            view.onSearch = { [weak self] query in
                self?.sidebarQuery = query
                self?.refreshSidebar()
            }
            view.onAddHost = { NSApp.sendAction(#selector(AppDelegate.newHost(_:)), to: nil, from: nil) }
            sidebar = view
            root.sidebar = view
            root.leadingColumnWidth = WRLDSidebarView.width
            refreshSidebar()
        } else if !shown, sidebar != nil {
            sidebar = nil
            root.sidebar = nil
            root.leadingColumnWidth = 0
        }
        root.titleBar.sidebarButton.isOn = sidebar != nil
        root.titleBar.needsLayout = true
        updateSidebarViewer()
    }

    private func refreshSidebar() {
        guard let sidebar, let connections = host?.connections else { return }
        sidebar.model = connections.sidebar(query: sidebarQuery, expanded: expandedGroups)
    }

    private func updateSidebarViewer() {
        let showing = sidebar != nil && window?.occlusionState.contains(.visible) == true
        guard showing != sidebarCounted else { return }
        sidebarCounted = showing
        if showing {
            host?.connections?.shown(by: self)
        } else {
            host?.connections?.hidden(by: self)
        }
    }

    /// A click on a row: a host opens in a new tab (⌘: beside the active pane), a group
    /// opens or closes, a snippet types in (⌘: runs), a tunnel turns on or off.
    private func sidebarRow(_ row: SidebarModel.Row, commandHeld: Bool) {
        switch row.kind {
        case .host(let ref):
            open(ref, beside: commandHeld)
        case .group(let id, _):
            if expandedGroups.contains(id) { expandedGroups.remove(id) } else { expandedGroups.insert(id) }
            refreshSidebar()
        case .snippet(let id):
            useSnippet(id, run: commandHeld)
        case .tunnel(let id):
            let connections = host?.connections
            Task { await connections?.toggleTunnel(id) }
        }
    }

    private func sidebarMenu(_ row: SidebarModel.Row) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping @MainActor () -> Void) {
            menu.addItem(ClosureMenuItem(title, action))
        }
        switch row.kind {
        case .host(let ref):
            add("Connect") { [weak self] in self?.open(ref, beside: false) }
            add("Connect Beside") { [weak self] in self?.open(ref, beside: true) }
            guard case .vault(let id) = ref, let connections = host?.connections, let saved = connections.host(id)
            else { return menu }
            menu.addItem(.separator())
            add("Edit") { [weak self] in self?.host?.showWRLD(at: .allHosts, selecting: id) }
            add(saved.isLegend ? "Unpin from Legends" : "Pin to Legends") {
                connections.setLegend(id, !saved.isLegend)
            }
            if let address = connections.address(of: ref) {
                add("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
                }
            }
            menu.addItem(.separator())
            add("Remove from WRLD…") { [weak self] in self?.confirmRemoval(saved) }
        case .group(_, let expanded):
            add(expanded ? "Collapse" : "Expand") { [weak self] in self?.sidebarRow(row, commandHeld: false) }
        case .snippet(let id):
            add("Insert") { [weak self] in self?.useSnippet(id, run: false) }
            add("Run") { [weak self] in self?.useSnippet(id, run: true) }
            menu.addItem(.separator())
            add("Edit in WRLD") { [weak self] in self?.host?.showWRLD(at: .wishingWell, selecting: nil) }
        case .tunnel:
            add(row.dot == .connected ? "Turn Off" : "Turn On") { [weak self] in
                self?.sidebarRow(row, commandHeld: false)
            }
        }
        return menu
    }

    /// "Remove prod-api from WRLD?", from the sidebar.
    private func confirmRemoval(_ host: WRLDHost) {
        guard let connections = self.host?.connections else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(host.name) from WRLD?"
        alert.informativeText =
            host.sshConfigAlias != nil
            ? "It stays in ~/.ssh/config." : "Its tunnels go too, and hosts that jump through it connect directly."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        Task {
            guard await present(alert) == .alertFirstButtonReturn else { return }
            await connections.remove(host.id)
        }
    }

    // MARK: - Wishing Well

    /// Where a snippet typed now goes: the active pane, and every armed pane with it.
    private var snippetTargets: [PaneID] {
        guard let active = model.activePane, let tab = model.activeTab else { return [] }
        return [active] + tab.broadcastTargets(from: active)
    }

    /// A Wishing Well snippet, into the active pane and every armed pane with it: at once,
    /// or once its fields are filled in.
    private func useSnippet(_ id: SnippetID, run: Bool) {
        guard let connections = host?.connections, let snippet = connections.snippet(id) else { return }
        let fill = SnippetFill(snippet.text)
        guard !fill.fields.isEmpty else {
            connections.used(id)
            return typeSnippet(fill.command, run: run)
        }
        let sheet = WishingWellSheet(title: snippet.name, parent: window)
        wishingWellSheet = sheet
        sheet.show(
            SnippetFillView(name: snippet.name, panes: snippetTargets.count, fill: fill) { [weak self, weak sheet] in
                sheet?.close()
                self?.wishingWellSheet = nil
                switch $0 {
                case .insert(let command)?:
                    connections.used(id)
                    self?.typeSnippet(command, run: false)
                case .run(let command)?:
                    connections.used(id)
                    self?.typeSnippet(command, run: true)
                case nil: break
                }
                self?.focusActivePane()
            })
    }

    /// `command` as if typed into the active pane and every armed pane with it, with Return
    /// after it to `run` it. Each program gets it as a paste, so a shell takes it whole, and
    /// no paste question asks: it was chosen and seen.
    func typeSnippet(_ command: String, run: Bool) {
        let inputs = TypedInput.snippet(command, run: run)
        for target in snippetTargets {
            guard let surface = panes[target]?.surface else { continue }
            for input in inputs { surface.receive(input) }
        }
    }

    /// Edit › Save Selection to Wishing Well…, or the context menu's: the selected text as a
    /// new snippet, named and looked over in a sheet first.
    @objc func saveSelectionToWishingWell(_ sender: Any?) {
        guard let pane = pane(of: sender), let connections = host?.connections else { return }
        Task {
            guard let selected = await pane.surface.selectedText(), !selected.allSatisfy(\.isWhitespace) else {
                return
            }
            let sheet = WishingWellSheet(title: "Save to Wishing Well", parent: window)
            wishingWellSheet = sheet
            sheet.show(
                SaveSnippetView(
                    name: WishingWell.suggestedName(for: selected),
                    text: WishingWell.snippetText(fromSelection: selected), save: { connections.save($0) },
                    done: { [weak self, weak sheet] in
                        sheet?.close()
                        self?.wishingWellSheet = nil
                        self?.focusActivePane()
                    }))
        }
    }

    /// The pane a context menu item was for, else the active one.
    private func pane(of sender: Any?) -> PaneController? {
        if let raw = (sender as? NSMenuItem)?.representedObject as? Int, let pane = panes[PaneID(raw)] {
            return pane
        }
        return activePane
    }

    /// What the app adds to `pane`'s context menu: Save Selection to Wishing Well.
    private func contextMenuItems(for pane: PaneID) -> [NSMenuItem] {
        guard host?.connections != nil else { return [] }
        let item = NSMenuItem(
            title: ActionCatalog.action(.saveSelectionToWishingWell).menuTitle,
            action: #selector(saveSelectionToWishingWell(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = pane.rawValue
        return [item]
    }

    // MARK: - Settings and theme

    /// Applies reloaded settings to every pane, and the theme to the chrome.
    func apply(_ newConfig: Config) {
        config = newConfig
        let shown = shownConfig
        for pane in panes.values { pane.apply(shown) }
        if shown.namedTheme != chrome.theme {
            chrome = Chrome(shown.namedTheme)
            applyChrome()
        }
        for area in areas.values { area.showsStars = showsStars }
        refreshCards()
        refreshStatus()
    }

    /// The settings, with the theme Hear Me Calling is previewing.
    private var shownConfig: Config {
        guard let previewThemeID else { return config }
        var shown = config
        shown.themeID = previewThemeID
        return shown
    }

    private func applyChrome() {
        hearMeCalling?.setChrome(chrome)
        window?.appearance = chrome.appearance
        window?.backgroundColor = chrome.colors.ground.nsColor
        root.titleBar.setChrome(chrome)
        root.statusBar.setChrome(chrome)
        sidebar?.setChrome(chrome)
        root.layer?.backgroundColor = chrome.colors.ground.cgColor
        for area in areas.values {
            area.setChrome(chrome)
            area.showsStars = showsStars
        }
        refreshTabs()
    }

    /// Stars on the ground and behind the text: `starfield = true`, and a theme with a night
    /// sky (not Righteous).
    private var showsStars: Bool { config.starfield && chrome.theme.hasStars }

    // MARK: - Keeping the chrome in step

    /// The NeonBorder and glow on each tab's active pane, the others dimmed, and the headers;
    /// in an armed tab, the banner and the armed panes' borders.
    private func refreshCards() {
        let isKey = window?.isKeyWindow ?? false
        for tab in model.tabs {
            guard let area = areas[tab.id] else { continue }
            let headers = showsHeaders(tab)
            let armed = Set(tab.armedPanes)
            area.showArmed(tab.isArmed ? BroadcastLabel.banner(names: armedNames(tab)) : nil, chrome: chrome)
            for (index, id) in tab.panes.enumerated() {
                guard let card = area.cards[id] else { continue }
                card.isActive = id == tab.activePane
                card.isWindowKey = isKey
                card.isArmed = armed.contains(id)
                // Typing reaches every armed pane, so none of them fades.
                card.isDimmed = tab.isSplit && tab.zoomedPane == nil && id != tab.activePane && !armed.contains(id)
                card.showsHeader = headers
                if headers, let pane = panes[id] {
                    var content = header(for: pane, number: Self.paneNumber(index, of: tab.panes.count))
                    if tab.isArmed { content.armed = armed.contains(id) ? .receiving : .leftOut }
                    card.header = content
                }
            }
        }
    }

    private func header(for pane: PaneController, number: Int?) -> PaneHeader {
        let directory = pane.directory
        if let directory, branchIsStale(directory) { readBranch(at: directory) }
        return PaneHeader(
            program: pane.programName ?? pane.shellName,
            directory: directory.map { abbreviatingHome($0, home: Self.home) },
            branch: directory.flatMap { branches[$0] }, number: number)
    }

    private func refreshTabs() {
        let now = Self.now
        root.titleBar.strip.update(
            model.tabs.map { tab in
                let pane = panes[tab.activePane]
                let state = activity[tab.id] ?? TabActivity()
                let title =
                    tab.isArmed
                    ? BroadcastLabel.pill(names: armedNames(tab))
                    : TabLabel.text(
                        title: pane?.title ?? "", program: pane?.programName ?? pane?.shellName,
                        directory: pane?.directory, home: Self.home, end: state.failure)
                return (
                    id: tab.id,
                    state: PillState(
                        title: title, isActive: tab.id == model.activeTabID, isBusy: state.isBusy(at: now),
                        rang: state.rang, failed: state.failure != nil, armed: tab.isArmed)
                )
            })
        window?.title =
            model.activeTab.flatMap { tab in
                panes[tab.activePane].map {
                    TabLabel.text(
                        title: $0.title, program: $0.programName ?? $0.shellName, directory: $0.directory,
                        home: Self.home)
                }
            } ?? "Death Race for Code"
    }

    /// Redraws the status bar for the active pane; with `rereadBranch`, the branch is read
    /// again off the main thread (after Return, a directory change, focus).
    func refreshStatus(rereadBranch: Bool = false) {
        guard let pane = activePane else { return }
        var facts = StatusLine.Facts(columns: pane.surface.grid.columns, rows: pane.surface.grid.rows)
        facts.directory = pane.directory
        facts.home = Self.home
        facts.program = pane.programName
        facts.secureInput = showsSecureInput
        facts.settingsProblems = settingsProblems
        facts.openTunnels = host?.connections?.openTunnelCount ?? 0
        if let tab = model.activeTab, tab.isArmed {
            facts.armedPanes = tab.armedPanes.count
            facts.endedArmedPanes = tab.armedPanes.filter { panes[$0]?.isDone ?? true }.count
        }
        // Where the link ⌘ is held over goes, in whichever pane it is.
        facts.hoveredLink = panes.values.lazy.compactMap { $0.surface.hoveredLink }.first.map {
            LinkPolicy.shown($0.uri)
        }
        if let directory = pane.directory {
            facts.branch = branches[directory]
            if rereadBranch || branchIsStale(directory) { readBranch(at: directory) }
        }
        root.statusBar.line = StatusLine(facts)
    }

    /// The branch shown for `directory` was read more than two seconds ago, or never.
    private func branchIsStale(_ directory: String) -> Bool {
        branchRead[directory].map { Date().timeIntervalSince($0) > 2 } ?? true
    }

    private func readBranch(at directory: String) {
        branchRead[directory] = Date()
        Task.detached(priority: .utility) { [weak self] in
            let branch = GitHead.branch(at: directory)
            await self?.setBranch(branch, for: directory)
        }
    }

    private func setBranch(_ branch: String?, for directory: String) {
        guard branches[directory] != branch else { return }
        branches[directory] = branch
        refreshCards()
        refreshStatus()
    }

    static var home: String? { ProcessInfo.processInfo.environment["HOME"] }
    static var now: Double { ProcessInfo.processInfo.systemUptime }

    // MARK: - NSWindowDelegate

    /// The red button and ⇧⌘W ask once for every pane in the window.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closeConfirmed else { return true }
        let all = model.tabs.flatMap(\.panes)
        let candidates = all.compactMap { panes[$0] }.filter { $0.isRunning }
        guard config.confirmClose, !candidates.isEmpty else { return true }
        confirmClose(of: all, in: "window") { [weak self] in
            self?.closeConfirmed = true
            self?.window?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if sidebarCounted {
            sidebarCounted = false
            host?.connections?.hidden(by: self)
        }
        window?.delegate = nil
        for check in quietChecks.values { check.cancel() }
        quietChecks = [:]
        for pane in panes.values { pane.shutDown() }
        panes = [:]
        host?.windowClosed(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        for pane in panes.values { pane.surface.focusChanged() }
        refreshCards()
        host?.inputStateChanged()
    }

    func windowDidResignKey(_ notification: Notification) {
        closeHearMeCalling()
        for pane in panes.values { pane.surface.focusChanged() }
        refreshCards()
        host?.inputStateChanged()
    }

    func windowDidResize(_ notification: Notification) {
        pitLaneWindow?.placeTrafficLights()
        root.titleBar.leadingInset = pitLaneWindow?.trafficLightsEnd ?? 84
        refreshStatus()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        root.titleBar.leadingInset = pitLaneWindow?.trafficLightsEnd ?? 16
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        pitLaneWindow?.placeTrafficLights()
        root.titleBar.leadingInset = pitLaneWindow?.trafficLightsEnd ?? 84
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        for pane in panes.values { pane.surface.visibilityChanged() }
        updateSidebarViewer()
    }

    /// Everything the window shows starts here, once AppKit has placed the buttons.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        pitLaneWindow?.placeTrafficLights()
        root.titleBar.leadingInset = pitLaneWindow?.trafficLightsEnd ?? 84
        if let pane = activePane { window?.makeFirstResponder(pane.surface) }
        refreshCards()
    }
}

extension PitLaneWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showNextTab(_:)), #selector(showPreviousTab(_:)), #selector(detachTab(_:)):
            return model.tabs.count > 1
        case #selector(togglePaneZoom(_:)):
            menuItem.state = model.activeTab?.zoomedPane != nil ? .on : .off
            return model.activeTab?.isSplit == true
        case #selector(equalizePanes(_:)), #selector(selectNextPane(_:)), #selector(selectPreviousPane(_:)),
            #selector(selectPaneLeft(_:)), #selector(selectPaneRight(_:)), #selector(selectPaneAbove(_:)),
            #selector(selectPaneBelow(_:)), #selector(moveDividerLeft(_:)), #selector(moveDividerRight(_:)),
            #selector(moveDividerUp(_:)), #selector(moveDividerDown(_:)):
            return model.activeTab?.isSplit == true && model.activeTab?.zoomedPane == nil
        case #selector(showHearMeCalling(_:)):
            menuItem.state = hearMeCalling != nil ? .on : .off
            return true
        case #selector(toggleArmed(_:)):
            menuItem.state = model.activeTab?.isArmed == true ? .on : .off
            return model.activeTab?.isSplit == true
        case #selector(toggleSidebar(_:)):
            menuItem.state = sidebar != nil ? .on : .off
            return host?.connections != nil
        case #selector(saveSelectionToWishingWell(_:)):
            return host?.connections != nil && pane(of: menuItem)?.surface.hasSelection == true
        default:
            return true
        }
    }
}
