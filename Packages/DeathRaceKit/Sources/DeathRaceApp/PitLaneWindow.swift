import AppKit

/// A Death Race window. The content runs under a transparent title bar so the tab pills
/// share the row with the traffic lights, which are moved down to the row's middle.
///
/// There is no toolbar: an empty one is the usual way to make a tall title bar, but it
/// takes the clicks of the views under it. Instead the standard buttons are placed again
/// after each layout pass, as Electron's `trafficLightPosition` does.
final class PitLaneWindow: NSWindow {
    /// Where the window's numbered and bracket shortcuts go.
    weak var shortcuts: (any WindowShortcuts)?

    static func make(contentRect: NSRect) -> PitLaneWindow {
        let window = PitLaneWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        // The controller owns the window; AppKit must not also release it when it closes.
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        return window
    }

    /// Shortcuts matched by key position rather than by character, so they work on layouts
    /// whose number row or brackets type other characters (AZERTY, German).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let shortcuts else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if let number = Self.numberKeys[event.keyCode] {
            // ⌘1–⌘9 select tabs and ⌥⌘1–⌥⌘9 panes, 9 being the last.
            if modifiers == .command, shortcuts.selectTab(number: number) { return true }
            if modifiers == [.command, .option], shortcuts.selectPane(number: number) { return true }
        }
        if event.keyCode == Self.leftBracket || event.keyCode == Self.rightBracket {
            let forward = event.keyCode == Self.rightBracket
            // ⇧⌘[ and ⇧⌘] step through tabs, as in Terminal; ⌘[ and ⌘] through panes.
            if modifiers == [.command, .shift] {
                shortcuts.stepTab(forward: forward)
                return true
            }
            if modifiers == .command, shortcuts.stepPane(forward: forward) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The number row's virtual key codes (kVK_ANSI_1 … kVK_ANSI_9).
    static let numberKeys: [UInt16: Int] = [
        0x12: 1, 0x13: 2, 0x14: 3, 0x15: 4, 0x17: 5, 0x16: 6, 0x1A: 7, 0x1C: 8, 0x19: 9,
    ]
    /// kVK_ANSI_LeftBracket and kVK_ANSI_RightBracket.
    static let leftBracket: UInt16 = 0x21
    static let rightBracket: UInt16 = 0x1E

    // MARK: - The traffic lights

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        placeTrafficLights()
    }

    /// Moves the close, minimize and zoom buttons down to the middle of the title row,
    /// keeping AppKit's horizontal places. The title bar's container grows to the row's
    /// height so the buttons stay inside it.
    func placeTrafficLights() {
        guard !styleMask.contains(.fullScreen),
            let close = standardWindowButton(.closeButton),
            let titlebar = close.superview,
            let container = titlebar.superview
        else { return }
        let height = Chrome.titleRowHeight
        let containerFrame = NSRect(x: 0, y: frame.height - height, width: frame.width, height: height)
        if container.frame != containerFrame { container.frame = containerFrame }
        if titlebar.frame != container.bounds { titlebar.frame = container.bounds }
        let buttons = [close, standardWindowButton(.miniaturizeButton), standardWindowButton(.zoomButton)]
        for case let button? in buttons {
            // The title bar view is not flipped: y counts from its bottom.
            let y = ((height - button.frame.height) / 2).rounded()
            if button.frame.origin.y != y { button.setFrameOrigin(NSPoint(x: button.frame.minX, y: y)) }
        }
    }

    /// Where the pills can start: past the zoom button, or at the margin in full screen.
    var trafficLightsEnd: CGFloat {
        guard !styleMask.contains(.fullScreen), let zoom = standardWindowButton(.zoomButton) else { return 16 }
        return zoom.frame.maxX + 14
    }
}

/// What the window's own shortcuts do.
@MainActor
protocol WindowShortcuts: AnyObject {
    /// False when there is no such tab, so the key goes on to the terminal.
    func selectTab(number: Int) -> Bool
    func selectPane(number: Int) -> Bool
    func stepTab(forward: Bool)
    func stepPane(forward: Bool) -> Bool
}

/// The window's content: the title row, the active tab's panes, the status bar, and room
/// for the WRLD sidebar on the left (Phase 4).
@MainActor
final class PitLaneRootView: NSView {
    let titleBar: TitleBarView
    let statusBar: StatusBarView
    /// Holds every tab's pane area; only the active tab's is shown.
    let tabArea = NSView()
    /// The sidebar's width; zero until WRLD arrives.
    var leadingColumnWidth: CGFloat = 0 {
        didSet { if leadingColumnWidth != oldValue { needsLayout = true } }
    }

    init(chrome: Chrome) {
        titleBar = TitleBarView(chrome: chrome)
        statusBar = StatusBarView(chrome: chrome)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        tabArea.wantsLayer = true
        addSubview(tabArea)
        addSubview(statusBar)
        addSubview(titleBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PitLaneRootView is created in code")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        let top = Chrome.titleRowHeight
        let bottom = Chrome.statusBarHeight
        set(titleBar, NSRect(x: 0, y: 0, width: width, height: top))
        set(statusBar, NSRect(x: 0, y: height - bottom, width: width, height: bottom))
        set(
            tabArea,
            NSRect(
                x: leadingColumnWidth, y: top, width: max(width - leadingColumnWidth, 0),
                height: max(height - top - bottom, 0)))
        for area in tabArea.subviews { set(area, tabArea.bounds) }
    }

    private func set(_ view: NSView, _ frame: NSRect) {
        if view.frame != frame { view.frame = frame }
    }

    /// The window size, in points, that gives the panes of a one-pane tab `surface` points,
    /// under a header if it has one.
    static func windowSize(forSurface surface: NSSize, header: Bool = false) -> NSSize {
        let around = (Chrome.paneMargin + Chrome.cardInset) * 2
        let top = header ? Chrome.paneHeaderHeight - Chrome.cardInset : 0
        return NSSize(
            width: surface.width + around,
            height: surface.height + around + top + Chrome.titleRowHeight + Chrome.statusBarHeight)
    }
}
