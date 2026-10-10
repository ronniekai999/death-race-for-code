/// One tab in a window. Numbers are unique for the app's life.
public struct TabID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    public var description: String { "tab \(rawValue)" }
}

/// A tab: its panes, the one that has the keys, and whether one fills the tab.
public struct TabModel: Equatable, Sendable {
    public let id: TabID
    public var tree: SplitTree
    /// The pane keys go to and the border marks. It changes when a pane becomes first
    /// responder or focus moves between panes, never when the window or the app loses
    /// focus, so the palette and sheets leave it where it is.
    public private(set) var activePane: PaneID
    /// ⌘⇧↩: this pane fills the tab and the others hide.
    public var zoomedPane: PaneID?
    /// Panes by when they were last active, most recent first.
    public private(set) var focusHistory: [PaneID]
    /// Armed and Dangerous (⇧⌘I): typing in an armed pane goes to every armed pane.
    public private(set) var isArmed = false
    /// Panes a header's toggle left out while armed. A pane split off later is in.
    public private(set) var unarmed: Set<PaneID> = []

    public init(id: TabID, pane: PaneID) {
        self.id = id
        tree = .pane(pane)
        activePane = pane
        focusHistory = [pane]
    }

    public init(id: TabID, tree: SplitTree, activePane: PaneID, zoomedPane: PaneID? = nil) {
        self.id = id
        self.tree = tree
        self.activePane = tree.contains(activePane) ? activePane : tree.panes[0]
        self.zoomedPane = zoomedPane.flatMap { tree.contains($0) ? $0 : nil }
        let focused = self.activePane
        focusHistory = [focused] + tree.panes.filter { $0 != focused }
    }

    public var panes: [PaneID] { tree.panes }
    public var isSplit: Bool { panes.count > 1 }

    /// The panes typing reaches while armed, in reading order; none when disarmed.
    public var armedPanes: [PaneID] { isArmed ? panes.filter { !unarmed.contains($0) } : [] }

    /// Where typing in `pane` goes besides itself: the other armed panes, if it's one.
    public func broadcastTargets(from pane: PaneID) -> [PaneID] {
        let armed = armedPanes
        guard armed.contains(pane) else { return [] }
        return armed.filter { $0 != pane }
    }

    mutating func arm() {
        guard isSplit else { return }
        isArmed = true
        unarmed = []
    }

    mutating func disarm() {
        isArmed = false
        unarmed = []
    }

    mutating func setArmed(_ pane: PaneID, _ armed: Bool) {
        guard isArmed, tree.contains(pane) else { return }
        if armed { unarmed.remove(pane) } else { unarmed.insert(pane) }
        disarmIfAlone()
    }

    /// One pane on its own has no one to type to.
    private mutating func disarmIfAlone() {
        if isArmed && armedPanes.count < 2 { disarm() }
    }

    /// The panes on screen: all of them, or the zoomed one.
    public var visiblePanes: [PaneID] { zoomedPane.map { [$0] } ?? panes }

    mutating func activate(_ pane: PaneID) {
        guard tree.contains(pane) else { return }
        activePane = pane
        focusHistory.removeAll { $0 == pane }
        focusHistory.insert(pane, at: 0)
    }

    /// Takes `pane` out; false when it was the last one.
    mutating func remove(_ pane: PaneID) -> Bool {
        guard let rest = tree.removing(pane) else { return false }
        tree = rest
        focusHistory.removeAll { $0 == pane }
        if zoomedPane == pane { zoomedPane = nil }
        if activePane == pane { activePane = focusHistory.first ?? rest.panes[0] }
        unarmed.remove(pane)
        disarmIfAlone()
        return true
    }
}

/// A window's tabs and panes, apart from the views: what ⌘T, ⌘W, ⌘D, ⌘1–9 and the arrows
/// do, as plain values the tests drive. New pane and tab numbers come from the caller,
/// which keeps them unique across windows.
public struct WindowModel: Equatable, Sendable {
    public private(set) var tabs: [TabModel] = []
    public private(set) var activeTabID: TabID?

    public init() {}

    public init(tab: TabModel) {
        tabs = [tab]
        activeTabID = tab.id
    }

    public var activeTab: TabModel? { tabs.first { $0.id == activeTabID } }
    public var activeIndex: Int? { tabs.firstIndex { $0.id == activeTabID } }
    public var activePane: PaneID? { activeTab?.activePane }

    public func tab(containing pane: PaneID) -> TabModel? {
        tabs.first { $0.tree.contains(pane) }
    }

    // MARK: - Tabs

    /// A tab with one pane, right after the active tab (as native tabs placed them), and
    /// active.
    public mutating func newTab(_ id: TabID, pane: PaneID) {
        insert(TabModel(id: id, pane: pane), at: activeIndex.map { $0 + 1 } ?? tabs.endIndex)
    }

    /// Adds a tab that came from another window, active.
    public mutating func insert(_ tab: TabModel, at index: Int? = nil) {
        tabs.insert(tab, at: min(max(index ?? tabs.endIndex, 0), tabs.endIndex))
        activeTabID = tab.id
    }

