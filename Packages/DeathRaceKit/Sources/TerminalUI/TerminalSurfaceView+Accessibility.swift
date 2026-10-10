import AppKit
import ScreenProtocol
import SurfaceCore

extension TerminalSurfaceView {
    var accessibleText: AccessibleTerminalText? { model.map { AccessibleTerminalText(mirror: $0.mirror) } }

    override public func isAccessibilityElement() -> Bool { true }
    override public func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override public func accessibilityLabel() -> String? { "Terminal output" }
    override public func accessibilityValue() -> Any? { accessibleText?.text ?? "" }
    override public func accessibilityNumberOfCharacters() -> Int { accessibleText?.points.count ?? 0 }
    override public func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: accessibilityNumberOfCharacters())
    }
    override public func accessibilitySelectedTextRange() -> NSRange {
        accessibleText?.range(for: selectionRange) ?? NSRange(location: 0, length: 0)
    }
    override public func accessibilitySelectedText() -> String? {
        accessibleText?.substring(accessibilitySelectedTextRange())
    }
    override public func accessibilityString(for range: NSRange) -> String? { accessibleText?.substring(range) }
    override public func accessibilityLine(for index: Int) -> Int { accessibleText?.line(at: index) ?? 0 }
    override public func accessibilityRange(forLine line: Int) -> NSRange {
        guard let text = accessibleText, text.lineRanges.indices.contains(line) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return text.lineRanges[line]
    }
    override public func accessibilityInsertionPointLineNumber() -> Int {
        guard let mirror = model?.mirror else { return 0 }
        return min(max(0, mirror.cursor.y + mirror.viewportOffset), max(0, mirror.rows - 1))
    }
    override public func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let text = accessibleText, range.location >= 0, range.length > 0,
            range.location < text.points.count, range.length <= text.points.count - range.location,
            let mirror = model?.mirror, let window
        else { return .zero }
        let first = text.points[range.location]
        let last = text.points[range.location + range.length - 1]
        let geometry = CellGeometry(cell: cell, layout: grid)
        let row = Int(first.line - mirror.viewportTopLine)
        let endRow = Int(last.line - mirror.viewportTopLine)
        let a = geometry.rect(column: first.column, row: row)
        let b = geometry.rect(column: last.column, row: endRow)
        let rect = NSRect(x: a.x, y: a.y, width: a.width, height: a.height)
            .union(NSRect(x: b.x, y: b.y, width: b.width, height: b.height))
        return window.convertToScreen(convert(rect, to: nil))
    }

    /// Coalesce only active updates. There is no idle poll or automatic read-out of output.
    func accessibilityOutputChanged() {
        guard NSWorkspace.shared.isVoiceOverEnabled, isFocused, accessibilityTask == nil else { return }
        accessibilityTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self else { return }
            self.accessibilityTask = nil
            NSAccessibility.post(element: self, notification: .valueChanged)
            NSAccessibility.post(element: self, notification: .selectedTextChanged)
        }
    }
}
