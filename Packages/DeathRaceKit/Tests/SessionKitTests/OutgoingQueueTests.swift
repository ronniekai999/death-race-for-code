import PTYKit
import Testing

@testable import SessionKit

@Suite struct OutgoingQueueTests {
    @Test func repliesPastTheLimitAreDroppedWhole() {
        var queue = OutgoingQueue(replyLimit: 8)
        let accepted = ["\u{1B}[?62;22c", "\u{1B}[0n", "\u{1B}[0n", "\u{1B}[0n"].map {
            queue.appendReplies(Array($0.utf8))
        }
        // The first (9 bytes) is a byte too long; the last would take the queue past the limit.
        #expect(accepted == [false, true, true, false])
        #expect(queue.replyBytes == 8)
        // Typed input is limited elsewhere and never dropped here.
        queue.appendInput([UInt8](repeating: 0x61, count: 100))
        var written: [UInt8] = []
        let input = queue.write { bytes in
            written += bytes
            return .wrote(bytes.count)
        }
        #expect(input == 100)
        #expect(written == Array("\u{1B}[0n\u{1B}[0n".utf8) + [UInt8](repeating: 0x61, count: 100))
        #expect(queue.replyBytes == 0)
        #expect(queue.isEmpty)
    }

    @Test func partialWritesKeepTheirPlace() {
        var queue = OutgoingQueue(replyLimit: 1 << 20)
        queue.appendInput(Array("hello".utf8))
        queue.appendReplies(Array("\u{1B}[0n".utf8))
        var written: [UInt8] = []
        var calls = 0
        func twoAtATime(_ bytes: UnsafeRawBufferPointer) -> PseudoTerminal.WriteResult {
            calls += 1
            if calls > 3 { return .wouldBlock }
            let n = min(2, bytes.count)
            written += bytes.prefix(n)
            return .wrote(n)
        }
        // Three calls: "he", "ll", "o"; then the terminal would block.
        let first = queue.write(twoAtATime)
        #expect(first == 5)
        #expect(written == Array("hello".utf8))
        #expect(queue.replyBytes == 4)
        calls = 0
        let second = queue.write(twoAtATime)
        #expect(second == 0)
        #expect(written == Array("hello\u{1B}[0n".utf8))
        #expect(queue.isEmpty && queue.replyBytes == 0)
    }

    @Test func aClosedTerminalEmptiesTheQueue() {
        var queue = OutgoingQueue(replyLimit: 1 << 20)
        queue.appendInput([1, 2, 3])
        queue.appendReplies([4, 5])
        let input = queue.write { _ in .closed }
        #expect(input == 0)
        #expect(queue.isEmpty && queue.replyBytes == 0)
    }
}
