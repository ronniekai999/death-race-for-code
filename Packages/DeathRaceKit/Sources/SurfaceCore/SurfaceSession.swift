import ScreenProtocol
import SessionKit
import VTCore

/// What a terminal view needs from the session behind it. `Session` runs a shell on a
/// pseudo-terminal; `ReplaySession` feeds an engine in process, for tests and tools.
public protocol SurfaceSession: AnyObject, Sendable {
    /// The waiting delta, if any.
    func takeDelta() -> ScreenDelta?
    var status: Session.Status { get }
    /// Queues bytes for the program; false when too much is already waiting.
    @discardableResult func send(_ bytes: [UInt8]) -> Bool
    func resize(columns: Int, rows: Int, cellPixelWidth: Int, cellPixelHeight: Int)
    func scroll(by lines: Int)
    func scrollToBottom()
    func requestSnapshot()
    func setFocused(_ focused: Bool)
    func setBasePalette(_ palette: Palette)
    func text(in range: TextRange, generation: UInt64) async -> String?
}

extension Session: SurfaceSession {}

/// An engine in process behind the `SurfaceSession` interface: bytes go in through `feed`,
/// deltas come out the way a session publishes them, and what the view sends collects in
/// `sent`. Deterministic, for tests, `vthost frame` and the smoke test.
///
/// Not thread-safe: use it from one thread. (It is Sendable only to fit the protocol.)
public final class ReplaySession: SurfaceSession, @unchecked Sendable {
    public let terminal: Terminal
    private var builder = DeltaBuilder()
    private var publishedVersion: UInt64 = .max
    private var mustPublish = true
    /// Everything the view sent: keys, pastes, reports.
    public private(set) var sent: [UInt8] = []
    public private(set) var focused = false
    public var status: Session.Status = .running

    public init(_ configuration: Terminal.Configuration) {
        terminal = Terminal(configuration)
    }

    /// Output from the "program".
    public func feed(_ bytes: [UInt8]) {
        terminal.feed(bytes)
        _ = terminal.takeReplies()
    }

    public func feed(_ text: String) {
        feed(Array(text.utf8))
    }

    public func takeDelta() -> ScreenDelta? {
        guard mustPublish || terminal.currentVersion != publishedVersion || !terminal.events.isEmpty else {
            return nil
        }
        let delta = builder.makeDelta(from: terminal, events: terminal.takeEvents())
        builder.didDeliver(delta)
        publishedVersion = terminal.currentVersion
        mustPublish = false
        return delta
    }

    @discardableResult
    public func send(_ bytes: [UInt8]) -> Bool {
        sent += bytes
        if builder.viewportOffset > 0 {
            builder.scrollToBottom()
            mustPublish = true
        }
        return true
    }

    public func resize(columns: Int, rows: Int, cellPixelWidth: Int, cellPixelHeight: Int) {
        terminal.resize(columns: columns, rows: rows)
        mustPublish = true
    }

    public func scroll(by lines: Int) {
        builder.scroll(by: lines, in: terminal)
        mustPublish = true
    }

    public func scrollToBottom() {
        builder.scrollToBottom()
        mustPublish = true
    }

    public func requestSnapshot() {
        builder.reset()
        mustPublish = true
    }

    public func setFocused(_ focused: Bool) {
        self.focused = focused
    }

    public func setBasePalette(_ palette: Palette) {
        terminal.setBasePalette(palette)
    }

    public func text(in range: TextRange, generation: UInt64) async -> String? {
        guard generation == terminal.generation else { return nil }
        return TextExtractor.text(in: range) { terminal.line($0) }
    }
}
