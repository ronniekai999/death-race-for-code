import PTYKit
import ScreenProtocol
import VTCore

/// One session, told apart from the others by the host that made it. Unique for as long as
/// the process that minted it runs; a daemon's ids outlive any one app.
public struct SessionID: Hashable, Sendable, CustomStringConvertible {
    public let value: UInt64

    public init(_ value: UInt64) {
        self.value = value
    }

    public var description: String { String(value) }

    private static let counter = Locked<UInt64>(0)

    /// The next id this process has not used.
    public static func next() -> SessionID {
        SessionID(
            counter.withLock { value in
                value += 1
                return value
            })
    }
}

/// What a terminal view needs from the session behind it: the screen, what to send it, and
/// what it can be asked.
///
/// `Session` runs a shell on a pseudo-terminal in this process; `ReplaySession` feeds an
/// engine in process, for tests and tools; a remote session speaks to a daemon that holds
/// the shell. Deltas are **pulled**: the session publishes one and says so, and the view
/// takes it on its next frame, which is what lets a flood coalesce instead of queueing.
public protocol TerminalSession: AnyObject, Sendable {
    /// The waiting delta, if any. Taking it says the screen it describes has been applied.
    func takeDelta() -> ScreenDelta?
    var status: Session.Status { get }
    /// Queues bytes for the program; false when too much is already waiting.
    @discardableResult func send(_ bytes: [UInt8]) -> Bool
    /// Queues what the terminal reports on its own (focus, mouse, key releases): like
    /// `send`, but a scrolled-back view stays where it is.
    @discardableResult func sendReport(_ bytes: [UInt8]) -> Bool
    func resize(columns: Int, rows: Int, cellPixelWidth: Int, cellPixelHeight: Int)
    func scroll(by lines: Int)
    func scrollToBottom()
    func requestSnapshot()
    func setFocused(_ focused: Bool)
    func setBasePalette(_ palette: Palette)
    /// Clear to Start (⌘K) or Clear Scrollback (⌥⌘K).
    func clear(_ kind: Terminal.ClearKind)
    func text(in range: TextRegion, generation: UInt64) async -> String?
}

/// What a pane needs on top of the screen: which session this is, who is in the foreground,
/// and the two different ways of letting go.
public protocol ShellSession: TerminalSession {
    var id: SessionID { get }
    /// Whether this session's shell keeps running when this process goes. The app asks before
    /// deciding whether a pane is worth a question at quit, and whether to detach or close.
    var outlivesItsClient: Bool { get }
    func foregroundProcess() async -> ForegroundProcess?
    /// Ends the shell: it is hung up, and killed if it lingers.
    func close()
    /// Stops watching and leaves the shell running, where it can be taken up again.
    ///
    /// The difference from `close` is the whole of Legends Never Die, so every place that
    /// lets go of a session has to say which it means. Closing a pane or a tab is `close`;
    /// quitting the app is `detach`.
    func detach()
}

/// A session a host knows about but this process may never have watched.
public struct SessionDescription: Sendable, Equatable {
    public var id: SessionID
    public var status: Session.Status
    public var columns: Int
    public var rows: Int
    /// What is running on it, for a sentence like "3 sessions kept running".
    public var shellExecutable: String
    public var startedAtMilliseconds: UInt64
    /// Opaque to the host, which only stores it: what the app needs to put the session back
    /// in the window it came from.
    public var metadata: [UInt8]

    public init(
        id: SessionID, status: Session.Status, columns: Int, rows: Int, shellExecutable: String,
        startedAtMilliseconds: UInt64, metadata: [UInt8]
    ) {
        self.id = id
        self.status = status
        self.columns = columns
        self.rows = rows
        self.shellExecutable = shellExecutable
        self.startedAtMilliseconds = startedAtMilliseconds
        self.metadata = metadata
    }
}

/// Why a host could not do what was asked.
public enum SessionHostError: Error, Equatable {
    /// Nothing is listening, or it would not talk in time.
    case unreachable(String)
    /// Both ends are running, and have no version in common.
    case incompatible(ours: ClosedRange<UInt16>, theirs: ClosedRange<UInt16>, build: String)
    case atCapacity(limit: Int)
    case unknownSession(SessionID)
    case alreadyAttached(SessionID)
    case refused(String)
    /// The shell itself would not start.
    case start(String)
}

/// Where sessions come from: this process, or a daemon that outlives it.
///
/// The three calls that make a session block with a deadline rather than being `async`. A
/// pane already spawns its shell on the main actor, and a round trip to a socket on the same
/// machine is the same order of cost; making this async would turn restoring a window into a
/// state machine for nothing anyone would see. On a deadline they throw, and the app falls
/// back to running sessions in process.
public protocol SessionHost: Sendable {
    /// Whether sessions this host makes outlive the process that asked for them.
    var sessionsSurviveQuit: Bool { get }
    /// Sessions already running, from before this process started.
    func existing() throws(SessionHostError) -> [SessionDescription]
    func start(
        _ launch: ShellLaunch, configuration: Terminal.Configuration, metadata: [UInt8],
        onUpdate: @escaping @Sendable () -> Void
    ) throws(SessionHostError) -> any ShellSession
    /// Takes up a session this process is not watching.
    func adopt(_ id: SessionID, onUpdate: @escaping @Sendable () -> Void) throws(SessionHostError) -> any ShellSession
    func setMetadata(_ metadata: [UInt8], for id: SessionID)
    /// Ends a session without taking it up first.
    func end(_ id: SessionID)
}

/// Sessions in this process, which is what every phase before Legends Never Die did, and
/// what the app falls back to whenever the daemon cannot be reached or understood.
public struct InProcessHost: SessionHost {
    public init() {}

    public var sessionsSurviveQuit: Bool { false }

    /// Nothing outlives the process, so there is never anything to find.
    public func existing() throws(SessionHostError) -> [SessionDescription] { [] }

    public func start(
        _ launch: ShellLaunch, configuration: Terminal.Configuration, metadata: [UInt8],
        onUpdate: @escaping @Sendable () -> Void
    ) throws(SessionHostError) -> any ShellSession {
        do {
            return try Session(launch: launch, configuration: configuration, onUpdate: onUpdate)
        } catch {
            throw .start("\(error)")
        }
    }

    public func adopt(
        _ id: SessionID, onUpdate: @escaping @Sendable () -> Void
    ) throws(SessionHostError) -> any ShellSession {
        throw .unknownSession(id)
    }

    /// There is nowhere to keep it: a session that dies with the process needs no note of
    /// where it belonged.
    public func setMetadata(_ metadata: [UInt8], for id: SessionID) {}

    public func end(_ id: SessionID) {}
}