    public mutating func restore(_ tab: TabModel) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs[index] = tab
    }

    public mutating func selectTab(_ id: TabID) {
        if tabs.contains(where: { $0.id == id }) { activeTabID = id }
    }

    /// ⌘1–⌘8 select that tab and ⌘9 the last, as in browsers; false when there is no such
    /// tab.
    @discardableResult
    public mutating func selectTab(number: Int) -> Bool {
        guard (1...9).contains(number), !tabs.isEmpty else { return false }
        let index = number == 9 ? tabs.count - 1 : number - 1
        guard index < tabs.count else { return false }
        activeTabID = tabs[index].id
        return true
    }

    /// ⌘⇧] and ⌘⇧[, wrapping around.
    public mutating func selectNextTab() { step(by: 1) }
    public mutating func selectPreviousTab() { step(by: -1) }

    private mutating func step(by delta: Int) {
        guard let index = activeIndex, tabs.count > 1 else { return }
        activeTabID = tabs[(index + delta + tabs.count) % tabs.count].id
    }

    /// Drag to reorder: the tab at `from` moves to `to`.
    public mutating func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(to, 0), tabs.count))
    }

    /// Takes a tab out (closed, or moving to another window). The tab to its right becomes
    /// active, else the one to its left, as when closing a tab in Safari or Terminal.
    @discardableResult
    public mutating func removeTab(_ id: TabID) -> TabModel? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        return tab
    }

    // MARK: - Panes

    /// ⌘D and ⌘⇧D: the active pane splits, and the new pane takes the keys.
    public mutating func split(_ axis: SplitAxis, newPane: PaneID) {
        update(activeTabID) { tab in
            tab.zoomedPane = nil
            tab.tree = tab.tree.splitting(tab.activePane, axis, newPane: newPane)
            tab.activate(newPane)
        }
    }

    /// What closing a pane closed.
    public enum Closed: Equatable, Sendable {
        case pane
        /// The pane was its tab's last.
        case tab
        /// It was the window's last tab's last pane.
        case window
    }

    /// ⌘W: the pane goes; the pane focused before it takes over its tab.
    @discardableResult
    public mutating func closePane(_ pane: PaneID) -> Closed? {
        guard let index = tabs.firstIndex(where: { $0.tree.contains(pane) }) else { return nil }
        if tabs[index].remove(pane) { return .pane }
        removeTab(tabs[index].id)
        return tabs.isEmpty ? .window : .tab
    }

    /// A pane became first responder: its tab and it are active.
    public mutating func activate(_ pane: PaneID) {
        guard let index = tabs.firstIndex(where: { $0.tree.contains(pane) }) else { return }
        tabs[index].activate(pane)
        activeTabID = tabs[index].id
    }

    /// ⌘⌥ arrows; false when there is no pane that way.
    @discardableResult
    public mutating func focusNeighbor(_ direction: Direction, in rect: LayoutRect, gap: Double) -> Bool {
        guard let tab = activeTab, tab.zoomedPane == nil,
            let next = tab.tree.neighbor(
                of: tab.activePane, toward: direction, in: rect, gap: gap, recent: tab.focusHistory)
        else { return false }
        activate(next)
        return true
    }

    /// ⌥⌘1–9: the pane by its place in reading order, 9 being the last.
    @discardableResult
    public mutating func focusPane(number: Int) -> Bool {
        guard let tab = activeTab, (1...9).contains(number) else { return false }
        let panes = tab.panes
        let index = number == 9 ? panes.count - 1 : number - 1
        guard index < panes.count else { return false }
        update(tab.id) { tab in
            if tab.zoomedPane != nil { tab.zoomedPane = panes[index] }
            tab.activate(panes[index])
        }
        return true
    }

    /// ⌘] and ⌘[: the next and previous pane in reading order, wrapping around.
    public mutating func focusNextPane() { stepPane(by: 1) }
    public mutating func focusPreviousPane() { stepPane(by: -1) }

    private mutating func stepPane(by delta: Int) {
        guard let tab = activeTab, tab.isSplit, let index = tab.panes.firstIndex(of: tab.activePane) else { return }
        let next = tab.panes[(index + delta + tab.panes.count) % tab.panes.count]
        update(tab.id) { tab in
            if tab.zoomedPane != nil { tab.zoomedPane = next }
            tab.activate(next)
        }
    }

    /// ⇧⌘I: arms every pane in the active tab, or disarms it. A tab of one pane stays as it is.
    public mutating func toggleArmed() {
        update(activeTabID) { tab in
            if tab.isArmed { tab.disarm() } else { tab.arm() }
        }
    }

    /// The banner's Stop: `tab` is disarmed, whichever tab is active.
    public mutating func disarm(_ tab: TabID) {
        update(tab) { $0.disarm() }
    }

    /// A pane header's toggle: `pane` in or out while its tab is armed.
    public mutating func setArmed(_ pane: PaneID, _ armed: Bool) {
        guard let index = tabs.firstIndex(where: { $0.tree.contains(pane) }) else { return }
        tabs[index].setArmed(pane, armed)
    }

    /// ⌘⇧↩: the active pane fills the tab, or the tab shows all its panes again.
    public mutating func toggleZoom() {
        update(activeTabID) { tab in
            guard tab.isSplit else { return }
            tab.zoomedPane = tab.zoomedPane == nil ? tab.activePane : nil
        }
    }

    /// ⌘⌃=: the active tab's panes share its space evenly.
    public mutating func equalize(in rect: LayoutRect, gap: Double) {
        update(activeTabID) { tab in tab.tree = tab.tree.equalized(in: rect, gap: gap) }
    }

    /// Changes the active tab's tree: a divider dragged, or ⌘⌃ arrows.
    public mutating func setTree(_ tree: SplitTree, of tab: TabID) {
        update(tab) { model in
            guard Set(tree.panes) == Set(model.tree.panes) else { return }
            model.tree = tree
        }
    }

    private mutating func update(_ id: TabID?, _ change: (inout TabModel) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&tabs[index])
    }
}
