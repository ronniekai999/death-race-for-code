import Foundation

/// A bounded random-access source lets several SFTP writes overlap without buffering a file.
public struct TransferSource: Sendable {
    public let size: UInt64
    public let read: @Sendable (UInt64, Int) async throws -> [UInt8]

    public init(size: UInt64, read: @escaping @Sendable (UInt64, Int) async throws -> [UInt8]) {
        self.size = size
        self.read = read
    }
}

public struct TransferDestination: Sendable {
    public let write: @Sendable ([UInt8], UInt64) async throws -> Void
    public let commit: @Sendable (Bool) async throws -> Void

    public init(
        write: @escaping @Sendable ([UInt8], UInt64) async throws -> Void,
        commit: @escaping @Sendable (Bool) async throws -> Void
    ) {
        self.write = write
        self.commit = commit
    }
}

/// Event-driven progress: no idle timer, at most twenty intermediate UI updates a second.
/// The queue also rejects backwards reports, since MainActor tasks can arrive out of order.
final class TransferProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var last: ContinuousClock.Instant?
    private var completed: UInt64 = 0

    func report(_ done: UInt64, total: UInt64) -> (UInt64, UInt64)? {
        lock.withLock {
            completed = max(completed, done)
            let now = ContinuousClock.now
            guard last == nil || last!.duration(to: now) >= .milliseconds(50) || done >= total else { return nil }
            last = now
            return (completed, max(total, completed))
        }
    }
}
