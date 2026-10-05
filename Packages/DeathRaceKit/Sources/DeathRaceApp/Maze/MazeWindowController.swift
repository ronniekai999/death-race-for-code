import AppCore
import AppKit
import LegendsUI
import SFTPKit
import SwiftUI
import Vault

/// A Maze window: one host's files beside this Mac's. Made when the host's Maze is first
/// opened and released when closed, so a closed window costs nothing. Closing it ends the
/// ssh subsystem and lets the host's master idle out.
@MainActor
final class MazeWindowController: NSWindowController, NSWindowDelegate {
    let model: MazeModel
    private let host: HostRef
    private weak var wrld: (any HostConnecting)?
    /// After the window has closed.
    var onClose: (() -> Void)?

    init(host: HostRef, name: String, files: any RemoteFiles, wrld: any HostConnecting, chrome: Chrome) {
        self.host = host
        self.wrld = wrld
        model = MazeModel(hostName: name, files: files, palette: LegendsPalette(chrome))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Maze · \(name)"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let content = NSHostingView(rootView: MazeView(model: model))
        content.sizingOptions = [.minSize]
        window.contentView = content
        window.center()
        super.init(window: window)
        window.delegate = self
        // No frame autosave name, so a second host's Maze cascades off the first rather than
        // landing exactly on top of it.
        setChrome(chrome)
        model.confirmOverwrite = { [weak self] name in await self?.confirmOverwrite(name) ?? false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not made from a nib")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func setChrome(_ chrome: Chrome) {
        let palette = LegendsPalette(chrome)
        if model.palette != palette { model.palette = palette }
        window?.appearance = chrome.appearance
        window?.backgroundColor = chrome.colors.ground.nsColor
    }

    /// Ends the connection, whether the window closed or the app is quitting.
    func shutDown() async {
        await model.shutDown()
        wrld?.closeSFTP(host)
        wrld = nil
    }

    /// "notes.md is already there. Replace it?" — asked before a transfer overwrites.
    private func confirmOverwrite(_ name: String) async -> Bool {
        guard let window else { return false }
        guard window.attachedSheet == nil else {
            model.problem = "Answer the question on screen first."
            return false
        }
        let alert = NSAlert()
        alert.messageText = "\(name) is already there. Replace it?"
        alert.informativeText = "The file that's there now will be overwritten."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        let onClose = onClose
        self.onClose = nil
        // Tell the owner now, so reopening this host's Maze makes a fresh window rather than
        // finding this one; the task holds the controller until the connection has ended.
        Task { await shutDown() }
        onClose?()
    }
}
