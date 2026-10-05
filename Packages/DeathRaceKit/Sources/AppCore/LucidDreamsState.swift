/// Whether Lucid Dreams — the notch quick-terminal — is on screen, and which way a toggle
/// should move it. The panel's behaviour that needs no AppKit lives here, so it is tested on
/// Linux; the controller animates the panel and reports back when each animation finishes.
public struct LucidDreamsState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case hidden
        /// Animating down from the notch.
        case showing
        case shown
        /// Animating back up into the notch.
        case hiding
    }

    public private(set) var phase: Phase

    public init(phase: Phase = .hidden) {
        self.phase = phase
    }

    /// The panel's window is ordered in — visible to the eye, including while it animates in
    /// or out. Only `.hidden` is truly off screen.
    public var isOnScreen: Bool { phase != .hidden }

    /// What the controller should do now.
    public enum Command: Equatable, Sendable { case show, hide }

    /// ⌥Space, the menu item or the menu-bar icon: show it when it's away, hide it when it's
    /// up. A press mid-animation reverses, so a quick double-tap ends where it started.
    public mutating func toggle() -> Command {
        switch phase {
        case .hidden, .hiding:
            phase = .showing
            return .show
        case .shown, .showing:
            phase = .hiding
            return .hide
        }
    }

    /// Esc, or a click outside: hide it, or do nothing if it's already going or gone.
    public mutating func hide() -> Command? {
        switch phase {
        case .shown, .showing:
            phase = .hiding
            return .hide
        case .hidden, .hiding:
            return nil
        }
    }

    /// The show animation finished (ignored if a toggle already sent it the other way).
    public mutating func didFinishShowing() {
        if phase == .showing { phase = .shown }
    }

    /// The hide animation finished.
    public mutating func didFinishHiding() {
        if phase == .hiding { phase = .hidden }
    }
}
