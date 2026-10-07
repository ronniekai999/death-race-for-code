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

    /// What to deliver for a program's own `OSC 9`, or nil for one not worth interrupting for.
    ///
    /// Rule 2 above stands down for a program that notified itself — but standing down is only
    /// right if the program's own words then reach you. They were being dropped: nothing read
    /// the event's title and body, so a program that notified got no notification at all,
    /// neither its own nor ours. **Passing it on is what rule 2 always meant.**
    ///
    /// The watched rule still applies, because it is about you already having the information
    /// and that is true whoever wrote the banner. A program with no title of its own is named
    /// by whatever the pane is running, since "" is not a notification anyone can read.
    public static func notice(fromProgram title: String, body: String, in pane: String, wasWatched: Bool) -> Notice? {
        guard !wasWatched else { return nil }
        let said = banner(title).isEmpty ? banner(body) : "\(banner(title)) — \(banner(body))"
        guard !said.isEmpty else { return nil }
        // **The title is the pane, never the program.** These words came off a stream of bytes
        // the project's own threat model calls hostile: a compromised host, a tailed log, a
        // piped HTTP response. Delivered as the title they would read as the app's own voice,
        // and the watched rule means they arrive precisely when there is nothing on screen to
        // attribute them to — so a banner could say "Death Race for Code / your key could not
        // be verified, run this" and look exactly like a banner the app wrote. Under the pane's
        // own name they are plainly a program talking.
        return Notice(title: pane.isEmpty ? "A program" : banner(pane), body: said)
    }

    /// Text a program supplied, made fit for a banner: bounded, and with the formatting scalars
    /// that reorder what the eye reads taken out.
    ///
    /// Controls, DEL and C1 are already gone before this — `CommandRecord.cleaned` does that at
    /// the app's boundary, where VTCore is in scope, and it is deliberately not repeated here
    /// (`AppCore` cannot see VTCore, which is the same boundary that makes `FastLabel` take
    /// plain values). What is left to do is the part specific to a line someone reads and acts
    /// on: the bidi overrides and isolates, which can make a command or a URL render in an
    /// order it was not written in — the Trojan Source trick — and a length a notification can
    /// actually show.
    static func banner(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var kept = 0
        for scalar in text.unicodeScalars where !isReordering(scalar) {
            guard kept < bannerLimit else { break }
            out.append(scalar)
            kept += 1
        }
        return String(out).trimmingWhitespace
    }

    /// Enough for a banner macOS will show; past this it is truncated anyway.
    static let bannerLimit = 256

    /// The bidi controls that change reading order, and nothing else. **Not** every format
    /// scalar: U+200D is the zero-width joiner, which every multi-part emoji needs, so taking
    /// the whole category would mangle ordinary text to no purpose.
    private static func isReordering(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200E, 0x200F: true  // LRM, RLM
        case 0x202A...0x202E: true  // LRE, RLE, PDF, LRO, RLO
        case 0x2066...0x2069: true  // LRI, RLI, FSI, PDI
        default: false
        }
    }
}

extension String {

    /// Leading and trailing whitespace and newlines gone. A program's own notification text
    /// arrives as it was printed, often with the newline that ended the escape sequence's line.
    var trimmingWhitespace: String {
        var scalars = Substring(self)
        while let first = scalars.first, first.isWhitespace { scalars = scalars.dropFirst() }
        while let last = scalars.last, last.isWhitespace { scalars = scalars.dropLast() }
        return String(scalars)
    }
}

/// Delivering a notification, which only macOS can do.
///
/// The seam exists for the same reason `HotKeyRegistrar`'s does: the thing worth testing is the
/// decision, and the thing that cannot be tested here is the one call into the system. A fake
/// records what it was asked to deliver, so the app's wiring is covered by the window tests
/// without any notification ever being posted.
///
/// `@MainActor` because that is where it is called from and where it has to run: the real one
/// talks to `UNUserNotificationCenter` and keeps whether it has asked yet, and the decision that
/// reaches it is made in `PaneController`, which is main-actor isolated too. A nonisolated
/// protocol would make the one real conformer illegal — a main-actor class cannot satisfy
/// nonisolated requirements — and buy nothing, because nothing delivers a notice off the main
/// thread.
@MainActor
public protocol Notifier: AnyObject {
    /// Asks for permission once, if it has not been asked for yet.
    func requestAuthorization()
    /// Delivers `notice`; `paneID` comes back to whoever handles a tap, so it can focus the
    /// pane the command ran in.
    func deliver(_ notice: RingRing.Notice, paneID: UInt64)
}

/// A `Notifier` that posts nothing and remembers everything, for tests and for a build that
/// cannot ask (a bare `swift run` has no bundle to ask from).
@MainActor
public final class FakeNotifier: Notifier {
    public private(set) var askedForAuthorization = false
    public private(set) var delivered: [(notice: RingRing.Notice, paneID: UInt64)] = []

    public init() {}

    public func requestAuthorization() { askedForAuthorization = true }

    public func deliver(_ notice: RingRing.Notice, paneID: UInt64) {
        delivered.append((notice, paneID))
    }
}
