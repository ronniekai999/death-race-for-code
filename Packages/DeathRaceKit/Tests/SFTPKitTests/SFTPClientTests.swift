import Testing

@testable import SFTPKit

private func started(_ server: FakeSFTPServer) async throws -> SFTPClient {
    let client = SFTPClient(transport: server)
    try await client.start()
    return client
}

/// Whether `work` finishes at all. A dropped reply leaves its request waiting for good, and a
/// test that waits for good takes the whole run with it — swift-testing's time limit cannot
/// interrupt a continuation that nobody will resume. So this watches from outside and gives
/// up, leaving the stuck task suspended.
private actor Finished {
    private var value = false
    func mark() { value = true }
    var isSet: Bool { value }

    static func within(_ seconds: Double, _ work: @escaping @Sendable () async throws -> Void) async -> Bool {
        let flag = Finished()
        let task = Task {
            try await work()
            await flag.mark()
        }
        for _ in 0..<Int(seconds * 20) {
            if await flag.isSet { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        task.cancel()
        return await flag.isSet
    }
}

@Suite struct SFTPClientTests {
    @Test func theHandshakeNegotiatesVersion3() async throws {
        let client = try await started(FakeSFTPServer())
        #expect(await client.serverVersion == 3)
        await client.shutDown()
    }

    @Test func realPathResolvesDot() async throws {
        let client = try await started(FakeSFTPServer())
        #expect(try await client.realPath(".") == "/home/user")
        await client.shutDown()
    }

    @Test func listReturnsTheDirectoryEntries() async throws {
        let server = FakeSFTPServer(
            files: ["/home/user/a.txt": [1, 2, 3], "/home/user/b.log": []], directories: ["/home/user/sub"])
        let client = try await started(server)
        let entries = try await client.list("/home/user")
        let names = Set(entries.map(\.filename))
        #expect(names.isSuperset(of: [".", "..", "a.txt", "b.log", "sub"]))
        let aFile = try #require(entries.first { $0.filename == "a.txt" })
        #expect(aFile.attributes.size == 3)
        #expect(!aFile.attributes.isDirectory)
        #expect(try #require(entries.first { $0.filename == "sub" }).attributes.isDirectory)
        await client.shutDown()
    }

    @Test func statReportsSizeAndKind() async throws {
        let server = FakeSFTPServer(files: ["/home/user/a.txt": [UInt8](repeating: 7, count: 42)])
        let client = try await started(server)
        let attributes = try await client.stat("/home/user/a.txt")
        #expect(attributes.size == 42)
        #expect(!attributes.isDirectory)
        #expect(try await client.stat("/home/user").isDirectory)
        await client.shutDown()
    }

    @Test func statOfAMissingFileThrowsNoSuchFile() async throws {
        let client = try await started(FakeSFTPServer())
        do {
            _ = try await client.stat("/home/user/nope")
            Issue.record("expected a thrown status")
        } catch let error as SFTPError {
            guard case .status(let code, _) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(code == SFTP.Status.noSuchFile)
        }
        await client.shutDown()
    }

    @Test func uploadThenDownloadRoundTripsAcrossManyChunks() async throws {
        // Larger than one 32 KiB chunk, so the read and write loops run several times.
        let bytes = (0..<70_000).map { UInt8($0 % 251) }
        let client = try await started(FakeSFTPServer())
        try await client.upload("/home/user/big.bin", bytes: bytes)
        #expect(try await client.stat("/home/user/big.bin").size == 70_000)
        #expect(try await client.download("/home/user/big.bin") == bytes)
        await client.shutDown()
    }

    @Test func downloadOfAnEmptyFileIsEmpty() async throws {
        let client = try await started(FakeSFTPServer(files: ["/home/user/empty": []]))
        #expect(try await client.download("/home/user/empty") == [])
        await client.shutDown()
    }

    @Test func makeRenameAndRemove() async throws {
        let client = try await started(FakeSFTPServer(files: ["/home/user/old.txt": [9, 9]]))
        try await client.mkdir("/home/user/new")
        #expect(try await client.stat("/home/user/new").isDirectory)

        try await client.rename(from: "/home/user/old.txt", to: "/home/user/renamed.txt")
        #expect(try await client.stat("/home/user/renamed.txt").size == 2)
        await #expect(throws: SFTPError.self) { try await client.stat("/home/user/old.txt") }

        try await client.remove("/home/user/renamed.txt")
        await #expect(throws: SFTPError.self) { try await client.stat("/home/user/renamed.txt") }

        try await client.rmdir("/home/user/new")
        await #expect(throws: SFTPError.self) { try await client.stat("/home/user/new") }
        await client.shutDown()
    }

    @Test func requestsAfterShutDownThrow() async throws {
        let client = try await started(FakeSFTPServer())
        await client.shutDown()
        await #expect(throws: SFTPError.self) { try await client.realPath(".") }
    }

    @Test func manyConcurrentStatsAreMatchedToTheirReplies() async throws {
        // Pipelining: fire a batch at once and check each reply lands on its own request.
        var files: [String: [UInt8]] = [:]
        for i in 0..<32 { files["/home/user/f\(i)"] = [UInt8](repeating: UInt8(i), count: i) }
        let client = try await started(FakeSFTPServer(files: files))
        try await withThrowingTaskGroup(of: (Int, UInt64?).self) { group in
            for i in 0..<32 {
                group.addTask { (i, try await client.stat("/home/user/f\(i)").size) }
            }
            var seen = 0
            for try await (i, size) in group {
                #expect(size == UInt64(i))
                seen += 1
            }
            #expect(seen == 32)
        }
        await client.shutDown()
    }

    /// A reply that arrives while its request is still in `send`. Sending suspends the client
    /// actor, so the read loop can deliver first; the reply has to wait for the request rather
    /// than be dropped. Against a real sshd a dropped `STATUS` hung a 70 KB upload for good,
    /// and with it `swift test`, until Linux CI's 25-minute timeout.
    @Test func aReplyThatArrivesDuringSendIsNotLost() async throws {
        let size = SFTPClient.chunkSize * 3 + 1  // several chunks each way, and a short last one
        let server = FakeSFTPServer(
            files: ["/home/user/a.txt": [UInt8](repeating: 9, count: size)], answersDuringSend: true)
        let client = try await started(server)
        let finished = await Finished.within(10) {
            // Several round trips, and a transfer of more than one chunk, so the race gets
            // plenty of chances.
            #expect(try await client.realPath(".") == "/home/user")
            #expect(try await client.download("/home/user/a.txt").count == size)
            try await client.upload("/home/user/b.txt", bytes: [UInt8](repeating: 1, count: size))
            #expect(try await client.stat("/home/user/b.txt").size == UInt64(size))
        }
        #expect(finished, "a reply that arrived during send was dropped, so its request never came back")
        await client.shutDown()
    }

    /// SFTP has no unsolicited server packets, and ids are 1, 2, 3 …, so a server can answer
    /// ahead of us. Taking such a reply would let it report an upload's `WRITE` as written
    /// when it threw the bytes away, and let it stream replies into an unbounded dictionary.
    @Test func aReplyToARequestThatWasNeverSentFailsTheSession() async throws {
        let server = FakeSFTPServer(answersAheadOfRequests: true)
        let client = SFTPClient(transport: server)
        try await client.start()
        let finished = await Finished.within(10) {
            // The server's forged STATUS(id: 1, ok) must not be mistaken for this reply.
            await #expect(throws: (any Error).self) { try await client.mkdir("/anything") }
        }
        #expect(finished, "the request never came back")
        await client.shutDown()
    }

    /// A server need never send the `EOF` that ends a READDIR loop. The cap is injected small
    /// so this costs nothing: reaching the real 200,000 would make the test heavy enough to
    /// starve its neighbours under Thread Sanitizer, which is what the limits are a seam for.
    @Test func aDirectoryThatNeverEndsIsCapped() async throws {
        let server = FakeSFTPServer(directories: ["/home/user/endless"], neverEndsReaddir: true)
        let client = SFTPClient(transport: server, limits: SFTPClient.Limits(directoryEntries: 2_000))
        try await client.start()
        let finished = await Finished.within(10) {
            await #expect(throws: (any Error).self) { _ = try await client.list("/home/user/endless") }
        }
        #expect(finished, "the listing never stopped")
        await client.shutDown()
    }

    /// A server may answer a 32 KiB `READ` short, never long: a 16 MiB `DATA` for each chunk
    /// is how a download loop becomes an unbounded one.
    @Test func moreDataThanWasAskedForIsRefused() async throws {
        let server = FakeSFTPServer(
            files: ["/home/user/a.bin": [UInt8](repeating: 3, count: 1_024)], answersReadsTooLong: true)
        let client = try await started(server)
        await #expect(throws: (any Error).self) { _ = try await client.download("/home/user/a.bin") }
        await client.shutDown()
    }
}
