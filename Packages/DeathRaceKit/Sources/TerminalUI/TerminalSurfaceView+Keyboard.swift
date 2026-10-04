import AppKit
import SurfaceCore
import VTCore

extension KeyPress {
    /// The facts of a key event, read off `NSEvent` for `KeyRouting`.
    init(_ event: NSEvent) {
        let flags = event.modifierFlags
        self.init(
            keyCode: event.keyCode,
            flags: EventFlags(rawValue: flags.rawValue),
            characters: event.characters ?? "",
            plainCharacters: event.characters(byApplyingModifiers: flags.intersection([.shift, .capsLock])) ?? "",
            unmodifiedCharacters: event.characters(byApplyingModifiers: []) ?? "",
            isRepeat: event.isARepeat)
    }
}

/// Keys and input methods.
///
/// A key press goes one of two ways (`KeyRouting`): straight to the encoder for keys that
/// are commands to the terminal (control chords, Option as Meta, arrows and function keys),
/// or through `interpretKeyEvents`, where the input method composes text (accents, Japanese,
/// emoji) and hands it back through `insertText`. Text being composed is kept as marked text
/// until the input method commits it.
extension TerminalSurfaceView: @preconcurrency NSTextInputClient {
    override public func keyDown(with event: NSEvent) {
        guard model != nil else { return }
        // The cursor shows at once and blinks again from here.
        restartBlink = true
        updateCursor()
        let press = KeyPress(event)
        switch KeyRouting.route(press, optionAsMeta: optionAsMeta, composing: hasMarkedText()) {
        case .encode(let keyEvent):
            send(keyEvent)
        case .inputMethod:
            currentPress = press
            interpretKeyEvents([event])
            currentPress = nil
        }
    }

    /// A release, for programs that asked the Kitty protocol for them (the encoder drops it
    /// for the rest).
    override public func keyUp(with event: NSEvent) {
        guard model != nil else { return }
        if let keyEvent = KeyRouting.release(KeyPress(event), optionAsMeta: optionAsMeta, composing: hasMarkedText()) {
            send(keyEvent)
        }
    }

    /// A modifier key alone, for programs that asked the Kitty protocol for every key.
    override public func flagsChanged(with event: NSEvent) {
        guard model != nil, !hasMarkedText() else { return }
        // A flagsChanged event has no characters: asking for them raises an exception.
        let press = KeyPress(
            keyCode: event.keyCode, flags: EventFlags(rawValue: event.modifierFlags.rawValue), characters: "",
            plainCharacters: "", unmodifiedCharacters: "", isRepeat: false)
        if let keyEvent = KeyRouting.modifierKey(press, optionAsMeta: optionAsMeta) { send(keyEvent) }
    }

    /// Encodes a key for the program, in the modes it set, and sends it.
    func send(_ keyEvent: KeyEvent) {
        guard let mirror = model?.mirror else { return }
        let bytes = KeyEncoder.encode(keyEvent, modes: mirror.modes, kittyFlags: mirror.kittyFlags)
        guard !bytes.isEmpty else { return }
        // Typing clears the selection; a release or a modifier key alone does not.
        var isModifier = false
        if case .modifier = keyEvent.key { isModifier = true }
        if keyEvent.action != .release && !isModifier { clearSelection() }
        session?.send(bytes)
    }

    // MARK: - NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        clearMarkedText()
        guard !text.isEmpty else { return }
        send(KeyRouting.textEvent(text, press: currentPress))
    }

    /// AppKit's editing commands (insertNewline:, deleteBackward:…): the keys that mean
    /// something to a terminal were encoded before they got here, so there is nothing to do,
    /// and doing nothing keeps AppKit from beeping.
    override public func doCommand(by selector: Selector) {}

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attributed)
        } else {
            markedText = NSMutableAttributedString(string: (string as? String) ?? "")
        }
        markedSelection = selectedRange
        // Composing sends nothing until the text is committed, so it would not bring a
        // scrolled-back view down to where the text is going.
        if let mirror = model?.mirror, mirror.viewportOffset > 0 { session?.scrollToBottom() }
        redraw()
    }

    /// The input method is done with its composing text; what it commits comes through
    /// `insertText`.
    public func unmarkText() {
        clearMarkedText()
    }

    /// Drops the text being composed, here and in the input method (focus moved away).
    func discardComposition() {
        guard hasMarkedText() else { return }
        clearMarkedText()
        inputContext?.discardMarkedText()
    }

    private func clearMarkedText() {
        guard hasMarkedText() else { return }
        markedText = NSMutableAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
        redraw()
    }

    public func selectedRange() -> NSRange {
        hasMarkedText() ? markedSelection : NSRange(location: NSNotFound, length: 0)
    }

    public func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    public func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
        -> NSAttributedString?
    {
        nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    /// Where the input method puts its candidate window: under the caret of the text being
    /// composed, or the cursor's cell, in screen coordinates. An empty range gets a zero-width
    /// rectangle, which dictation shows its indicator at.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window, let mirror = model?.mirror else { return .zero }
        let column = preedit?.caretColumn ?? mirror.cursor.x
        let row = preedit?.row ?? mirror.cursor.y + mirror.viewportOffset
        let rect = CellGeometry(cell: cell, layout: grid).rect(column: column, row: row)
        let inView = NSRect(x: rect.x, y: rect.y, width: range.length == 0 ? 0 : rect.width, height: rect.height)
        return window.convertToScreen(convert(inView, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }
}
