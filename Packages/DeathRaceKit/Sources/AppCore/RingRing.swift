/// What a notification says and whether to send one at all.
///
/// The decision is here, in portable code, and only the delivery is macOS — the
/// `HotKeyRegistrar` shape. A notification is the kind of thing that is easy to get subtly
/// wrong and impossible to test by looking at it once, so the rules are a table.
public enum RingRing {

    /// A command that has just finished, as much of it as the decision needs.
    public struct Finished: Sendable, Equatable {
        public var command: String
        public var milliseconds: UInt32?
        public var exitCode: Int32?
        /// The pane it ran in was on screen and in the active tab of a window in front. Watching
        /// a command finish is the one case where a notification is pure noise.
        public var wasWatched: Bool
        /// The program sent its own `OSC 9` notification. Two notifications for one command is
        /// worse than none, and the program's says more than ours could.
        public var programNotified: Bool

        public init(
            command: String, milliseconds: UInt32?, exitCode: Int32?, wasWatched: Bool,
            programNotified: Bool = false
        ) {
            self.command = command
            self.milliseconds = milliseconds
            self.exitCode = exitCode
            self.wasWatched = wasWatched
            self.programNotified = programNotified
        }
    }

    /// A notification, ready to hand to whatever delivers it.
    public struct Notice: Sendable, Equatable {
        public var title: String
        public var body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    /// Whether `finished` is worth saying out loud, and what to say. Nil for the common case.
    ///
    /// The rules, in order, because the order is the design:
    ///
    /// 1. **Watched commands never notify.** You were looking at it.
    /// 2. **A program that notified itself wins.** Ours would be a second, worse copy.
    /// 3. **A command with no duration cannot be judged**, so it is not. That is macOS's
    ///    `/bin/bash` 3.2, which has no `$EPOCHREALTIME` — a documented limit rather than a
    ///    guess at how long it took.
    /// 4. **Over the threshold, or failed** — a failure is the thing you most need to know
    ///    about, and it is told however quick it was, because a build that fell over in two
    ///    seconds is still a build that fell over.
    /// 5. **A command hidden from shell history is never named.** The same leading space that
    ///    keeps it out of `bests.json` keeps it out of a banner on your screen, which is where
    ///    someone else can read it.
    public static func notice(for finished: Finished, thresholdSeconds: UInt32) -> Notice? {
        guard !finished.wasWatched, !finished.programNotified else { return nil }
        guard let milliseconds = finished.milliseconds else { return nil }
        let failed = (finished.exitCode ?? 0) != 0
        let slow = milliseconds >= thresholdSeconds &* 1_000
        guard failed || slow else { return nil }
        guard !CommandBests.isPrivate(finished.command) else { return nil }

        let name = finished.command.isEmpty ? "A command" : finished.command
        let duration = FastLabel.duration(milliseconds)
        if failed, let code = finished.exitCode {
            return Notice(title: name, body: "Exited with status \(code) after \(duration)")
        }
        return Notice(title: name, body: "Finished in \(duration)")
    }
}

/// Delivering a notification, which only macOS can do.
///
/// The seam exists for the same reason `HotKeyRegistrar`'s does: the thing worth testing is the
/// decision, and the thing that cannot be tested here is the one call into the system. A fake
/// records what it was asked to deliver, so the app's wiring is covered by the window tests
/// without any notification ever being posted.
public protocol Notifier: AnyObject, Sendable {
    /// Asks for permission once, if it has not been asked for yet.
    func requestAuthorization()
    /// Delivers `notice`; `paneID` comes back to whoever handles a tap, so it can focus the
    /// pane the command ran in.
    func deliver(_ notice: RingRing.Notice, paneID: UInt64)
}

/// A `Notifier` that posts nothing and remembers everything, for tests and for a build that
/// cannot ask (a bare `swift run` has no bundle to ask from).
public final class FakeNotifier: Notifier, @unchecked Sendable {
    public private(set) var askedForAuthorization = false
    public private(set) var delivered: [(notice: RingRing.Notice, paneID: UInt64)] = []

    public init() {}

    public func requestAuthorization() { askedForAuthorization = true }

    public func deliver(_ notice: RingRing.Notice, paneID: UInt64) {
        delivered.append((notice, paneID))
    }
}
