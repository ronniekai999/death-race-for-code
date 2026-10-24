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
    /// Checks that pipelined upload writes tolerate replies arriving in reverse order and
    /// preserve the file's contents on download.
    @Test func pipelinedWritesCompleteWhenRepliesArriveInReverseOrder() async throws {
        let transport = ReorderingTransport()
        let client = SFTPClient(
            transport: transport, limits: .init(pipelineDepth: 4), requestTimeout: .milliseconds(patience(2_000)))
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

    // MARK: - Staged uploads

    private func source(_ size: Int, stallingFrom stall: UInt64 = .max) -> TransferSource {
        TransferSource(size: UInt64(size)) { offset, length in
            if offset >= stall { try await Task.sleep(for: .seconds(30)) }
            return [UInt8](repeating: 7, count: length)
        }
    }

    /// Waits for a cleanup the client sends from a fresh task after a Stop.
    private func settle(_ server: FakeSFTPServer, until done: @Sendable ([String]) -> Bool) async -> [String] {
        for _ in 0..<2_000 {
            let paths = await server.filePaths
            if done(paths) { return paths }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await server.filePaths
    }

    /// A replace stopped part way leaves the host's file as it was. Written into the target, it
    /// was truncated first: a 2 GB archive stopped at 10% was a 200 MB fragment.
    @Test func aStoppedReplaceLeavesTheOriginal() async throws {
        let server = FakeSFTPServer(files: ["/home/user/site.tar": [1, 2, 3]])
        let client = SFTPClient(transport: server)
        try await client.start()
        let size = SFTPClient.chunkSize * 4
        let upload = Task {
            try await client.upload(
                "/home/user/site.tar", source: source(size, stallingFrom: UInt64(SFTPClient.chunkSize)),
                overwrite: true, progress: { _, _ in })
        }
        for _ in 0..<2_000 where await server.filePaths.count < 2 { try await Task.sleep(for: .milliseconds(1)) }
        upload.cancel()
        await #expect(throws: CancellationError.self) { try await upload.value }
        #expect(await server.contents(of: "/home/user/site.tar") == [1, 2, 3])
        let left = await settle(server) { $0 == ["/home/user/site.tar"] }
        #expect(left == ["/home/user/site.tar"], "the staged file was left behind")
        await client.shutDown()
    }

    /// Finished, it replaces the file whole — with OpenSSH's replacing rename, or without one
    /// by taking the old file away first.
    @Test(arguments: [true, false])
    func aFinishedReplaceSwapsTheFileIn(_ serverHasPosixRename: Bool) async throws {
        let server = FakeSFTPServer(
            files: ["/home/user/site.tar": [1, 2, 3]],
            extensions: serverHasPosixRename ? [SFTP.posixRename: "1"] : [:])
        let client = SFTPClient(transport: server)
        try await client.start()
        try await client.upload("/home/user/site.tar", source: source(10), overwrite: true, progress: { _, _ in })
        #expect(await server.contents(of: "/home/user/site.tar") == [UInt8](repeating: 7, count: 10))
        #expect(await server.filePaths == ["/home/user/site.tar"])
        await client.shutDown()
    }

    /// Not replacing, the rename is the check: a name that came into being since is refused,
    /// and nothing of the upload is left beside it.
    @Test func aNewFileNeverReplacesOneThatAppeared() async throws {
        let server = FakeSFTPServer(files: ["/home/user/notes.md": [1]])
        let client = SFTPClient(transport: server)
        try await client.start()
        await #expect(throws: SFTPError.self) {
            try await client.upload("/home/user/notes.md", source: source(4), overwrite: false, progress: { _, _ in })
        }
        #expect(await server.contents(of: "/home/user/notes.md") == [1])
        #expect(await server.filePaths == ["/home/user/notes.md"])
        await client.shutDown()
    }

    /// The hidden name stays a usable one however long the file's is.
    @Test func theStagingNameStaysWithinAFileNamesLength() {
        let long = String(repeating: "é", count: 200) + ".txt"
        let staging = SFTPClient.stagingPath(for: "/home/user/" + long)
        #expect(Listing.parent(of: staging) == "/home/user")
        #expect(Listing.name(of: staging).utf8.count <= 255)
        #expect(Listing.name(of: staging).hasPrefix("."))
    }

    /// Once the connection has gone every request fails, and the window says so by being asked:
    /// Open in Maze then opens the host's files again rather than bringing back a dead window.
    @Test func aClosedConnectionSaysItIsNotConnected() async throws {
        let server = FakeSFTPServer()
        let client = SFTPClient(transport: server)
        #expect(await client.isConnected() == false, "nothing has been opened yet")
        try await client.start()
        #expect(await client.isConnected())
        await server.close()
        for _ in 0..<2_000 where await client.isConnected() { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await client.isConnected() == false)
    }

    // MARK: - Permissions

    /// A script uploaded arrives executable: the file is created with the local file's bits,
    /// as OpenSSH's sftp sends them, where it used to get the server's default.
    @Test func anUploadKeepsTheFilesPermissions() async throws {
        let server = FakeSFTPServer()
        let client = SFTPClient(transport: server)
        try await client.start()
        let script = TransferSource(size: 3, permissions: 0o755) { _, length in [UInt8](repeating: 1, count: length) }
        try await client.upload("/home/user/deploy.sh", source: script, overwrite: false, progress: { _, _ in })
        #expect(await server.createdPermissions["/home/user/deploy.sh"] == 0o755)
        await client.shutDown()
    }

    /// And one downloaded stays executable, masked as a new file here would be. The staged
    /// file was created 0600 and published as that.
    @Test func aDownloadKeepsTheFilesPermissions() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let staged = try LocalDownload(path: path.path)
        try staged.write([1], offset: 0)
        try staged.setPermissions(0o100_755)
        try staged.commit(overwrite: false)
        let mode = try #require(
            try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)
        let mask = umask(0o022)
        umask(mask)
        #expect(UInt32(mode.intValue) == 0o755 & ~UInt32(mask))
    }

    /// The client asks the destination to take the remote file's bits before it publishes.
    @Test func aDownloadHandsOnTheRemotePermissions() async throws {
        let server = FakeSFTPServer(files: ["/home/user/run.sh": [1, 2]])
        let client = SFTPClient(transport: server)
        try await client.start()
        let seen = SeenMode()
        let destination = TransferDestination(
            write: { _, _ in }, commit: { _ in }, permissions: { mode in await seen.take(mode) })
        try await client.download("/home/user/run.sh", destination: destination, progress: { _, _ in })
        #expect(await seen.mode == 0o100_644)
        await client.shutDown()
    }
}

private actor SeenMode {
    private(set) var mode: UInt32?
    func take(_ mode: UInt32) { self.mode = mode }
}
