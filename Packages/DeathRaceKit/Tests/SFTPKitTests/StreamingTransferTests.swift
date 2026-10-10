import Foundation
import Testing

@testable import SFTPKit

private actor ReorderingTransport: SFTPTransport {
    let server: FakeSFTPServer
    private var writes: [[UInt8]] = []
    private(set) var largestBatch = 0

    init() { server = FakeSFTPServer() }
    func send(_ frame: [UInt8]) async throws {
        if case .write = try SFTPPacket.decode(frame: frame) {
            writes.append(frame)
            largestBatch = max(largestBatch, writes.count)
            if writes.count == 4 {
                let batch = writes.reversed()
                writes.removeAll()
                for request in batch { try await server.send(request) }
            }
        } else {
            try await server.send(frame)
        }
    }
    func receive() async throws -> [UInt8] { try await server.receive() }
    func close() async { await server.close() }
}

@Suite struct StreamingTransferTests {
    @Test func pipelinedWritesCompleteWhenRepliesArriveInReverseOrder() async throws {
        let transport = ReorderingTransport()
        let client = SFTPClient(transport: transport, limits: .init(pipelineDepth: 4), requestTimeout: .seconds(2))
        try await client.start()
        let count = SFTPClient.chunkSize * 8
        let source = TransferSource(size: UInt64(count)) { offset, length in
            (0..<length).map { UInt8((offset + UInt64($0)) % 251) }
        }
        try await client.upload("/home/user/stream", source: source, overwrite: false, progress: { _, _ in })
        #expect(await transport.largestBatch == 4)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let destination = try await LocalFileSystem.local.openDownload(scratch.path)
        try await client.download("/home/user/stream", destination: destination, progress: { _, _ in })
        try await destination.commit(false)
        let result = try Data(contentsOf: scratch)
        #expect(result.count == count)
        #expect(Array(result) == (0..<count).map { UInt8($0 % 251) })
        await client.shutDown()
    }

    @Test func aDestinationCreatedAfterTheCheckCannotBeReplaced() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let staged = try LocalDownload(path: path.path)
        try staged.write([9], offset: 0)
        try Data([1, 2]).write(to: path)
        #expect(throws: POSIXError.self) { try staged.commit(overwrite: false) }
        #expect(try Data(contentsOf: path) == Data([1, 2]))
        try staged.commit(overwrite: true)
        #expect(try Data(contentsOf: path) == Data([9]))
    }

    @Test func cancellingADownloadLeavesTheDestinationAndCleansTheTemporaryFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("file")
        try Data([7]).write(to: path)
        do {
            let destination = try await LocalFileSystem.local.openDownload(path.path)
            try await destination.write([9], 0)
            // A failed/cancelled transfer drops its destination without committing.
        }
        #expect(try Data(contentsOf: path) == Data([7]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["file"])
    }

    @Test func progressCannotMoveBackwardsOrReviveAFinishedTransfer() {
        var queue = TransferQueue()
        let id = queue.enqueue(.upload, name: "file", localPath: "/file", remotePath: "/file")
        queue.begin(id, total: 100)
        queue.progress(id, done: 90)
        queue.progress(id, done: 10)
        #expect(queue[id]?.state == .transferring(done: 90, total: 100))
        queue.finish(id)
        queue.progress(id, done: 50)
        #expect(queue[id]?.state == .finished)
    }

    @Test func anAlreadyCancelledCommitCannotPublishOrOverwrite() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try Data([7]).write(to: path)
        let destination = try await LocalFileSystem.local.openDownload(path.path)
        try await destination.write([9], 0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await destination.commit(true)
        }
        do { try await task.value; Issue.record("cancelled commit published a file") } catch is CancellationError {}
        #expect(try Data(contentsOf: path) == Data([7]))
    }
}
