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

extension TerminalEvent {
    /// `events` with what a burst repeats folded away, in order: one bell, the latest title,
    /// icon name, directory, progress and clipboard write, one colors-changed and one
    /// screen-replaced, and the newest 16 notifications and 64 prompt marks. The app only
    /// needs the outcome of a burst, and a program that rings the bell in a loop must not grow
    /// memory while nobody takes the events.
    public static func coalesced(_ events: [TerminalEvent]) -> [TerminalEvent] {
        var counts: [Kind: Int] = [:]
        var kept: [TerminalEvent] = []
        for event in events.reversed() {
            let kind = event.kind
            let count = counts[kind, default: 0]
            guard count < kind.limit else { continue }
            counts[kind] = count + 1
            kept.append(event)
        }
        return kept.reversed()
    }

    private enum Kind: Hashable {
        case bell, title, iconName, directory, notification, progress, clipboard, promptMark, colors, screen

        var limit: Int {
            switch self {
            case .notification: 16
            case .promptMark: 64
            default: 1
            }
        }
    }

    private var kind: Kind {
        switch self {
        case .bell: .bell
        case .titleChanged: .title
        case .iconNameChanged: .iconName
        case .workingDirectoryChanged: .directory
        case .notification: .notification
        case .progress: .progress
        case .clipboardWrite: .clipboard
        case .promptMark: .promptMark
        case .colorsChanged: .colors
        case .screenReplaced: .screen
        }
    }
}

public enum ProgressReport: Equatable, Sendable {
    case cleared
    case normal(percent: Int)
    case error(percent: Int?)
    case indeterminate
    case paused(percent: Int?)
}
