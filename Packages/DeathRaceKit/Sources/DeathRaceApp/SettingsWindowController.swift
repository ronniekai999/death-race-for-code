import AppCore
import AppKit
import ConfigKit
import LegendsUI
import SwiftUI
import TerminalUI

/// The Settings window, made when first opened and released when closed, so a closed
/// window costs nothing. Its SwiftUI content draws under a transparent title bar in the
/// theme's colors.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel
    /// After the window has closed.
    var onClose: (() -> Void)?

    static let autosaveName = "Settings"

    init(model: SettingsModel, chrome: Chrome) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior.insert(.fullScreenNone)
        let content = NSHostingView(rootView: SettingsView(model: model))
        // The window takes its smallest size from the view; it is free to grow.
        content.sizingOptions = [.minSize]
        window.contentView = content
        window.center()
        _ = window.setFrameUsingName(Self.autosaveName)
        _ = window.setFrameAutosaveName(Self.autosaveName)
        super.init(window: window)
        window.delegate = self
        setChrome(chrome)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not made from a nib")
    }

    /// Brings the window forward, at `page` when given.
    func show(page: SettingsCatalog.Page? = nil) {
        if let page { model.page = page }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The settings as the file now says, and the theme's colors.
    func update(config: Config, chrome: Chrome) {
        if model.config != config { model.config = config }
        setChrome(chrome)
    }

    private func setChrome(_ chrome: Chrome) {
        let palette = LegendsPalette(chrome)
        if model.palette != palette { model.palette = palette }
        window?.appearance = chrome.appearance
        window?.backgroundColor = chrome.colors.ground.nsColor
    }

    func windowWillClose(_ notification: Notification) {
        model.stopSampling()
        onClose?()
    }
}
