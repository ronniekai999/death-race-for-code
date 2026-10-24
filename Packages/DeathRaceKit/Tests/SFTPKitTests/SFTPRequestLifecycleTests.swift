import Testing

@testable import SFTPKit

actor StalledTransport: SFTPTransport {
    enum Operation: Sendable { case handshake, stat, read, write, close, open, opendir }
    let server = FakeSFTPServer(files: ["/home/user/file": [1, 2, 3]])
    let operation: Operation
    let blockSend: Bool
    private var stalled: SFTPPacket?
    private var observer: CheckedContinuation<Void, Never>?
    private var blockedSend: CheckedContinuation<Void, any Error>?

    init(_ operation: Operation, blockSend: Bool = false) {
        self.operation = operation
        self.blockSend = blockSend
    }

    func send(_ frame: [UInt8]) async throws {
        let packet = try SFTPPacket.decode(frame: frame)
        let hold: Bool
        switch (operation, packet) {
        case (.handshake, .initialize), (.stat, .stat), (.read, .read), (.write, .write), (.close, .close),
            (.open, .open), (.opendir, .opendir):
            hold = true
        default: hold = false
        }
        if hold {
            stalled = packet
            observer?.resume()
            observer = nil
            if blockSend { try await withCheckedThrowingContinuation { blockedSend = $0 } }
        } else {
            try await server.send(frame)
        }
    }

    func receive() async throws -> [UInt8] { try await server.receive() }
    func close() async {
        blockedSend?.resume(throwing: SFTPError.transportClosed)
        blockedSend = nil
        await server.close()
    }

    func waitUntilStalled() async {
        if stalled != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func deliverLateReply() async throws {
        if let stalled { try await server.send(stalled.encode()) }
    }
}

@Suite(.timeLimit(.minutes(1))) struct SFTPRequestLifecycleTests {
    @Test(arguments: [StalledTransport.Operation.stat, .read, .write, .close])
    func cancelledRequestsReturnWithoutShuttingDownTheClient(_ operation: StalledTransport.Operation) async throws {
        let transport = StalledTransport(operation)
        let client = SFTPClient(transport: transport)
        try await client.start()
        let handle = try await client.open("/home/user/file", pflags: SFTP.Open.read | SFTP.Open.write)
        let task = Task {
            switch operation {
            case .stat: _ = try await client.stat("/home/user/file")
            case .read: _ = try await client.read(handle, offset: 0, length: 3)
            case .write: try await client.write(handle, offset: 0, data: [4])
            case .close: try await client.close(handle)
            case .handshake, .open, .opendir: break
            }
        }
        await transport.waitUntilStalled()
        // Let the completed transport.send return to the actor before cancelling.
        for _ in 0..<10_000 where await client.sendingRequestCount != 0 { await Task.yield() }
        #expect(await client.sendingRequestCount == 0)
        task.cancel()
        let finished = await Finished.within(2) {
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(finished, "a cancelled request remained suspended")
        try await transport.deliverLateReply()
        #expect(try await client.realPath(".") == "/home/user")
        await client.shutDown()
    }

    /// Stop pressed while a request's frame is still waiting to be written retires that request
    /// alone. A transport writes a frame whole or not at all, so there is no half frame to fear;
    /// treating it as one closed the session, which is what Stop in Maze did whenever any of a
    /// transfer's pipelined requests was still queued — and every action after it failed.
    @Test(arguments: [StalledTransport.Operation.stat, .read, .write])
    func cancellingARequestStillBeingSentKeepsTheSession(_ operation: StalledTransport.Operation) async throws {
        let transport = StalledTransport(operation, blockSend: true)
        let client = SFTPClient(transport: transport)
        try await client.start()
        let handle = try await client.open("/home/user/file", pflags: SFTP.Open.read | SFTP.Open.write)
        let task = Task {
            switch operation {
            case .stat: _ = try await client.stat("/home/user/file")
            case .read: _ = try await client.read(handle, offset: 0, length: 3)
            case .write: try await client.write(handle, offset: 0, data: [4])
            case .handshake, .close, .open, .opendir: break
            }
        }
        await transport.waitUntilStalled()
        for _ in 0..<10_000 where await client.sendingRequestCount == 0 { await Task.yield() }
        #expect(await client.sendingRequestCount == 1, "the request's frame is still being sent")
        task.cancel()
        let finished = await Finished.within(2) {
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(finished, "a cancelled request remained suspended")
        // The frame goes out after all, and its reply is one the client no longer waits for.
        try await transport.deliverLateReply()
        #expect(try await client.realPath(".") == "/home/user")
        await client.shutDown()
    }

    @Test(arguments: [false, true])
    func deadlinesUnblockAReplyOrASend(_ blockSend: Bool) async throws {
        let transport = StalledTransport(.stat, blockSend: blockSend)
        let client = SFTPClient(transport: transport, requestTimeout: .milliseconds(100))
        try await client.start()
        let finished = await Finished.within(2) {
            await #expect(throws: SFTPError.timedOut) { _ = try await client.stat("/home/user/file") }
        }
        #expect(finished)
        await client.shutDown()
    }

    @Test(arguments: [StalledTransport.Operation.open, .opendir], [false, true])
    func abandonedOpensCloseTheirLateHandles(_ operation: StalledTransport.Operation, _ expires: Bool) async throws {
        let transport = StalledTransport(operation)
        // Expiring is what one case checks, so its 250 ms stays; the other's deadline only has to
        // outlast the cancel, and gets the sanitizer's room.
        let client = SFTPClient(
            transport: transport, requestTimeout: expires ? .milliseconds(250) : .milliseconds(patience(5_000)))
        try await client.start()
        let opening = Task {
            if operation == .open {
                return try await client.open("/home/user/file", pflags: SFTP.Open.read)
            }
            return try await client.openDirectory("/home/user")
        }
        await transport.waitUntilStalled()
        for _ in 0..<10_000 where await client.sendingRequestCount != 0 { await Task.yield() }
        #expect(await client.sendingRequestCount == 0)
        if expires {
            await #expect(throws: SFTPError.timedOut) { try await opening.value }
        } else {
            opening.cancel()
            await #expect(throws: CancellationError.self) { try await opening.value }
        }
        try await transport.deliverLateReply()
        // A round trip proves the late HANDLE was read. Its CLOSE must be processed by
        // that same reader, so this also detects a cleanup that deadlocks the read loop.
        let finished = await Finished.within(2) {
            let path = try await client.realPath(".")
            #expect(path == "/home/user")
            for _ in 0..<10_000 where await transport.server.openHandleCount != 0 { await Task.yield() }
            #expect(await transport.server.openHandleCount == 0)
        }
        #expect(finished, "late-handle cleanup blocked the reply reader")
        await client.shutDown()
    }

    @Test func theHandshakeHasADeadline() async {
        let client = SFTPClient(transport: StalledTransport(.handshake), requestTimeout: .milliseconds(100))
        let finished = await Finished.within(2) {
            await #expect(throws: SFTPError.timedOut) { try await client.start() }
        }
        #expect(finished)
        await client.shutDown()
    }

    @Test func exclusiveUploadPreservesAnExistingFile() async throws {
        let client = SFTPClient(transport: FakeSFTPServer(files: ["/home/user/file": [1, 2, 3]]))
        try await client.start()
        await #expect(throws: SFTPError.self) { try await client.upload("/home/user/file", bytes: [9]) }
        #expect(try await client.download("/home/user/file") == [1, 2, 3])
        try await client.upload("/home/user/file", bytes: [9], overwrite: true)
        #expect(try await client.download("/home/user/file") == [9])
        await client.shutDown()
    }
}
