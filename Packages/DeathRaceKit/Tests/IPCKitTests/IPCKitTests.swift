import Foundation
import Testing

@testable import IPCKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A new private folder with a short path: a socket path must fit in 104 bytes on macOS.
private func shortTemporaryFolder() -> String {
    let path = NSTemporaryDirectory() + "ipc-" + String(UInt32.random(in: .min ... .max), radix: 16)
    try? FileManager.default.createDirectory(
        atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return path
}

@Suite("Frames on a stream")
struct FrameTests {
    @Test("a payload comes back whole")
    func roundTrip() {
        var reader = FrameReader(limit: 1_024)
        let payload: [UInt8] = Array("999".utf8)
        let out = reader.append(Frames.framed(payload))
        #expect(out == [payload])
        #expect(!reader.isBroken)
    }

    /// A stream gives no promises about where it breaks, so the reader is fed one byte at a
    /// time and must still produce exactly the three payloads, in order.
    @Test("it does not matter where the stream is cut")
    func anyBoundary() {
        let payloads: [[UInt8]] = [[], Array("one".utf8), Array(repeating: 0x39, count: 300)]
        let stream = payloads.flatMap { Frames.framed($0) }
        for chunk in [1, 2, 3, 5, 7, 256, stream.count] {
            var reader = FrameReader(limit: 4_096)
            var out: [[UInt8]] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunk, stream.count)
                out += reader.append(Array(stream[offset..<end]))
                offset = end
            }
            #expect(out == payloads, "cut into \(chunk)-byte pieces")
            #expect(!reader.isBroken)
        }
    }

    @Test("a payload at the limit passes and one byte more breaks the reader")
    func theLimit() {
        var atLimit = FrameReader(limit: 64)
        let fits = atLimit.append(Frames.framed(Array(repeating: 1, count: 64)))
        #expect(fits.count == 1)
        #expect(!atLimit.isBroken)

        var past = FrameReader(limit: 64)
        let over = past.append(Frames.framed(Array(repeating: 1, count: 65)))
        #expect(over.isEmpty)
        #expect(past.isBroken)
    }

    /// A forged length must not make the reader wait for bytes nobody will send, or hold the
    /// ones it already has. It gives up for good: the connection is no longer trustworthy.
    @Test("a forged length breaks the reader for good and holds nothing")
    func forgedLength() {
        var reader = FrameReader(limit: 1_024)
        let forged: [UInt8] = [0x7F, 0xFF, 0xFF, 0xFF]
        let nothing = reader.append(forged)
        #expect(nothing.isEmpty)
        #expect(reader.isBroken)
        #expect(reader.bufferedBytes == 0)
        // Even a well-formed frame afterwards is refused.
        let stillNothing = reader.append(Frames.framed([1, 2, 3]))
        #expect(stillNothing.isEmpty)
    }

    /// Payloads before the forged length were already whole, so they are handed over; the
    /// break stops what comes after it, not what came before.
    @Test("payloads before a forged length still arrive")
    func goodBeforeBad() {
        var reader = FrameReader(limit: 1_024)
        let good: [UInt8] = Array("good".utf8)
        let out = reader.append(Frames.framed(good) + [0x7F, 0xFF, 0xFF, 0xFF])
        #expect(out == [good])
        #expect(reader.isBroken)
    }

    @Test("a frame half arrived is held, not handed over")
    func partialFrame() {
        var reader = FrameReader(limit: 1_024)
        let frame = Frames.framed(Array(repeating: 7, count: 100))
        let half = reader.append(Array(frame[0..<50]))
        #expect(half.isEmpty)
        #expect(reader.bufferedBytes == 50)
        let whole = reader.append(Array(frame[50...]))
        #expect(whole.count == 1)
        #expect(reader.bufferedBytes == 0)
    }
}

@Suite("Frames waiting to go out")
struct FrameWriterTests {
    /// Queues outside `#expect`, which makes what it captures immutable.
    private func queue(_ writer: inout FrameWriter, _ payload: [UInt8], _ lane: FrameWriter.Lane) -> Bool {
        writer.queue(payload, lane)
    }

