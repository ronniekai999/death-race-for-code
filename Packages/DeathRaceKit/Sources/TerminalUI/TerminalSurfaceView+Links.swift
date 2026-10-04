import AppKit
import ScreenProtocol
import SurfaceCore

/// Links: a program's own (OSC 8) or a URL in the text.
///
/// With ⌘ held over one, its cells are underlined, the pointer becomes a hand and the
/// status bar says where it goes. A ⌘-click follows it, as the app's link policy says, and
/// never reaches the program. A right-click on one offers Open Link and Copy Link.
extension TerminalSurfaceView {
    /// The cell at a point in the view, if it is on the screen.
    private func cellPosition(at point: NSPoint) -> (column: Int, row: Int)? {
        guard let mirror = model?.mirror else { return nil }
        let geometry = CellGeometry(cell: cell, layout: grid)
        let column = geometry.column(atX: Double(point.x))
        let row = geometry.row(atY: Double(point.y))
        guard row >= 0, row < mirror.lines.count, column >= 0, column < mirror.columns else { return nil }
        return (column, row)
    }

    /// The link at a point in the view.
    func link(at point: NSPoint) -> LinkHit? {
        guard let mirror = model?.mirror, let position = cellPosition(at: point) else { return nil }
        return LinkFinder.link(atColumn: position.column, row: position.row, in: mirror)
    }

    /// Looks for a link under the pointer again: ⌘ went down or up, the pointer moved, or the
    /// screen changed under it. Only in the key window, with ⌘ held.
    func updateHoveredLink(commandHeld: Bool? = nil, redrawing: Bool = true) {
        let held = commandHeld ?? NSEvent.modifierFlags.contains(.command)
        var position: (column: Int, row: Int)?
        if held, let window, window.isKeyWindow {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(point) { position = cellPosition(at: point) }
        }
        guard let position, let mirror = model?.mirror else {
            hoverCell = nil
            setHoveredLink(nil, redrawing: redrawing)
            return
        }
        // Moving within a cell changes nothing; the screen changing under the pointer (a
        // frame's refresh, which does not redraw) does.
        if redrawing, hoverCell?.column == position.column, hoverCell?.row == position.row { return }
        hoverCell = position
        setHoveredLink(LinkFinder.link(atColumn: position.column, row: position.row, in: mirror), redrawing: redrawing)
    }

    private func setHoveredLink(_ link: LinkHit?, redrawing: Bool) {
        guard link != hoveredLink else { return }
        hoveredLink = link
        window?.invalidateCursorRects(for: self)
        (link == nil ? NSCursor.iBeam : NSCursor.pointingHand).set()
        onHoverLink?(link?.uri)
        if redrawing { redraw() }
    }

    /// The text cursor over the terminal, and a hand while ⌘ is held over a link.
    override public func resetCursorRects() {
        addCursorRect(visibleRect, cursor: hoveredLink == nil ? .iBeam : .pointingHand)
    }

    // MARK: - The context menu

    override public func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menuLink = link(at: convert(event.locationInWindow, from: nil))
        if menuLink != nil {
            let open = NSMenuItem(title: "Open Link", action: #selector(openMenuLink(_:)), keyEquivalent: "")
            open.target = self
            let copy = NSMenuItem(title: "Copy Link", action: #selector(copyMenuLink(_:)), keyEquivalent: "")
            copy.target = self
            menu.addItem(open)
            menu.addItem(copy)
            menu.addItem(.separator())
        }
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: ""))
        if let extra = contextMenuItems?(), !extra.isEmpty {
            menu.addItem(.separator())
            for item in extra { menu.addItem(item) }
        }
        return menu
    }

    @objc func openMenuLink(_ sender: Any?) {
        if let menuLink { onOpenLink?(menuLink) }
    }

    @objc func copyMenuLink(_ sender: Any?) {
        guard let uri = menuLink?.uri else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(uri, forType: .string)
    }
}
