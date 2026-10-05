import IPCKit
import PTYKit
import ScreenProtocol
import SessionKit
import Testing
import VTCore

@testable import SessionIPC

/// A launch with an environment big enough to be realistic, since that is what a spawn
/// carries and what makes a control frame large.
private func sampleLaunch() -> ShellLaunch {
    var environment = ["PATH": "/usr/bin:/bin", "HOME": "/Users/r", "TERM": "xterm-256color"]
    for index in 0..<60 { environment["VAR_\(index)"] = String(repeating: "x", count: 40) }
    return ShellLaunch(
        executable: "/bin/zsh", arguments: ["-zsh", "-l"], environment: environment,
        workingDirectory: "/Users/r/code")
}

private func sampleConfiguration() -> Terminal.Configuration {
    Terminal.Configuration(
        columns: 132, rows: 43, scrollbackLimitBytes: 50 << 20, palette: .legendsNeverDie,
        answersChecksumRequests: true, version: "0.1.0", cellPixelWidth: 9, cellPixelHeight: 20)
}

private func sampleDescription(_ id: UInt64) -> SessionDescription {
    SessionDescription(
        id: SessionID(id), status: .exited(.signaled(signal: 9)), columns: 80, rows: 24,
        shellExecutable: "/bin/zsh", startedAtMilliseconds: 1_728_000_000_000,
        metadata: Array("window=1 tab=2".utf8))
}

private let sampleRegion = TextRegion(
    TextPoint(line: 10, column: 3), TextPoint(line: 2_400, column: 79))

private func everyControlRequest() -> [ControlRequest] {
    [
        .list,
        .spawn(request: 7, launch: sampleLaunch(), configuration: sampleConfiguration(), metadata: [1, 2, 3]),
        .spawn(
            request: 0, launch: ShellLaunch(executable: "/bin/sh", arguments: [], environment: [:]),
            configuration: Terminal.Configuration(), metadata: []),
        .adopt(request: 9, id: SessionID(4)),
        .setMetadata(id: SessionID(4), metadata: Array("where it was".utf8)),
        .end(id: SessionID(4)),
        .handOver,
        .goodbye,
    ]
}

private func everyControlReply() -> [ControlReply] {
    [
        .sessions([]),
        .sessions([sampleDescription(1), sampleDescription(2)]),
        .ready(request: 7, id: SessionID(11), token: Array(repeating: 0xAB, count: SessionWire.tokenSize)),
        .failed(request: 7, reason: .atCapacity, detail: "64 sessions already"),
        .failed(request: 0, reason: .malformed, detail: ""),
        .sessionEnded(id: SessionID(3), status: .exited(.exited(code: 0))),
        .sessionEnded(id: SessionID(3), status: .exited(nil)),
        .sessionEnded(id: SessionID(3), status: .running),
    ]
}

private func everyStreamRequest() -> [StreamRequest] {
    [
        .attach(id: SessionID(5), token: Array(repeating: 1, count: SessionWire.tokenSize), wantsSnapshot: true),
        .input(Array("echo 999\n".utf8), typed: true),
        .input([], typed: false),
        .resize(columns: 132, rows: 43, cellPixelWidth: 9, cellPixelHeight: 20),
        .scroll(by: -40),
        .scroll(by: 40),
        .scrollToBottom,
        .snapshot,
        .focus(true),
        .setBasePalette(.legendsNeverDie),
        .clear(.toStart),
        .clear(.scrollback),
        .queryText(request: 3, region: sampleRegion, generation: 77),
        .queryForeground(request: 4),
        .ack(version: .max),
        .close,
        .detach,
    ]
}

private func everyStreamReply() -> [StreamReply] {
    let process = ForegroundProcess(pid: 4_242, name: "vim", workingDirectory: "/tmp", isShell: false)
    return [
        .attached(columns: 80, rows: 24),
        .refused(.alreadyAttached),
        .delta(Array(repeating: 0x39, count: 5_000)),
        .delta([]),
        .status(.running),
        .text(request: 3, "999 — 𝄞 and a 🎧"),
        .text(request: 3, nil),
        .text(request: 3, ""),
        .foreground(request: 4, process),
        .foreground(request: 4, ForegroundProcess(pid: 1, name: "sh", workingDirectory: nil, isShell: true)),
        .foreground(request: 4, nil),
    ]
}

@Suite("The session wire")
struct SessionWireTests {
    @Test("every control request comes back as it went")
    func controlRequests() throws {
        for message in everyControlRequest() {
            #expect(try ControlRequest.decode(message.encode()) == message)
        }
    }

