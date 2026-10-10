import Testing

@testable import SFTPKit

actor StalledTransport: SFTPTransport {
    enum Operation: Sendable { case handshake, stat, read, write, close }
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
        case (.handshake, .initialize), (.stat, .stat), (.read, .read), (.write, .write), (.close, .close): hold = true
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
            case .handshake: break
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
