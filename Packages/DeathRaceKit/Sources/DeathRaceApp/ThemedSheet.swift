import AppKit
import LegendsUI
import SwiftUI

/// A sheet in the theme's colors on the window in front, or a panel of its own when that
/// window has one already: New Host, a snippet's fields, a selection being saved, the host to
/// open in Maze.
@MainActor
final class ThemedSheet {
    let panel: NSPanel
    private weak var parent: NSWindow?
    private var chrome: Chrome

    init(title: String, parent: NSWindow?, chrome: Chrome) {
        self.parent = parent
        self.chrome = chrome
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320), styleMask: [.titled], backing: .buffered,
            defer: false)
        panel.title = title
        panel.appearance = chrome.appearance
        panel.backgroundColor = chrome.colors.ground.nsColor
    }

    func show(_ view: some View) {
        // The panel fits the view, which has a height of its own as long as nothing in it
        // scrolls, and follows it as rows come and go: the key file's, a problem.
        let content = NSHostingView(rootView: view.environment(\.legends, LegendsPalette(chrome)))
        content.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        if let parent, parent.attachedSheet == nil {
            parent.beginSheet(panel)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// A theme chosen while the sheet is up, as the welcome's swatches choose one: the panel
    /// follows. The view follows through its own model, since its palette was set at `show`.
    func setChrome(_ chrome: Chrome) {
        self.chrome = chrome
        panel.appearance = chrome.appearance
        panel.backgroundColor = chrome.colors.ground.nsColor
    }

    /// The sheet, and the window it is on, to the front: asked for again, it may have gone
    /// behind another window.
    func bringForward() {
        (panel.sheetParent ?? panel).makeKeyAndOrderFront(nil)
    }

    func close() {
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        } else {
            panel.orderOut(nil)
        }
    }
}