    @Test("every control reply comes back as it went")
    func controlReplies() throws {
        for message in everyControlReply() {
            #expect(try ControlReply.decode(message.encode()) == message)
        }
    }

    @Test("every session request comes back as it went")
    func streamRequests() throws {
        for message in everyStreamRequest() {
            #expect(try StreamRequest.decode(message.encode()) == message)
        }
    }

    @Test("every session reply comes back as it went")
    func streamReplies() throws {
        for message in everyStreamReply() {
            #expect(try StreamReply.decode(message.encode()) == message)
        }
    }

    /// A whole screen, through the codec it has always used, inside the frame that carries it.
    @Test("a screen rides the wire as DeltaCodec already writes it")
    func aScreen() throws {
        let terminal = Terminal(Terminal.Configuration(columns: 40, rows: 8))
        terminal.feed(Array("\u{1b}[1;31mLegends never die\u{1b}[0m\r\n".utf8))
        var builder = DeltaBuilder()
        let delta = builder.makeDelta(from: terminal, events: terminal.takeEvents())

        let reply = StreamReply.delta(DeltaCodec.encode(delta))
        guard case .delta(let carried) = try StreamReply.decode(reply.encode()) else {
            Issue.record("it did not come back a screen")
            return
        }
        #expect(try DeltaCodec.decode(carried) == delta)
    }

    /// Typed bytes are patient and everything else is urgent. Getting this backwards would
    /// freeze the screen for the length of a paste.
    @Test("only the big things are patient")
    func lanes() {
        for message in everyStreamRequest() {
            if case .input = message {
                #expect(message.lane == .bulk)
            } else {
                #expect(message.lane == .control, "\(message) should not wait behind a paste")
            }
        }
        for message in everyStreamReply() {
            if case .delta = message {
                #expect(message.lane == .bulk)
            } else {
                #expect(message.lane == .control, "\(message) should not wait behind a screen")
            }
        }
    }
}

@Suite("The session wire, given bytes it should not trust")
struct SessionWireDefenceTests {
    /// Every message, cut at every byte. None may decode, none may crash, and none may be
    /// read as something shorter that happens to parse.
    @Test("every truncation fails cleanly")
    func everyTruncation() {
        for bytes in everyControlRequest().map({ $0.encode() }) {
            for length in 0..<bytes.count {
                #expect(throws: SessionWire.Fault.self) { _ = try ControlRequest.decode(Array(bytes[0..<length])) }
            }
        }
        for bytes in everyStreamRequest().map({ $0.encode() }) {
            for length in 0..<bytes.count {
                #expect(throws: SessionWire.Fault.self) { _ = try StreamRequest.decode(Array(bytes[0..<length])) }
            }
        }
        for bytes in everyControlReply().map({ $0.encode() }) {
            for length in 0..<bytes.count {
                #expect(throws: SessionWire.Fault.self) { _ = try ControlReply.decode(Array(bytes[0..<length])) }
            }
        }
        for bytes in everyStreamReply().map({ $0.encode() }) {
            for length in 0..<bytes.count {
                #expect(throws: SessionWire.Fault.self) { _ = try StreamReply.decode(Array(bytes[0..<length])) }
            }
        }
    }

    /// Bytes nobody wrote on purpose. Whatever comes out, nothing may crash, and nothing may
    /// be read past the end of what it was given.
    @Test("corruption never crashes", arguments: 0..<60)
    func corruption(seed: Int) {
        var state = UInt64(seed &* 2_654_435_761 &+ 1)
        func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        let samples =
            everyControlRequest().map { $0.encode() } + everyStreamRequest().map { $0.encode() }
            + everyControlReply().map { $0.encode() } + everyStreamReply().map { $0.encode() }
        for original in samples {
            guard !original.isEmpty else { continue }
            var bytes = original
            for _ in 0..<4 {
                bytes[Int(next() % UInt64(bytes.count))] ^= UInt8(truncatingIfNeeded: next())
            }
            _ = try? ControlRequest.decode(bytes)
            _ = try? ControlReply.decode(bytes)
            _ = try? StreamRequest.decode(bytes)
            _ = try? StreamReply.decode(bytes)
        }
    }

    /// The whole point of `ByteReader.count`: a length nobody could satisfy is refused before
    /// anything is reserved, rather than asking for gigabytes and finding out later.
    @Test("a forged count allocates nothing")
    func forgedCounts() {
        // A spawn whose argument count claims four billion.
        var w = ByteWriter()
        w.u8(0x11)  // spawn
        w.u32(1)  // request
        w.string("/bin/sh")
        w.u32(.max)  // arguments
        #expect(throws: SessionWire.Fault.self) { _ = try ControlRequest.decode(w.bytes) }

        // A listing claiming four billion sessions.
        var listing = ByteWriter()
        listing.u8(0x90)
        listing.u32(.max)
        #expect(throws: SessionWire.Fault.self) { _ = try ControlReply.decode(listing.bytes) }

        // A screen claiming to be eight megabytes that is not there.
        var screen = ByteWriter()
        screen.u8(0xA2)
        screen.u32(8 << 20)
        #expect(throws: SessionWire.Fault.self) { _ = try StreamReply.decode(screen.bytes) }
    }

