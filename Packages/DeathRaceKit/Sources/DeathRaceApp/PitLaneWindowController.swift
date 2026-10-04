import AppCore
import AppKit
import ConfigKit
import Foundation
import SurfaceCore
import TerminalUI
import VTCore

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
        root.statusBar.onProblemsClick = { [weak self] in self?.onSettingsProblemsClick?() }
        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PitLaneWindowController is created in code")
    }

    private var pitLaneWindow: PitLaneWindow? { window as? PitLaneWindow }

    var activePane: PaneController? { model.activePane.flatMap { panes[$0] } }

    // MARK: - Building tabs and panes

    private func makePane(directory: String?) -> PaneController {
        PaneController(
            id: ids.pane(), config: config, directory: directory,
            scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, makeSession: makeSession)
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
        pane.presentAlert = { [weak self] alert in await self?.present(alert) }
        panes[id] = pane
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
        area.setChrome(chrome)
        let id = tab.id
        area.onDividerDrag = { [weak self] path, position in self?.dragDivider(in: id, at: path, to: position) }
        area.onDividerDoubleClick = { [weak self] in
            guard let self, self.model.activeTabID == id else { return }
            self.equalizePanes(nil)
        }
        areas[tab.id] = area
        root.tabArea.addSubview(area)
        root.needsLayout = true
        model.insert(tab, at: model.activeIndex.map { $0 + 1 })
        activity[tab.id] = TabActivity()
        show(tab.id)
    }

    /// Sizes a new window for `window-size` cells in its first pane.
    private func sizeWindow(toFit pane: PaneController) {
        guard let window else { return }
        let header = config.paneHeaders == .always
        let surface = pane.surface.size(columns: config.windowSize.columns, rows: config.windowSize.rows)
        window.setContentSize(PitLaneRootView.windowSize(forSurface: surface, header: header))
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

    /// A clean exit closes the pane; any other stays on screen saying why, and marks its tab.
    private func paneEnded(_ id: PaneID, _ end: ShellEnd) {
        guard let tab = model.tab(containing: id) else { return }
        if !end.isFailure { return closeNow(id) }
        activity[tab.id]?.failure = end
        areas[tab.id]?.cards[id]?.showEnd(end.sentence) { [weak self] in self?.restart(id) }
        refreshTabs()
    }

    private func restart(_ id: PaneID) {
        guard let pane = panes[id], let tab = model.tab(containing: id) else { return }
        areas[tab.id]?.cards[id]?.showEnd(nil, restart: nil)
        activity[tab.id]?.failure = nil
        pane.restart()
        window?.makeFirstResponder(pane.surface)
        refreshTabs()
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

    /// Hear Me Calling arrives in a later milestone.
    @objc func showHearMeCalling(_ sender: Any?) {}

    // MARK: - Splits

    @objc func splitRight(_ sender: Any?) { split(.sideBySide) }
    @objc func splitDown(_ sender: Any?) { split(.stacked) }

    /// ⌘D and ⇧⌘D: the active pane shares its place with a new one, which starts where it
    /// is and takes the keys.
    private func split(_ axis: SplitAxis) {
        guard let tabID = model.activeTabID else { return }
        Task {
            let directory = await activePane?.currentDirectory()
            guard model.activeTabID == tabID, let area = areas[tabID] else { return }
            let pane = makePane(directory: directory)
            wire(pane)
            model.split(axis, newPane: pane.id)
            area.add(PaneCardView(pane: pane.id, surface: pane.surface, chrome: chrome))
            focusActivePane()
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

    // MARK: - Settings and theme

    /// Applies reloaded settings to every pane, and the theme to the chrome.
    func apply(_ newConfig: Config) {
        config = newConfig
        for pane in panes.values { pane.apply(newConfig) }
        if newConfig.namedTheme != chrome.theme {
            chrome = Chrome(newConfig.namedTheme)
            applyChrome()
        }
        refreshCards()
        refreshStatus()
    }

    private func applyChrome() {
        window?.appearance = chrome.appearance
        window?.backgroundColor = chrome.colors.ground.nsColor
        root.titleBar.setChrome(chrome)
        root.statusBar.setChrome(chrome)
        root.layer?.backgroundColor = chrome.colors.ground.cgColor
        for area in areas.values { area.setChrome(chrome) }
        refreshTabs()
    }

    // MARK: - Keeping the chrome in step

    /// The NeonBorder and glow on each tab's active pane, the others dimmed, and the headers.
    private func refreshCards() {
        let isKey = window?.isKeyWindow ?? false
        for tab in model.tabs {
            guard let area = areas[tab.id] else { continue }
            let headers = showsHeaders(tab)
            for (index, id) in tab.panes.enumerated() {
                guard let card = area.cards[id] else { continue }
                card.isActive = id == tab.activePane
                card.isWindowKey = isKey
                card.isDimmed = tab.isSplit && tab.zoomedPane == nil && id != tab.activePane
                card.showsHeader = headers
                if headers, let pane = panes[id] {
                    card.header = header(for: pane, number: Self.paneNumber(index, of: tab.panes.count))
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
                let title = TabLabel.text(
                    title: pane?.title ?? "", program: pane?.programName ?? pane?.shellName,
                    directory: pane?.directory, home: Self.home, end: state.failure)
                return (
                    id: tab.id,
                    state: PillState(
                        title: title, isActive: tab.id == model.activeTabID, isBusy: state.isBusy(at: now),
                        rang: state.rang, failed: state.failure != nil)
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
            return false
        default:
            return true
        }
    }
}
