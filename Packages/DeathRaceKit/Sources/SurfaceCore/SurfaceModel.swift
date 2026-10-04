import ScreenProtocol
import VTCore

/// One terminal view's state apart from AppKit: the mirror of its session's screen, and what
/// changed since the view last drew.
///
/// The view calls `drain()` when the session says a delta is waiting (and before drawing);
/// the result says what to redraw and which events to act on.
public final class SurfaceModel {
    public let session: any SurfaceSession
    public private(set) var mirror = MirrorGrid()

    public init(session: any SurfaceSession) {
        self.session = session
    }

    /// What applying the waiting deltas changed.
    public struct Update: Sendable, Equatable {
        /// Viewport rows whose content or position changed.
        public var rows: Set<Int> = []
        /// The screen was replaced (first delta, resize, screen switch, reset): everything
        /// redraws, and selections from before mean nothing.
        public var replaced = false
        public var cursorChanged = false
        public var paletteChanged = false
        public var titleChanged = false
        /// The view scrolled through history (or back to the bottom).
        public var viewportMoved = false
        public var events: [TerminalEvent] = []

        public var isEmpty: Bool {
            rows.isEmpty && !replaced && !cursorChanged && !paletteChanged && !titleChanged && !viewportMoved
                && events.isEmpty
        }
    }

    /// Applies every waiting delta. A delta the mirror cannot apply (it builds on a state
    /// the mirror never had) asks the session for a snapshot, which arrives as a later delta.
    public func drain() -> Update {
        var update = Update()
        while let delta = session.takeDelta() {
            let before = mirror
            let changed: [Int]
            do {
                changed = try mirror.apply(delta)
            } catch {
                session.requestSnapshot()
                update.events += delta.events
                break
            }
            update.rows.formUnion(changed)
            update.events += delta.events
            if delta.isSnapshot || delta.generation != before.generation { update.replaced = true }
            if mirror.cursor != before.cursor { update.cursorChanged = true }
            if delta.palette != nil && mirror.palette != before.palette { update.paletteChanged = true }
            if mirror.title != before.title { update.titleChanged = true }
            if mirror.viewportTopLine != before.viewportTopLine || mirror.viewportOffset != before.viewportOffset {
                update.viewportMoved = true
            }
        }
        update.events = TerminalEvent.coalesced(update.events)
        return update
    }
}