    /// Reading a region walks from its first line to its last, on the thread that owns the
    /// engine. A span no scrollback could hold would leave that session's shell unable to
    /// answer ever again, so it is refused at the wire rather than attempted.
    @Test("a region spanning more lines than there can be is refused")
    func aForgedRegion() {
        func queryText(startLine: UInt64, endLine: UInt64, startColumn: Int = 0, endColumn: Int = 1) -> [UInt8] {
            var w = ByteWriter()
            w.u8(0x29)
            w.u32(1)
            w.u64(startLine)
            w.i64(startColumn)
            w.u64(endLine)
            w.i64(endColumn)
            w.bool(false)
            w.u64(0)
            return w.bytes
        }
        #expect(throws: SessionWire.Fault.self) {
            _ = try StreamRequest.decode(queryText(startLine: 0, endLine: .max))
        }
        #expect(throws: SessionWire.Fault.self) {
            _ = try StreamRequest.decode(queryText(startLine: 0, endLine: UInt64(SessionWire.longestRegionLines)))
        }
        // One line short of the cap is still a region, however silly.
        #expect(throws: Never.self) {
            _ = try StreamRequest.decode(
                queryText(startLine: 0, endLine: UInt64(SessionWire.longestRegionLines) - 1))
        }
        // Backwards, and a column from nowhere.
        #expect(throws: SessionWire.Fault.self) {
            _ = try StreamRequest.decode(queryText(startLine: 10, endLine: 1))
        }
        #expect(throws: SessionWire.Fault.self) {
            _ = try StreamRequest.decode(queryText(startLine: 0, endLine: 1, startColumn: -1))
        }
        #expect(throws: SessionWire.Fault.self) {
            _ = try StreamRequest.decode(
                queryText(startLine: 0, endLine: 1, endColumn: SessionWire.widestColumn + 1))
        }
    }

    @Test("a terminal no screen could be is refused")
    func impossibleSizes() {
        func resize(_ columns: UInt32, _ rows: UInt32) -> [UInt8] {
            var w = ByteWriter()
            w.u8(0x22)
            w.u32(columns)
            w.u32(rows)
            w.u32(0)
            w.u32(0)
            return w.bytes
        }
        #expect(throws: SessionWire.Fault.self) { _ = try StreamRequest.decode(resize(0, 24)) }
        #expect(throws: SessionWire.Fault.self) { _ = try StreamRequest.decode(resize(80, 0)) }
        #expect(throws: SessionWire.Fault.self) { _ = try StreamRequest.decode(resize(.max, 24)) }
        #expect(throws: SessionWire.Fault.self) { _ = try StreamRequest.decode(resize(80, .max)) }
        #expect(throws: Never.self) { _ = try StreamRequest.decode(resize(1, 1)) }
    }

    @Test("a tag nobody writes is an error, not something skipped")
    func unknownTags() {
        for tag: UInt8 in [0x00, 0x7F, 0xEE, 0xFF] {
            #expect(throws: SessionWire.Fault.self) { _ = try ControlRequest.decode([tag]) }
            #expect(throws: SessionWire.Fault.self) { _ = try ControlReply.decode([tag]) }
            #expect(throws: SessionWire.Fault.self) { _ = try StreamRequest.decode([tag]) }
            #expect(throws: SessionWire.Fault.self) { _ = try StreamReply.decode([tag]) }
        }
        #expect(throws: SessionWire.Fault.self) { _ = try StreamRequest.decode([]) }
    }

    /// A message with something after it is a message that was not understood, even if the
    /// part that was read made sense.
    @Test("a byte too many is refused")
    func trailingBytes() {
        #expect(throws: SessionWire.Fault.self) { _ = try ControlRequest.decode(ControlRequest.list.encode() + [0]) }
        #expect(throws: SessionWire.Fault.self) { _ = try StreamRequest.decode(StreamRequest.close.encode() + [0]) }
    }

    @Test("more metadata than allowed is refused")
    func tooMuchMetadata() {
        var w = ByteWriter()
        w.u8(0x13)  // setMetadata
        w.u64(1)
        w.blob(Array(repeating: 0, count: SessionWire.largestMetadata + 1))
        #expect(throws: SessionWire.Fault.self) { _ = try ControlRequest.decode(w.bytes) }
    }

    @Test("more input in one piece than allowed is refused")
    func tooMuchInput() {
        var w = ByteWriter()
        w.u8(0x21)  // input
        w.bool(true)
        w.blob(Array(repeating: 0x41, count: SessionWire.largestInputChunk + 1))
        #expect(throws: SessionWire.Fault.self) { _ = try StreamRequest.decode(w.bytes) }
    }
}

