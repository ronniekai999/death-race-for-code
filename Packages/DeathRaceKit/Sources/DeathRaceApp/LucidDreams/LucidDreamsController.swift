import AppCore
import AppKit
import ConfigKit
import QuartzCore
import TerminalUI

/// Lucid Dreams: one persistent terminal in a panel that springs from the notch. The panel is
/// non-activating, so summoning it doesn't switch away from whatever app is in front; the one
/// `PaneController` is made on first show and kept across hide/show, so the shell lives on (the
/// surface stops drawing while hidden but the session never closes — only `shutDown` ends it).
@MainActor
final class LucidDreamsController: NSObject, NSWindowDelegate {
    private let config: @MainActor () -> Config
    private let makeSession: SessionMaker
    private let ids: IDSource
    /// Where the shell starts, when known (the front window's directory); nil is home.
    private let directory: @MainActor () -> String?

    private var panel: LucidDreamsPanel?
    private(set) var pane: PaneController?
    private var card: PaneCardView?
    private var keyMonitor: Any?
    private var state = LucidDreamsState()

    /// A quick-terminal grid: wide enough for a command, short enough to feel like a drop-in.
    private let columns = 90
    private let rows = 20

    init(
        config: @escaping @MainActor () -> Config, makeSession: @escaping SessionMaker, ids: IDSource,
        directory: @escaping @MainActor () -> String? = { nil }
    ) {
        self.config = config
        self.makeSession = makeSession
        self.ids = ids
        self.directory = directory
    }

    var isOnScreen: Bool { state.isOnScreen }

    /// ⌥Space, the menu item or the menu-bar icon.
    func toggle() {
        switch state.toggle() {
        case .show: present()
        case .hide: dismiss()
        }
    }

    /// Esc or a click away.
    func hideIfShowing() {
        if state.hide() == .hide { dismiss() }
    }

    /// Live-reload: font, theme and the rest reach the one pane and its card.
    func apply(_ config: Config) {
        pane?.apply(config)
        card?.setChrome(Chrome(config.namedTheme))
    }

    /// At quit: the one place the session is actually closed.
    func shutDown() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        pane?.shutDown()
        pane = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Showing and hiding

    private func present() {
        let panel = ensurePanel()
        let resting = restingFrame(size: panel.frame.size)
        // Spring down from the notch: start a little higher and clear, settle into place.
        let start = resting.offsetBy(dx: 0, dy: 20)
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        if let pane { panel.makeFirstResponder(pane.surface) }
        installKeyMonitor()
        LucidDreamsHandshake.post(open: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(resting, display: true)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            self?.state.didFinishShowing()
        }
    }

    private func dismiss() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        LucidDreamsHandshake.post(open: false)
        guard let panel else {
            state.didFinishHiding()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: 20), display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            panel.orderOut(nil)
            panel.alphaValue = 1
            self?.state.didFinishHiding()
        }
    }

    // MARK: - Building the panel

    private func ensurePanel() -> LucidDreamsPanel {
        if let panel { return panel }
        let chrome = Chrome(config().namedTheme)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pane = PaneController(
            id: ids.pane(), config: config(), directory: directory(), scale: scale, makeSession: makeSession,
            launch: .shell, connections: nil)
        let card = PaneCardView(pane: pane.id, surface: pane.surface, chrome: chrome)
        card.isActive = true
        card.isWindowKey = true

        let surfaceSize = pane.surface.size(columns: columns, rows: rows)
        let cardSize = NSSize(
            width: surfaceSize.width + Chrome.cardInset * 2, height: surfaceSize.height + Chrome.cardInset * 2)
        let panelSize = NSSize(
            width: cardSize.width + Chrome.paneMargin * 2, height: cardSize.height + Chrome.paneMargin * 2)

        let panel = LucidDreamsPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // the card draws the neon glow itself
        panel.animationBehavior = .none
        panel.delegate = self
        panel.appearance = chrome.appearance

        let content = NSView(frame: NSRect(origin: .zero, size: panelSize))
        content.autoresizingMask = [.width, .height]
        card.frame = content.bounds.insetBy(dx: Chrome.paneMargin, dy: Chrome.paneMargin)
        card.autoresizingMask = [.width, .height]
        content.addSubview(card)
        panel.contentView = content

        self.panel = panel
        self.pane = pane
        self.card = card
        return panel
    }

    /// Centre under the notch on the screen holding the pointer (else the main screen), hung
    /// just below the menu bar; top-centre on a screen without a notch.
    private func restingFrame(size: NSSize) -> NSRect {
        guard let screen = screenUnderPointer() else {
            // No display (a headless edge): centre on nothing, something sane.
            return NSRect(x: 100, y: 100, width: size.width, height: size.height)
        }
        let visible = screen.visibleFrame
        let rect = NotchPlacement.frame(
            inVisible: LayoutRect(
                x: visible.minX, y: visible.minY, width: visible.width, height: visible.height),
            notchCenterX: notchCenterX(of: screen), width: size.width, height: size.height, topInset: 6)
        return NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    private func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func notchCenterX(of screen: NSScreen) -> Double? {
        guard screen.safeAreaInsets.top > 0 else { return nil }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return Double(left.maxX + (right.minX - left.maxX) / 2)
        }
        return Double(screen.frame.midX)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            // Plain Esc hides the panel. (A quick scratch terminal; a program needing Esc wants
            // the full Pit Lane window. Noted in NAMING/MANUAL-TESTS.)
            let plain = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            if event.keyCode == 53, plain {
                self.hideIfShowing()
                return nil
            }
            return event
        }
    }

    // MARK: - NSWindowDelegate

    /// Clicking another app or window hides the drop-in panel.
    func windowDidResignKey(_ notification: Notification) {
        hideIfShowing()
    }
}

/// A borderless, non-activating panel must opt in to becoming key so the terminal can take
/// keystrokes without the summon switching apps.
final class LucidDreamsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
