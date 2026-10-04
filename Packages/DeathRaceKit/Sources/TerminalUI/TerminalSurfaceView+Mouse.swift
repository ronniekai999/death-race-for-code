import AppKit
import SurfaceCore
import VTCore

/// The mouse and the scroll wheel.
///
/// While a program tracks the mouse (vim, tmux, htop with mouse support), presses, releases,
/// drags and the wheel are reported to it, as its mode and encoding ask; holding Shift keeps
/// them for the terminal instead. Otherwise the wheel scrolls through history, or, on the
/// alternate screen (less, man), sends arrow keys so the program scrolls.
extension TerminalSurfaceView {
    /// Cells the mouse is over and pixels, in the grid, for a mouse event.
    private func position(of event: NSEvent) -> (column: Int, row: Int, pixelX: Int, pixelY: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let geometry = CellGeometry(cell: cell, layout: grid)
        let row = min(max(geometry.row(atY: Double(point.y)), 0), grid.rows - 1)
        let pixel = geometry.pixel(atX: Double(point.x), y: Double(point.y))
        return (geometry.column(atX: Double(point.x)), row, pixel.x, pixel.y)
    }

    private func mouseModifiers(_ event: NSEvent) -> KeyModifiers {
        var modifiers = KeyModifiers()
        let flags = event.modifierFlags
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.alt) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    /// Whether the program gets this event: it tracks the mouse, and Shift is not held.
    private func reportsMouse(_ event: NSEvent) -> Bool {
        guard let mirror = model?.mirror else { return false }
        return mirror.modes.mouseTracking != .none && !event.modifierFlags.contains(.shift)
    }

    /// Reports `kind` of `button` at the event's cell; motion only when the cell changed.
    private func report(_ kind: MouseEvent.Kind, _ button: MouseEvent.Button, _ event: NSEvent) {
        guard let mirror = model?.mirror else { return }
        let at = position(of: event)
        if kind == .motion {
            guard lastMouseCell?.column != at.column || lastMouseCell?.row != at.row else { return }
        }
        lastMouseCell = (at.column, at.row)
        let mouse = MouseEvent(
            kind, button: button, column: at.column, row: at.row, pixelX: at.pixelX, pixelY: at.pixelY,
            modifiers: mouseModifiers(event))
        let bytes = MouseEncoder.encode(mouse, modes: mirror.modes)
        if !bytes.isEmpty { session?.send(bytes) }
    }

    override public func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        if reportsMouse(event) { report(.press, .left, event) }
    }

    override public func mouseUp(with event: NSEvent) {
        if reportsMouse(event) { report(.release, .left, event) }
    }

    override public func mouseDragged(with event: NSEvent) {
        if reportsMouse(event) { report(.motion, .left, event) }
    }

    override public func rightMouseDown(with event: NSEvent) {
        if reportsMouse(event) { report(.press, .right, event) } else { super.rightMouseDown(with: event) }
    }

    override public func rightMouseUp(with event: NSEvent) {
        if reportsMouse(event) { report(.release, .right, event) } else { super.rightMouseUp(with: event) }
    }

    override public func rightMouseDragged(with event: NSEvent) {
        if reportsMouse(event) { report(.motion, .right, event) }
    }

    override public func otherMouseDown(with event: NSEvent) {
        if reportsMouse(event) { report(.press, Self.button(event), event) }
    }

    override public func otherMouseUp(with event: NSEvent) {
        if reportsMouse(event) { report(.release, Self.button(event), event) }
    }

    override public func otherMouseDragged(with event: NSEvent) {
        if reportsMouse(event) { report(.motion, Self.button(event), event) }
    }

    override public func mouseMoved(with event: NSEvent) {
        if reportsMouse(event) { report(.motion, .none, event) }
    }

    /// The middle button, and the back and forward buttons of five-button mice.
    private static func button(_ event: NSEvent) -> MouseEvent.Button {
        switch event.buttonNumber {
        case 3: .back
        case 4: .forward
        default: .middle
        }
    }

    override public func scrollWheel(with event: NSEvent) {
        guard let mirror = model?.mirror else { return }
        if event.phase == .began { scrollAccumulator.reset() }
        let lines = scrollAccumulator.lines(
            forDelta: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas,
            cellHeight: cell.pointHeight, multiplier: mouseScrollMultiplier)
        guard lines != 0 else { return }
        // A burst of reports or keys is capped, so a flick never floods the program.
        let count = min(abs(lines), 12)
        if reportsMouse(event) {
            let button: MouseEvent.Button = lines > 0 ? .wheelUp : .wheelDown
            for _ in 0..<count { report(.press, button, event) }
        } else if mirror.isAlternateScreen && (mirror.modes.alternateScroll || mouseScrollAlternate) {
            for _ in 0..<count { send(KeyEvent(lines > 0 ? .up : .down)) }
        } else {
            session?.scroll(by: lines)
        }
    }
}