@Suite("Agreeing on a version")
struct PreambleTests {
    /// A fixed size, and a fixed first nine bytes on every answer, so that every version of
    /// either end can read every other version's preamble. If this changes shape, version
    /// negotiation becomes the thing that cannot negotiate — so the size is pinned here, and
    /// changing it has to be deliberate.
    @Test("a hello is a fixed size and never changes shape")
    func theShape() throws {
        let hello = Preamble.hello(speaks: 1...1, role: .control).encode()
        #expect(hello.count == Preamble.helloSize)
        #expect(Preamble.helloSize == 11)
        #expect(Array(hello[0..<4]) == Array("DRLD".utf8))
        #expect(try Preamble.decode(hello) == .hello(speaks: 1...1, role: .control))
    }

    @Test("every preamble comes back as it went")
    func roundTrip() throws {
        let facts = DaemonFacts(
            startedAtMilliseconds: 99, pid: 4_242, deltaFormat: DeltaCodec.formatVersion, build: "test")
        let messages: [Preamble] = [
            .hello(speaks: 1...1, role: .control),
            .hello(speaks: 2...7, role: .session),
            .welcome(chosen: 3, speaks: 1...4, daemon: facts),
            .incompatible(speaks: 9...9, build: "older"),
        ]
        for message in messages {
            #expect(try Preamble.decode(message.encode()) == message)
        }
    }

    @Test("the highest version both ends speak wins, and no overlap means none")
    func agreeing() {
        #expect(Preamble.agree(1...1, 1...1) == 1)
        #expect(Preamble.agree(1...3, 2...9) == 3)
        #expect(Preamble.agree(2...9, 1...3) == 3)
        #expect(Preamble.agree(1...1, 2...2) == nil)
        #expect(Preamble.agree(5...9, 1...4) == nil)
    }

    @Test("a welcome naming a version it does not itself speak is refused")
    func anImpossibleWelcome() {
        let facts = DaemonFacts(startedAtMilliseconds: 0, pid: 1, deltaFormat: 3, build: "")
        var w = ByteWriter()
        w.bytes.append(contentsOf: Array("DRLD".utf8))
        w.u8(2)
        w.u16(9)  // chosen
        w.u16(1)  // speaks 1...1
        w.u16(1)
        w.u64(facts.startedAtMilliseconds)
        w.u32(UInt32(bitPattern: facts.pid))
        w.u8(facts.deltaFormat)
        w.string(facts.build)
        #expect(throws: SessionWire.Fault.self) { _ = try Preamble.decode(w.bytes) }
    }

    @Test("a connection for nothing the daemon knows about is refused")
    func anUnknownRole() {
        var w = ByteWriter()
        w.bytes.append(contentsOf: Array("DRLD".utf8))
        w.u8(1)
        w.u16(1)
        w.u16(1)
        w.u16(99)
        #expect(throws: SessionWire.Fault.self) { _ = try Preamble.decode(w.bytes) }
    }

    @Test("a version range that runs backwards is refused")
    func backwards() {
        var w = ByteWriter()
        w.bytes.append(contentsOf: Array("DRLD".utf8))
        w.u8(1)
        w.u16(9)
        w.u16(1)
        w.u16(0)
        #expect(throws: SessionWire.Fault.self) { _ = try Preamble.decode(w.bytes) }
    }

    @Test("bytes from something else are not a preamble")
    func notOurs() {
        #expect(throws: SessionWire.Fault.badMagic) { _ = try Preamble.decode(Array("HTTP/1.1".utf8)) }
        #expect(throws: SessionWire.Fault.self) { _ = try Preamble.decode([]) }
        let hello = Preamble.hello(speaks: 1...1, role: .control).encode()
        for length in 0..<hello.count {
            #expect(throws: SessionWire.Fault.self) { _ = try Preamble.decode(Array(hello[0..<length])) }
        }
    }

    /// There is one version today. The test exists so that adding a second has to be a
    /// deliberate change here, with the compatibility it implies thought about.
    @Test("this build speaks exactly one version")
    func whatWeSpeak() {
        #expect(SessionWire.versions == 1...1)
        #expect(DeltaCodec.formatVersion == 3)
    }
}