    /// Collects what a writer hands over, from a socket that takes `take` bytes in all and
    /// then blocks — so a frame left half written is the normal case rather than an edge one.
    /// `write` keeps going while the socket accepts, which is why the budget spans the call
    /// rather than each hand-over.
    private func drain(_ writer: inout FrameWriter, take: Int) -> [UInt8] {
        var out: [UInt8] = []
        var budget = take
        _ = writer.write { buffer in
            let count = min(budget, buffer.count)
            guard count > 0 else { return .wouldBlock }
            out += Array(UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
            budget -= count
            return .wrote(count)
        }
        return out
    }

    /// The whole reason for two lanes: a key pressed during a paste must not wait for it.
    @Test("a control frame goes before bulk already waiting")
    func controlFirst() {
        var writer = FrameWriter(largestQueue: 1 << 20)
        #expect(queue(&writer, Array(repeating: 0xBB, count: 500), .bulk))
        #expect(queue(&writer, Array("ack".utf8), .control))
        var reader = FrameReader(limit: 4_096)
        let bytes = drain(&writer, take: 4_096)
        let payloads = reader.append(bytes)
        #expect(payloads.first == Array("ack".utf8))
        #expect(payloads.count == 2)
        #expect(writer.isEmpty)
    }

    /// Bytes of two frames may not interleave, so a frame that has started finishes even if
    /// something urgent is queued behind it.
    @Test("a frame half written is finished before the lanes are looked at again")
    func noInterleaving() {
        var writer = FrameWriter(largestQueue: 1 << 20)
        #expect(queue(&writer, Array(repeating: 0xBB, count: 500), .bulk))
        var collected = drain(&writer, take: 100)
        #expect(queue(&writer, Array("ack".utf8), .control))
        while !writer.isEmpty { collected += drain(&writer, take: 100) }
        var reader = FrameReader(limit: 4_096)
        let payloads = reader.append(collected)
        #expect(payloads.count == 2)
        #expect(payloads.first?.count == 500, "the bulk frame was not cut in half")
        #expect(payloads.last == Array("ack".utf8))
    }

    @Test("it reports what is waiting")
    func whatIsWaiting() {
        var writer = FrameWriter(largestQueue: 1 << 20)
        #expect(writer.isEmpty)
        #expect(writer.bulkIsEmpty)
        #expect(queue(&writer, [1, 2, 3], .control))
        #expect(!writer.isEmpty)
        #expect(writer.bulkIsEmpty, "a control frame is not bulk")
        #expect(writer.queuedBytes == 3 + Frames.headerSize)
        #expect(queue(&writer, [4], .bulk))
        #expect(!writer.bulkIsEmpty)
    }

    /// A half-written bulk frame still counts as bulk, which is what stops a caller taking
    /// another delta while one is still going out.
    @Test("a bulk frame half written still counts as bulk")
    func halfWrittenBulk() {
        var writer = FrameWriter(largestQueue: 1 << 20)
        #expect(queue(&writer, Array(repeating: 0xBB, count: 500), .bulk))
        _ = drain(&writer, take: 100)
        #expect(!writer.bulkIsEmpty)
        while !writer.isEmpty { _ = drain(&writer, take: 500) }
        #expect(writer.bulkIsEmpty)
    }

    @Test("a full queue refuses more rather than growing")
    func theQueueIsBounded() {
        var writer = FrameWriter(largestQueue: 64)
        #expect(queue(&writer, Array(repeating: 0, count: 60 - Frames.headerSize), .bulk))
        #expect(!queue(&writer, [1], .bulk))
        #expect(!queue(&writer, [1], .control), "a full queue refuses urgent frames too")
        _ = drain(&writer, take: 1 << 20)
        #expect(queue(&writer, [1], .control), "and takes them once it has drained")
    }

    @Test("would-block keeps the rest, gone throws the connection away")
    func whatTheSocketSaid() {
        var writer = FrameWriter(largestQueue: 1 << 20)
        #expect(queue(&writer, Array(repeating: 1, count: 10), .bulk))
        let blocked = writer.write { _ in .wouldBlock }
        #expect(blocked)
        #expect(!writer.isEmpty, "nothing was lost")
        let gone = writer.write { _ in .gone }
        #expect(!gone)
    }
}

@Suite("A lock one process at a time holds")
struct ProcessLockTests {
    /// `flock` treats each open of a file independently, in one process as much as across
    /// two, so taking the lock twice here exercises the same kernel path a second daemon
    /// would — without a second process to make the test flaky.
    @Test("a second holder is refused until the first lets go")
    func oneAtATime() {
        let folder = shortTemporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/legendsd.lock"

        let first = ProcessLock.take(at: path)
        #expect(first != nil)
        #expect(ProcessLock.take(at: path) == nil, "two holders at once")
        first?.release()
        let second = ProcessLock.take(at: path)
        #expect(second != nil, "the lock was free again")
        second?.release()
    }

