import VTCore

/// What was typed into a pane, before it was encoded. Armed and Dangerous hands it to the
/// other armed panes, and each encodes it for its own program: ↑ is `ESC O A` to vim in
/// application cursor mode and `ESC [ A` at a zsh prompt, and a paste is bracketed only
/// where the program asked for that. The mouse and the scroll wheel are never typing.
public enum TypedInput: Equatable, Sendable {
    /// A key, encoded with the receiving pane's modes and Kitty flags.
    case key(KeyEvent)
    /// Text an input method composed, or the emoji picker inserted: sent as it is.
    case text(String)
    /// A paste.
    case paste(String)

    /// What a pane whose program set `modes` and `kittyFlags` sends, and whether it's a
    /// report (a key's release, a modifier on its own) rather than typing, which leaves the
    /// selection and a scrolled-back view where they are. Empty when the key means nothing
    /// to that program.
    public func bytes(modes: TerminalModes, kittyFlags: UInt8) -> (bytes: [UInt8], isReport: Bool) {
        switch self {
        case .key(let event):
            var isModifier = false
            if case .modifier = event.key { isModifier = true }
            let bytes = KeyEncoder.encode(event, modes: modes, kittyFlags: kittyFlags)
            return (bytes, event.action == .release || isModifier)
        case .text(let text):
            return (Array(text.utf8), false)
        case .paste(let text):
            return (InputEncoder.paste(text, modes: modes), false)
        }
    }

    /// A Wishing Well snippet typed in: as a paste, so a shell takes it whole rather than
    /// line by line, with Return after it as a key when it should run. You chose it and saw
    /// it, so no paste warning asks first.
    public static func snippet(_ text: String, run: Bool) -> [TypedInput] {
        run ? [.paste(text), .key(KeyEvent(.enter))] : [.paste(text)]
    }
}
