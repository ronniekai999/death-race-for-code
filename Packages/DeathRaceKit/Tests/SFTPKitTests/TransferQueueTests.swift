import Testing

@testable import SFTPKit

@Suite struct TransferQueueTests {
    @Test func enqueueStartsQueued() {
        var queue = TransferQueue()
        let id = queue.enqueue(
            .upload, name: "app.tar.gz", localPath: "/Users/r/app.tar.gz", remotePath: "/var/www/app.tar.gz")
        #expect(queue.transfers.count == 1)
        #expect(queue[id]?.state == .queued)
        #expect(queue[id]?.direction == .upload)
        #expect(queue[id]?.fraction == 0)
        #expect(queue.hasActive)
    }

    @Test func aTransferRunsToCompletion() {
        var queue = TransferQueue()
        let id = queue.enqueue(.download, name: "f", localPath: "/l", remotePath: "/r")
        queue.begin(id, total: 100)
        #expect(queue[id]?.state == .transferring(done: 0, total: 100))
        queue.progress(id, done: 50)
        #expect(queue[id]?.fraction == 0.5)
        queue.progress(id, done: 100)
        #expect(queue[id]?.fraction == 1)
        queue.finish(id)
        #expect(queue[id]?.state == .finished)
        #expect(queue[id]?.isActive == false)
        #expect(!queue.hasActive)
    }

    @Test func progressIsClampedToTheTotal() {
        var queue = TransferQueue()
        let id = queue.enqueue(.download, name: "f", localPath: "/l", remotePath: "/r")
        queue.begin(id, total: 10)
        queue.progress(id, done: 999)
        #expect(queue[id]?.state == .transferring(done: 10, total: 10))
        #expect(queue[id]?.fraction == 1)
    }

    @Test func cancelStopsProgressAndStartsAreIgnoredAfter() {
        var queue = TransferQueue()
        let id = queue.enqueue(.upload, name: "f", localPath: "/l", remotePath: "/r")
        queue.begin(id, total: 100)
        queue.progress(id, done: 30)
        queue.cancel(id)
        #expect(queue[id]?.state == .cancelled)
        #expect(queue[id]?.isActive == false)
        // A late progress report or a stray begin must not revive it.
        queue.progress(id, done: 90)
        queue.begin(id, total: 100)
        #expect(queue[id]?.state == .cancelled)
    }

    @Test func progressAndFinishAfterAFinalStateAreIgnored() {
        var queue = TransferQueue()
        let id = queue.enqueue(.download, name: "f", localPath: "/l", remotePath: "/r")
        queue.begin(id, total: 100)
        queue.finish(id)
        queue.progress(id, done: 10)
        queue.fail(id, "too late")
        #expect(queue[id]?.state == .finished)
    }

    @Test func failureCarriesItsReason() {
        var queue = TransferQueue()
        let id = queue.enqueue(.download, name: "f", localPath: "/l", remotePath: "/r")
        queue.begin(id, total: 5)
        queue.fail(id, "the server refused")
        #expect(queue[id]?.state == .failed("the server refused"))
        #expect(queue[id]?.isActive == false)
    }

    @Test func aZeroByteTransferCompletes() {
        var queue = TransferQueue()
        let id = queue.enqueue(.upload, name: "empty", localPath: "/l", remotePath: "/r")
        queue.begin(id, total: 0)
        #expect(queue[id]?.fraction == 0)
        queue.finish(id)
        #expect(queue[id]?.fraction == 1)
    }

    @Test func removeAndClearCompleted() {
        var queue = TransferQueue()
        let a = queue.enqueue(.upload, name: "a", localPath: "/l/a", remotePath: "/r/a")
        let b = queue.enqueue(.download, name: "b", localPath: "/l/b", remotePath: "/r/b")
        queue.begin(a, total: 1)
        queue.finish(a)
        queue.begin(b, total: 1)
        #expect(queue.active.map(\.id) == [b])
        queue.clearCompleted()
        #expect(queue.transfers.map(\.id) == [b])
        queue.remove(b)
        #expect(queue.transfers.isEmpty)
    }
}
