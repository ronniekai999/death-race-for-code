import AppKit
import ConfigKit
import PTYKit
import RenderKit
import TerminalUI

/// One tab. Tabs are native window tabs: each is a window with its own controller, and
/// AppKit groups them by their tabbing identifier.
@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    static let tabbingIdentifier = "terminal"
    private static let fontSizes = 6.0...144.0

    let surface: TerminalSurfaceView
    private var config: Config
    /// The font size ⌘+ and ⌘− chose for this window; nil follows the settings.
    private var fontSizeOverride: Double?
    private let onClose: (TerminalWindowController) -> Void
    private let onNewTab: (TerminalWindowController) -> Void

    init(
        config: Config, onNewTab: @escaping (TerminalWindowController) -> Void,
        onClose: @escaping (TerminalWindowController) -> Void
    ) {
        self.config = config
        self.onNewTab = onNewTab
        self.onClose = onClose
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
        window.title = Self.placeholderTitle
        super.init(window: window)
        window.delegate = self
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalWindowController is created in code")
    }

    /// Until a shell runs in the tab, it is named after the shell that will.
    private static var placeholderTitle: String {
        let shell = ShellLaunch.userShell(environment: ShellLaunch.processEnvironment())
        return shell.split(separator: "/").last.map(String.init) ?? "Shell"
    }

    // MARK: - Settings

    /// Applies reloaded settings. Fonts, colors and padding change at once; the window size
    /// and the settings for new tabs wait for new windows and tabs.
    func apply(_ newConfig: Config) {
        let fontChanged = newConfig.fontFamily != config.fontFamily || newConfig.fontSize != config.fontSize
        config = newConfig
        if fontChanged { applyFonts() }
        applyAppearance()
    }

    private func applyAppearance() {
        surface.theme = config.theme
        surface.padding = (config.windowPaddingX, config.windowPaddingY)
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

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
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
