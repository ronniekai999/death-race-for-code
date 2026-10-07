/// The best time each command has taken, so "3.1s faster than your best" has something true
/// behind it.
///
/// Kept between runs by `BestsStore`, so a personal best is a personal best and not the best
/// since you last launched. What that costs is a file of command lines, which is why it is
/// 0600, capped, has a setting to turn it off, and never records a command you asked the shell
/// to keep out of its history.
///
/// Successful runs only. A command that failed after four seconds did not set a record, and
/// offering it as one next time would be a lie in the shape of a compliment.
public struct CommandBests: Sendable, Equatable {
    /// How many commands are remembered. A session that runs for days types a lot of different
    /// lines, and every one of them would otherwise be held for ever.
    public let limit: Int
    private var times: [String: UInt32] = [:]
    /// The best each command had *before* the run that currently holds the record. Kept because
    /// a badge is drawn long after the run it describes: by then `best(for:)` is the run's own
    /// time, so comparing with it says nothing. Not persisted — a fresh launch has no "before",
    /// and the first faster run after it makes one.
    private var earlier: [String: UInt32] = [:]
    /// Least recently recorded first, so the cap drops the command you have not run in longest
    /// rather than an arbitrary one.
    private var order: [String] = []

    public init(limit: Int = 500) {
        self.limit = max(limit, 1)
    }

    public var count: Int { times.count }

    /// The best time for `command` so far, or nil for one never seen.
    public func best(for command: String) -> UInt32? { times[command] }

    /// Records a successful run, and answers the best it beat — nil when it set the first time
    /// for this command, or did not beat the one there was.
    @discardableResult
    public mutating func record(command: String, milliseconds: UInt32) -> UInt32? {
        guard !command.isEmpty, !Self.isPrivate(command) else { return nil }
        order.removeAll { $0 == command }
        order.append(command)
        if order.count > limit, let oldest = order.first {
            order.removeFirst()
            times[oldest] = nil
            earlier[oldest] = nil
        }
        guard let previous = times[command] else {
            times[command] = milliseconds
            return nil
        }
        guard milliseconds < previous else { return nil }
        times[command] = milliseconds
        earlier[command] = previous
        return previous
    }

    /// The time a run of `command` taking `milliseconds` should be measured against: the best
    /// of the *other* runs.
    ///
    /// For the run that holds the record that is the best before it, which is the whole reason
    /// `earlier` is kept. Asking `best(for:)` instead compares a run with itself and can never
    /// say anything — which is exactly what the badge did, so "faster than your best" and the
    /// 999 flash were unreachable while the status bar, handed the beaten time directly, said
    /// the opposite at the same moment. A slower run gets the record itself, which it cannot
    /// beat, so it stays quiet.
    public func bestToBeat(for command: String, milliseconds: UInt32?) -> UInt32? {
        guard let milliseconds, let best = times[command] else { return nil }
        return milliseconds <= best ? earlier[command] : best
    }
}

extension CommandBests {

    /// A command the shell was asked to keep out of its history, by the oldest convention there
    /// is: a leading space (`HISTCONTROL=ignorespace`, zsh's `HIST_IGNORE_SPACE`).
    ///
    /// Checked here rather than trusted to the shell, because the shells do not agree about what
    /// they report: bash's integration reads `history 1`, and for a space-prefixed line the
    /// history number does not advance, so it falls back to `$BASH_COMMAND` and the command
    /// arrives anyway. Someone who typed a space meant it, whichever shell they typed it into —
    /// and `CommandRecord.cleaned` leaves leading spaces alone, so it is still there to see.
    public static func isPrivate(_ command: String) -> Bool { command.hasPrefix(" ") }

    /// The commands and their times, least recently run first — the order the cap drops in, so
    /// a file written and read back keeps its idea of which one to forget next.
    public var entries: [(command: String, milliseconds: UInt32)] {
        order.compactMap { command in times[command].map { (command, $0) } }
    }

    /// Replays `entries` in order, so loading a file applies the same cap and the same privacy
    /// rule as running the commands would have. A file hand-edited to hold a private command, or
    /// more commands than the cap allows, comes back obeying both.
    public init(limit: Int = 500, entries: [(command: String, milliseconds: UInt32)]) {
        self.init(limit: limit)
        for entry in entries { record(command: entry.command, milliseconds: entry.milliseconds) }
    }
}
