import Foundation
import PTYKit
import ScreenProtocol
import VTCore

/// A shell on a pseudo-terminal, run by its own thread.
///
/// The thread owns the terminal and the engine; nothing is shared with the app except a
/// small locked mailbox. It blocks in `poll` until the shell writes or the app asks for
/// something, so an idle session costs nothing. After reading everything available it
/// publishes one delta into the mailbox and, if the mailbox was empty, calls `onUpdate`;
/// the app takes the delta on its next frame. A newer delta replaces one the app has not
/// taken, so a flood of output never queues up work for the renderer.
///
/// All methods are safe to call from any thread.
public final class Session: Sendable {
    public enum Status: Sendable, Equatable {
        case running
        /// The shell exited; nil when its status could not be collected.
        case exited(ExitStatus?)
    }

    /// Which session this is. An in-process session mints its own: nothing outside the
    /// process can refer to it anyway.
    public let id = SessionID.next()

    /// A shell in this process goes when the process does.
    public var outlivesItsClient: Bool { false }

    let channel: SessionChannel

    /// Starts `launch` on a new terminal. `onUpdate` runs on the session thread when a
    /// delta or a status change is waiting; it should only schedule work.
    public init(
        launch: ShellLaunch,
        configuration: Terminal.Configuration = Terminal.Configuration(),
        onUpdate: @escaping @Sendable () -> Void
    ) throws {
        let size = TerminalSize(
            rows: UInt16(clamping: configuration.rows), columns: UInt16(clamping: configuration.columns),
            pixelWidth: UInt16(clamping: configuration.columns * configuration.cellPixelWidth),
            pixelHeight: UInt16(clamping: configuration.rows * configuration.cellPixelHeight))
        // The pipe first: once the shell runs, a failure here would leave it unreaped.
        channel = SessionChannel(wake: try WakePipe(), onUpdate: onUpdate)
        let pty = try PseudoTerminal.spawn(launch, size: size)
        let loop = Transfer(SessionLoop(pty: pty, terminal: Terminal(configuration), channel: channel))
        let thread = Thread { loop.value.run() }
        thread.name = "Death Race session"
        thread.stackSize = 1 << 20
        thread.start()
    }

    deinit {
        channel.send(.close)
    }

    // MARK: - Commands

    /// Queues bytes for the shell (keys, pastes); typing also returns the view to the
    /// bottom. Returns false when more than `SessionChannel.inputLimit` bytes are already
    /// waiting, so a runaway paste cannot grow memory without bound.
    @discardableResult
    public func send(_ bytes: [UInt8]) -> Bool {
        channel.sendInput(bytes, typed: true)
    }

    /// Queues what the terminal reports on its own rather than what the user typed (focus
    /// changes, mouse reports, key releases): like `send`, but a scrolled-back view stays
    /// where it is.
    @discardableResult
    public func sendReport(_ bytes: [UInt8]) -> Bool {
        channel.sendInput(bytes, typed: false)
    }

    /// Resizes the terminal and tells the program. Resizes that arrive faster than the
    /// session can apply them coalesce into the last one.
    public func resize(columns: Int, rows: Int, cellPixelWidth: Int = 0, cellPixelHeight: Int = 0) {
        channel.send(.resize(columns: columns, rows: rows, cellWidth: cellPixelWidth, cellHeight: cellPixelHeight))
    }

    /// Scrolls the view `lines` back into history (negative: toward the output).
    public func scroll(by lines: Int) {
        channel.send(.scroll(lines))
    }

    public func scrollToBottom() {
        channel.send(.scrollToBottom)
    }

    /// Asks for a delta with every row, after a mirror refused one.
    public func requestSnapshot() {
        channel.send(.snapshot)
    }

    /// A focused session's thread runs at user-initiated priority; others at utility, which
    /// lets macOS keep them on the efficiency cores.
    public func setFocused(_ focused: Bool) {
        channel.send(.focus(focused))
    }

    /// Hangs up: closes the terminal, sends SIGHUP, and kills the shell if it lingers.
    public func close() {
        channel.send(.close)
    }

    /// Stops watching and leaves the shell running — except that in this process there is
    /// nowhere to leave it, so this ends the session exactly as `close` does.
    ///
    /// It is here so that every place in the app which lets go of a session has to say which
    /// it means, whether or not a daemon is holding it. A pane being closed means `close`; the
    /// app quitting means `detach`, and only then does the difference show.
    public func detach() {
        close()
    }

    /// Stops building deltas, or starts again.
    ///
    /// Nothing takes the deltas of a session nobody is watching, so `DeltaBuilder` never
    /// advances and every publish would rebuild the whole viewport — and in debug builds send
    /// it through the codec as well. A detached session running `yes` would spend its time
    /// drawing screens that will never be read. The shell keeps running throughout; turning
    /// publishing back on makes the next delta a full one.
    public func setPublishing(_ on: Bool) {
        channel.send(.publishing(on))
    }