    @Test("releasing twice is not a problem")
    func releaseIsIdempotent() {
        let folder = shortTemporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let lock = ProcessLock.take(at: folder + "/twice.lock")
        lock?.release()
        lock?.release()
        #expect(ProcessLock.take(at: folder + "/twice.lock") != nil)
    }

    /// The file is left behind on purpose: it is the lock on it that means something, not
    /// that it exists. Finding one says nothing about whether a daemon is running.
    @Test("the file outlives the lock")
    func theFileStays() {
        let folder = shortTemporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/left.lock"
        ProcessLock.take(at: path)?.release()
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("a lock in a folder that is not there is refused")
    func nowhereToPutIt() {
        #expect(ProcessLock.take(at: "/nonexistent-\(UInt32.random(in: .min ... .max))/x.lock") == nil)
    }
}

@Suite("The folder a socket sits in")
struct SecureFolderTests {
    @Test("a folder this user owns is accepted and tightened")
    func ours() throws {
        let folder = shortTemporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        _ = chmod(folder, 0o777)
        try secureFolder(folder, what: "test folder")
        var info = stat()
        #expect(stat(folder, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700, "it was tightened, not just checked")
    }

    /// A symlink is how another user would redirect our socket somewhere they can read it,
    /// so the folder is opened with O_NOFOLLOW and a link is refused outright.
    @Test("a symlink is refused")
    func aSymlink() {
        let folder = shortTemporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let real = folder + "/real"
        let link = folder + "/link"
        try? FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        #expect(symlink(real, link) == 0)
        #expect(throws: UnixSocket.Failure.self) { try secureFolder(link, what: "test folder") }
    }

    @Test("a folder that is not there is refused")
    func missing() {
        #expect(throws: UnixSocket.Failure.self) {
            try secureFolder("/nonexistent-\(UInt32.random(in: .min ... .max))", what: "test folder")
        }
    }

    @Test("a file where a folder should be is refused")
    func notAFolder() {
        let folder = shortTemporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let file = folder + "/file"
        _ = FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
        #expect(throws: UnixSocket.Failure.self) { try secureFolder(file, what: "test folder") }
    }
}

@Suite("A Unix socket")
struct UnixSocketTests {
    @Test("nothing listens where nothing has been put")
    func nobodyHome() {
        #expect(!UnixSocket.accepts(shortTemporaryFolder() + "/absent.sock"))
        #expect(UnixSocket.connect(to: shortTemporaryFolder() + "/absent.sock") == nil)
    }

    /// `accepts` is a connect and a hang-up, so the listener is left a connection to accept
    /// and find closed. Asking here, where nothing else accepts, keeps that out of the way.
    @Test("something listening is found")
    func somebodyHome() throws {
        let folder = shortTemporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/live.sock"
        let listener = try UnixSocket.listen(at: path)
        #expect(UnixSocket.accepts(path))
        close(listener)
        #expect(!UnixSocket.accepts(path), "and not once it has stopped")
    }

