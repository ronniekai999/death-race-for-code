/// Maze's transfer queue: the uploads and downloads in flight, each a row the window draws as
/// a gradient bar. A pure value-type state machine (like `AppCore/WindowModel`), so the
/// transitions are tested on Linux; the Maze model holds one and mutates it as transfers run.
public struct TransferID: Hashable, Sendable {
    public let raw: UInt64
    public init(_ raw: UInt64) { self.raw = raw }
}

public struct Transfer: Equatable, Sendable, Identifiable {
    public enum Direction: Equatable, Sendable {
        case upload
        case download
    }

    public enum State: Equatable, Sendable {
        case queued
        case transferring(done: UInt64, total: UInt64)
        case finished
        /// Why it stopped, as a sentence.
        case failed(String)
        case cancelled
    }

    public let id: TransferID
    public var direction: Direction
    /// The file's name, for the row's label.
    public var name: String
    public var localPath: String
    public var remotePath: String
    public var state: State

    public init(
        id: TransferID, direction: Direction, name: String, localPath: String, remotePath: String,
        state: State = .queued
    ) {
        self.id = id
        self.direction = direction
        self.name = name
        self.localPath = localPath
        self.remotePath = remotePath
        self.state = state
    }

    /// Still queued or moving bytes.
    public var isActive: Bool {
        switch state {
        case .queued, .transferring: return true
        case .finished, .failed, .cancelled: return false
        }
    }

    /// 0…1 of the way done, for the bar. Queued is 0; a finished transfer is 1; a zero-byte
    /// file counts as complete once it starts.
    public var fraction: Double {
        switch state {
        case .queued: return 0
        case .finished: return 1
        case .failed, .cancelled: return 0
        case .transferring(let done, let total):
            guard total > 0 else { return done > 0 ? 1 : 0 }
            return min(1, Double(done) / Double(total))
        }
    }
}

public struct TransferQueue: Equatable, Sendable {
    public private(set) var transfers: [Transfer] = []
    private var nextID: UInt64 = 0

    /// How many rows to keep. Rows only leave when you press Clear, so a host that fails
    /// every transfer — each failure carrying its own message — would otherwise grow this
    /// without end. The oldest row that is no longer active goes first.
    public static let maxRows = 200

    public init() {}

    /// Add a transfer in the `queued` state and return its id.
    @discardableResult
    public mutating func enqueue(
        _ direction: Transfer.Direction, name: String, localPath: String, remotePath: String
    ) -> TransferID {
        nextID &+= 1
        let id = TransferID(nextID)
        transfers.append(
            Transfer(id: id, direction: direction, name: name, localPath: localPath, remotePath: remotePath))
        while transfers.count > Self.maxRows, let oldest = transfers.firstIndex(where: { !$0.isActive }) {
            transfers.remove(at: oldest)
        }
        return id
    }

    public subscript(_ id: TransferID) -> Transfer? { transfers.first { $0.id == id } }

    /// Begin moving a queued transfer. A cancelled one stays cancelled (a late start loses).
    public mutating func begin(_ id: TransferID, total: UInt64) {
        update(id) { if case .queued = $0.state { $0.state = .transferring(done: 0, total: total) } }
    }

    /// Report progress. Ignored once the transfer has left the `transferring` state (e.g. it
    /// was cancelled), so a trailing report can't revive it.
    public mutating func progress(_ id: TransferID, done: UInt64) {
        update(id) {
            if case .transferring(_, let total) = $0.state {
                $0.state = .transferring(done: min(done, total), total: total)
            }
        }
    }

    public mutating func finish(_ id: TransferID) {
        update(id) { if $0.isActive { $0.state = .finished } }
    }

    public mutating func fail(_ id: TransferID, _ message: String) {
        update(id) { if $0.isActive { $0.state = .failed(message) } }
    }

    /// Mark a transfer cancelled. The running task sees this (or its own cancellation) and stops.
    public mutating func cancel(_ id: TransferID) {
        update(id) { if $0.isActive { $0.state = .cancelled } }
    }

    /// Drop a row (a finished/failed/cancelled one the user cleared).
    public mutating func remove(_ id: TransferID) {
        transfers.removeAll { $0.id == id }
    }

    /// Drop every row that is no longer active.
    public mutating func clearCompleted() {
        transfers.removeAll { !$0.isActive }
    }

    public var active: [Transfer] { transfers.filter(\.isActive) }
    public var hasActive: Bool { transfers.contains { $0.isActive } }

    private mutating func update(_ id: TransferID, _ change: (inout Transfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }
}
