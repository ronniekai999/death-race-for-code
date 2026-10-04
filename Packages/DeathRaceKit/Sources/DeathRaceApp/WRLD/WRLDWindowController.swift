import AppCore
import AppKit
import LegendsUI
import SwiftUI
import Vault

/// The WRLD window (⌘O): made when first opened and released when closed, so a closed
/// window costs nothing. It draws again whenever WRLD or its tunnels change, and while it's
/// on screen WRLD checks how quickly the Legends answer.
@MainActor
final class WRLDWindowController: NSWindowController, NSWindowDelegate {
    let model: WRLDBoardModel
    private weak var wrld: WRLDService?
    /// After the window has closed.
    var onClose: (() -> Void)?
    /// Set once, on the main thread; read only by deinit, and removing an observer is safe
    /// from any thread.
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []
    private var isShowing = false

    static let autosaveName = "WRLD"

    init(wrld: WRLDService, host: any WRLDWindowHost, chrome: Chrome) {
        self.wrld = wrld
        model = WRLDBoardModel(palette: LegendsPalette(chrome))
        model.wrld = wrld
        model.host = host
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "WRLD"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let content = NSHostingView(rootView: WRLDBoardView(model: model))
        content.sizingOptions = [.minSize]
        window.contentView = content
        window.center()
        _ = window.setFrameUsingName(Self.autosaveName)
        _ = window.setFrameAutosaveName(Self.autosaveName)
        super.init(window: window)
        window.delegate = self
        setChrome(chrome)
        model.refresh()
        model.refreshFiles()
        for name in [Notification.Name.wrldChanged, .tunnelsChanged] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.model.refresh() }
                })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not made from a nib")
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Brings the window forward, at `place` when given.
    func show(_ place: WRLDBoard.Place? = nil) {
        if let place { model.place = place }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func setChrome(_ chrome: Chrome) {
        let palette = LegendsPalette(chrome)
        if model.palette != palette { model.palette = palette }
        window?.appearance = chrome.appearance
        window?.backgroundColor = chrome.colors.ground.nsColor
    }

    /// On screen or not: WRLD checks the Legends only while something shows them.
    private func setShowing(_ showing: Bool) {
        guard showing != isShowing else { return }
        isShowing = showing
        if showing {
            wrld?.shown(by: self)
        } else {
            wrld?.hidden(by: self)
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        setShowing(window?.occlusionState.contains(.visible) == true)
    }

    func windowWillClose(_ notification: Notification) {
        setShowing(false)
        onClose?()
    }
}