    /// Whether this session has ever published a screen, so a client taking it up can be
    /// given a whole one rather than a delta built on a base it has never seen.
    public var hasPublished: Bool {
        channel.mailbox.withLock { $0.published }
    }

    /// Installs a new base palette, the app's theme: colors programs set stay, the rest
    /// change, and the next delta carries the result.
    public func setBasePalette(_ palette: Palette) {
        channel.send(.setBasePalette(palette))
    }

    /// Clears for the user, as Terminal's ⌘K (`.toStart`) and ⌥⌘K (`.scrollback`) do. The
    /// alternate screen is left alone.
    public func clear(_ kind: Terminal.ClearKind) {
        channel.send(.clear(kind))
    }

    // MARK: - Questions

    /// The text of `range`, read on the session thread, so it reaches into history the app
    /// does not have. Nil when the screen is no longer the one of `generation` (the line
    /// numbers would point at other text) or the session has ended.
    public func text(in range: TextRegion, generation: UInt64) async -> String? {
        await withCheckedContinuation { continuation in
            channel.send(.query(.text(range, generation: generation, continuation)))
        }
    }

    /// Who is in the terminal's foreground, or nil once the session has ended.
    public func foregroundProcess() async -> ForegroundProcess? {
        await withCheckedContinuation { continuation in
            channel.send(.query(.foregroundProcess(continuation)))
        }
    }

    // MARK: - Results

    /// The waiting delta, if any. Taking it tells the session the app has it.
    public func takeDelta() -> ScreenDelta? {
        channel.mailbox.withLock { box in
            guard let delta = box.pending else { return nil }
            box.pending = nil
            box.taken = delta
            return delta
        }
    }

    public var status: Status {
        channel.mailbox.withLock { $0.status }
    }
}

extension Session: ShellSession {}

/// What the app and the session thread share: a mailbox under a lock, and the pipe that
/// wakes the thread.
final class SessionChannel: Sendable {
    enum Command: Sendable {
        /// Bytes for the program; `typed` ones return a scrolled-back view to the bottom.
        case input([UInt8], typed: Bool)
        case resize(columns: Int, rows: Int, cellWidth: Int, cellHeight: Int)
        case scroll(Int)
        case scrollToBottom
        case snapshot
        case focus(Bool)
        case setBasePalette(Palette)
        case clear(Terminal.ClearKind)
        case publishing(Bool)
        case query(Query)
        case close
    }

    /// A command that answers. Every query is answered exactly once: by the session thread,
    /// or with nil when the session has ended, so no caller waits forever.
    enum Query: Sendable {
        case text(TextRegion, generation: UInt64, CheckedContinuation<String?, Never>)
        case foregroundProcess(CheckedContinuation<ForegroundProcess?, Never>)

        /// Answers nil: there is no session to ask.
        func cancel() {
            switch self {
            case .text(_, _, let reply): reply.resume(returning: nil)
            case .foregroundProcess(let reply): reply.resume(returning: nil)
            }
        }
    }

    struct Mailbox: Sendable {
        var commands: [Command] = []
        var queuedInput = 0
        /// Published, not yet taken by the app.
        var pending: ScreenDelta?
        /// Taken by the app; the session thread records it as delivered.
        var taken: ScreenDelta?
        var status = Session.Status.running
        /// Whether any screen has ever been published. A session that has published has a
        /// builder whose base is some client's last screen, so whoever takes it up next needs
        /// a whole screen rather than a delta chained off a base it does not hold.
        var published = false
    }

    /// Input bytes allowed to wait for the shell to read them.
    static let inputLimit = 16 * 1024 * 1024

    let mailbox = Locked(Mailbox())
    let wake: WakePipe
    let onUpdate: @Sendable () -> Void

    init(wake: WakePipe, onUpdate: @escaping @Sendable () -> Void) {
        self.wake = wake
        self.onUpdate = onUpdate
    }

    /// Queues a command for the session thread; once the session has ended there is no one
    /// to run it, so it is dropped, and a query is answered with nil.
    func send(_ command: Command) {
        let queued = mailbox.withLock { box in
            guard box.status == .running else { return false }
            box.commands.append(command)
            return true
        }
        if queued {
            wake.signal()
        } else if case .query(let query) = command {
            query.cancel()
        }
    }

    func sendInput(_ bytes: [UInt8], typed: Bool) -> Bool {
        guard !bytes.isEmpty else { return true }
        let accepted = mailbox.withLock { box in
            guard box.status == .running, box.queuedInput + bytes.count <= Self.inputLimit else { return false }
            box.queuedInput += bytes.count
            box.commands.append(.input(bytes, typed: typed))
            return true
        }
        if accepted { wake.signal() }
        return accepted
    }
}

/// Moves a value to another thread that becomes its only user.
struct Transfer<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
