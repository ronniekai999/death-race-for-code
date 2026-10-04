import AppKit
import ScreenProtocol
import SurfaceCore

/// Selecting with the mouse, and copying.
///
/// Dragging selects characters, a double click words and a triple click lines (across soft
/// wraps); Option-drag selects a rectangle and Shift-click extends the selection. It is held
/// in line numbers, so it stays on its text as output arrives and the view scrolls, until
/// the screen is replaced (a resize, the alternate screen) or the user types.
extension TerminalSurfaceView {
    /// The selected range, if it still belongs to the screen the mirror shows.
    var selectionRange: TextRegion? {
        guard let selection, let mirror = model?.mirror, mirror.generation == selectionGeneration else { return nil }
        return selection.range
    }

    /// Starts a selection, or with Shift extends the one there is.
    func beginSelection(with event: NSEvent) {
        guard let mirror = model?.mirror, let point = selectionPoint(at: convert(event.locationInWindow, from: nil))
        else { return }
        let flags = event.modifierFlags
        if flags.contains(.shift), event.clickCount == 1, selectionRange != nil {
            extendSelection(to: point)
            return
        }
        let granularity: Selection.Granularity =
            switch event.clickCount {
            case 2: .word
            case 3...: .line
            default: .character
            }
        selection = Selection(
            at: point, granularity: granularity, rectangular: flags.contains(.option), columns: mirror.columns,
            line: { mirror.line($0) })
        selectionGeneration = mirror.generation
        redraw()
    }

    /// The pointer moved with the button down: the selection follows it, and past the top or
    /// bottom edge the view scrolls for as long as it stays out there.
    func dragSelection(with event: NSEvent) {
        guard selection != nil else { return }
        let location = convert(event.locationInWindow, from: nil)
        if let point = selectionPoint(at: location) { extendSelection(to: point) }
        let gridBottom = grid.top + Double(grid.rows) * cell.pointHeight
        autoscrollDirection = Double(location.y) < grid.top ? 1 : Double(location.y) > gridBottom ? -1 : 0
        if autoscrollDirection == 0 {
            stopAutoscroll()
        } else if autoscrollTimer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoscroll() }
            }
            RunLoop.main.add(timer, forMode: .common)
            autoscrollTimer = timer
        }
    }

    /// The button went up: the selection is made.
    func endSelection() {
        stopAutoscroll()
        if copyOnSelect, let range = selectionRange { copyText(in: range) }
    }

    /// Forgets the selection (typing, a new screen).
    func clearSelection() {
        guard selection != nil else { return }
        selection = nil
        stopAutoscroll()
        redraw()
    }

    private func extendSelection(to point: Selection.Point) {
        guard let mirror = model?.mirror else { return }
        selection?.extend(to: point, columns: mirror.columns, line: { mirror.line($0) })
        redraw()
    }

    private func autoscroll() {
        guard autoscrollDirection != 0, selection != nil, let window else { return stopAutoscroll() }
        session?.scroll(by: autoscrollDirection)
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if let point = selectionPoint(at: location) { extendSelection(to: point) }
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
        autoscrollDirection = 0
    }

    /// The line, cell and boundary at a point in the view; outside the grid, the nearest.
    private func selectionPoint(at location: NSPoint) -> Selection.Point? {
        guard let mirror = model?.mirror, mirror.columns > 0, !mirror.lines.isEmpty else { return nil }
        let geometry = CellGeometry(cell: cell, layout: grid)
        let row = min(max(geometry.row(atY: Double(location.y)), 0), mirror.lines.count - 1)
        let column = min(max(geometry.column(atX: Double(location.x)), 0), mirror.columns - 1)
        let boundary = min(max(geometry.boundary(atX: Double(location.x)), 0), mirror.columns)
        return Selection.Point(line: mirror.viewportTopLine + UInt64(row), column: column, boundary: boundary)
    }

    // MARK: - Copying

    /// Edit › Copy (⌘C).
    @objc func copy(_ sender: Any?) {
        guard let range = selectionRange else { return }
        copyText(in: range)
    }

    /// Edit › Select All (⌘A): the history and the screen.
    override public func selectAll(_ sender: Any?) {
        guard let mirror = model?.mirror, let all = mirror.allLines else { return }
        var selection = Selection(
            at: Selection.Point(line: all.start.line, column: 0, boundary: 0), granularity: .character,
            rectangular: false, columns: mirror.columns, line: { mirror.line($0) })
        selection.extend(
            to: Selection.Point(line: all.end.line, column: all.end.column, boundary: mirror.columns),
            columns: mirror.columns, line: { mirror.line($0) })
        self.selection = selection
        selectionGeneration = mirror.generation
        redraw()
    }

    /// The text of `range` onto the pasteboard: from the mirror when it is all in view,
    /// otherwise from the session, which has the history.
    private func copyText(in range: TextRegion) {
        guard let mirror = model?.mirror, let generation = mirror.generation else { return }
        if let text = mirror.text(in: range) { return Self.writeToPasteboard(text) }
        Task { [weak self] in
            guard let text = await self?.session?.text(in: range, generation: generation) else { return }
            Self.writeToPasteboard(text)
        }
    }

    private static func writeToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension TerminalSurfaceView: NSMenuItemValidation {
    /// Copy needs a selection and Paste needs text or files on the pasteboard.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): selectionRange != nil
        case #selector(paste(_:)): NSPasteboard.general.availableType(from: [.string]) != nil
        case #selector(selectAll(_:)): model?.mirror.allLines != nil
        default: true
        }
    }
}
