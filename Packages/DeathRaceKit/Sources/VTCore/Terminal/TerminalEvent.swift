/// Things a program asked for that the app handles: they leave the engine as events
/// instead of side effects, so the engine stays testable and the daemon can forward them.
public enum TerminalEvent: Equatable, Sendable {
    case bell
    case titleChanged(String)
    case iconNameChanged(String)
    /// OSC 7, as sent: usually `file://host/path`.
    case workingDirectoryChanged(String)
    /// OSC 9 (iTerm2/ConEmu style) or OSC 777;notify.
    case notification(title: String, body: String)
    /// OSC 9;4: progress for the tab bar.
    case progress(ProgressReport)
    /// OSC 52: decoded bytes for the pasteboard. Reading the clipboard is never answered.
    case clipboardWrite(selection: String, contents: [UInt8])
    /// OSC 133, with the id of the row the mark sits on.
    case promptMark(PromptMark, rowID: UInt64)
    /// A palette entry or dynamic color changed (OSC 4, 10, 11, 12 and their resets).
    case colorsChanged
    /// The program switched screens or the screen was resized: redraw everything.
    case screenReplaced
}

public enum ProgressReport: Equatable, Sendable {
    case cleared
    case normal(percent: Int)
    case error(percent: Int?)
    case indeterminate
    case paused(percent: Int?)
}
