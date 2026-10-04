import Dispatch
import Testing

@testable import SessionKit

/// The mailbox lock under contention. Besides checking that it excludes, this is what keeps
/// the Thread Sanitizer step honest: Synchronization's Mutex hands a contended lock over on
/// Linux in code the sanitizer cannot see, which reads as a race on every contended hand-off.
@Suite struct LockedTests {
    @Test func contendedHandOffsKeepEveryUpdate() throws {
        let channel = SessionChannel(wake: try WakePipe(), onUpdate: {})
        let threads = 4
        let increments = 50_000
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for _ in 0..<increments {
                channel.mailbox.withLock { $0.queuedInput += 1 }
            }
        }
        #expect(channel.mailbox.withLock { $0.queuedInput } == threads * increments)
    }
}