    @Test("a path too long for a sockaddr is refused rather than truncated")
    func tooLong() {
        #expect(throws: UnixSocket.Failure.pathTooLong(String(repeating: "x", count: 300))) {
            _ = try UnixSocket.listen(at: String(repeating: "x", count: 300))
        }
    }

    @Test("a frame crosses a real socket, and the peer is us")
    func acrossASocket() throws {
        let folder = shortTemporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/talk.sock"

        let listener = try UnixSocket.listen(at: path)
        defer { close(listener) }
        let client = try #require(UnixSocket.connect(to: path))
        defer { close(client) }
        let server = accept(listener, nil, nil)
        #expect(server >= 0)
        defer { close(server) }

        let payload = Array("legends never die".utf8)
        let sent = UnixSocket.writeAll(client, Frames.framed(payload))
        #expect(sent)
        let read = UnixSocket.readFrame(server, limit: 4_096, timeoutMilliseconds: 2_000)
        #expect(read == payload)

        let peers = SystemPeerInspector()
        #expect(peers.credentials(of: server)?.pid == getpid())
        #expect(peerIsThisUser(server))
        #expect(peerIsThisUser(client))
    }

    @Test("a frame past the limit is not read, however well framed")
    func oversizeIsRefused() throws {
        let folder = shortTemporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/big.sock"
        let listener = try UnixSocket.listen(at: path)
        defer { close(listener) }
        let client = try #require(UnixSocket.connect(to: path))
        defer { close(client) }
        let server = accept(listener, nil, nil)
        defer { close(server) }

        let sentBig = UnixSocket.writeAll(client, Frames.framed(Array(repeating: 0, count: 200)))
        #expect(sentBig)
        #expect(UnixSocket.readFrame(server, limit: 100, timeoutMilliseconds: 2_000) == nil)
    }

    @Test("reading gives up when nothing comes")
    func itTimesOut() throws {
        let folder = shortTemporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/quiet.sock"
        let listener = try UnixSocket.listen(at: path)
        defer { close(listener) }
        let client = try #require(UnixSocket.connect(to: path))
        defer { close(client) }
        let server = accept(listener, nil, nil)
        defer { close(server) }
        #expect(UnixSocket.readFrame(server, limit: 4_096, timeoutMilliseconds: 50) == nil)
    }

    @Test("writing to an end that has gone fails rather than raising")
    func theOtherEndWent() throws {
        let folder = shortTemporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/gone.sock"
        let listener = try UnixSocket.listen(at: path)
        defer { close(listener) }
        let client = try #require(UnixSocket.connect(to: path))
        defer { close(client) }
        let server = accept(listener, nil, nil)
        close(server)
        // The first write may land in the socket's buffer; by the second the reset has come.
        _ = UnixSocket.writeAll(client, Frames.framed([1]))
        var failed = false
        for _ in 0..<50 where !failed {
            failed = !UnixSocket.writeAll(client, Frames.framed(Array(repeating: 1, count: 4_096)))
        }
        #expect(failed)
    }
}

@Suite("Tokens")
struct SecretTests {
    @Test("comparing says nothing about where two differ")
    func comparing() {
        #expect(sameBytes([1, 2, 3], [1, 2, 3]))
        #expect(!sameBytes([1, 2, 3], [1, 2, 4]))
        #expect(!sameBytes([1, 2, 3], [1, 2]))
        #expect(sameBytes([], []))
    }

    @Test("a token is the length asked for, and not the last one")
    func tokens() {
        #expect(randomBytes(16).count == 16)
        #expect(randomBytes(0).isEmpty)
        #expect(randomBytes(32) != randomBytes(32))
    }

    @Test("hex is two lower-case digits a byte")
    func hex() {
        #expect(hexText([0x00, 0x0F, 0xA9, 0xFF]) == "000fa9ff")
        #expect(hexText(randomBytes(32)).count == 64)
    }
}
