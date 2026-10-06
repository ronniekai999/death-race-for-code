/// The best time each command has taken, so "3.1s faster than your best" has something true
/// behind it.
///
/// In memory only, for as long as the app runs. Keeping it on disk is a different question with
/// a different answer — a file of command lines wants its mode, its cap, a setting to turn it
/// off and a plain account of what is in it — and that belongs with the rest of the Fast work
/// rather than with the drawing.
///
/// Successful runs only. A command that failed after four seconds did not set a record, and
/// offering it as one next time would be a lie in the shape of a compliment.
public struct CommandBests: Sendable, Equatable {
    /// How many commands are remembered. A session that runs for days types a lot of different
    /// lines, and every one of them would otherwise be held for ever.
    public let limit: Int
    private var times: [String: UInt32] = [:]
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
        guard !command.isEmpty else { return nil }
        order.removeAll { $0 == command }
        order.append(command)
        if order.count > limit, let oldest = order.first {
            order.removeFirst()
            times[oldest] = nil
        }
        guard let previous = times[command] else {
            times[command] = milliseconds
            return nil
        }
        guard milliseconds < previous else { return nil }
        times[command] = milliseconds
        return previous
    }
}
