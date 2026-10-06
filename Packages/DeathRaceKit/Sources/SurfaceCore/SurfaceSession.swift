import ScreenProtocol
import SessionKit
import VTCore

/// What a terminal view needs from the session behind it. It lives in SessionKit, so a
/// session in another process can meet it without SurfaceCore — and the terminal view, and
/// `vthost` with it — having to know anything about sockets.
public typealias SurfaceSession = TerminalSession

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

    @discardableResult
    public func sendReport(_ bytes: [UInt8]) -> Bool {
        sent += bytes
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

    public func clear(_ kind: Terminal.ClearKind) {
        if terminal.clear(kind) { mustPublish = true }
    }

    public func text(in range: TextRegion, generation: UInt64) async -> String? {
        guard generation == terminal.generation else { return nil }
        return TextExtractor.text(in: range) { terminal.line($0) }
    }
}
