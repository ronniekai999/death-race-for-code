import IPCKit
import PTYKit
import ScreenProtocol
import SessionKit
import VTCore

/// What the app and `legendsd` say to each other.
///
/// Frames are `IPCKit.Frames`; payloads are `ByteWriter`/`ByteReader`, the same little-endian
/// bytes and the same strict decoding as `DeltaCodec` — every count checked against the bytes
/// that remain before anything is allocated. Screens are not re-encoded here at all: a delta
/// travels as `DeltaCodec` already writes it, which debug builds have been round-tripping
/// through since Phase 1.
///
/// Everything a decoder reads came from another process, so every number has a bound and
/// anything outside it drops the connection rather than being clamped quietly. A daemon that
/// trusted its client would hand a bad one the means to wedge a session or exhaust memory.
public enum SessionWire {
    /// The versions this build can speak. Both ends send their range and the higher of the
    /// two lowest wins; no overlap means they do not talk at all.
    ///
    /// There is one version today, and the no-overlap path is built and tested anyway: an app
    /// update meeting the daemon an older one left running is the single failure that could
    /// cost someone their sessions, and it is not the kind of path to write once it bites.
    public static let versions: ClosedRange<UInt16> = 1...1

    /// A spawn carries a whole environment, which on a developer's Mac is not small.
    public static let largestControlFrame = 256 * 1024
    /// A snapshot of a large window with its styles and link tables.
    public static let largestSessionFrame = 8 * 1024 * 1024
    /// Input goes in pieces this size, so a paste cannot hold up an acknowledgement.
    public static let largestInputChunk = 64 * 1024
    /// What the app may ask the daemon to remember about where a session belonged.
    public static let largestMetadata = 4 * 1024
    public static let largestArguments = 1_024
    public static let largestEnvironment = 4_096
    public static let largestTextReply = largestSessionFrame - 1_024
    public static let widestTerminal = 2_000
    public static let tallestTerminal = 1_000
    public static let largestScrollback = 512 * 1024 * 1024
    /// Columns far enough out to be nothing but a forgery.
    public static let widestColumn = 1_000_000
    /// An attach token: single use, and short-lived.
    public static let tokenSize = 16

    /// Decoding says what was wrong the way `DeltaCodec` does, so one kind of fault covers
    /// both halves of the wire.
    public typealias Fault = DeltaCodec.DecodeError
}

/// What a daemon says about itself when it answers.
public struct DaemonFacts: Sendable, Equatable {
    public var startedAtMilliseconds: UInt64
    public var pid: Int32
    /// `DeltaCodec.formatVersion`, carried so a mismatch can be named in a log rather than
    /// found as a decoding failure. It is pinned by the protocol version, never negotiated
    /// on its own.
    public var deltaFormat: UInt8
    public var build: String

    public init(startedAtMilliseconds: UInt64, pid: Int32, deltaFormat: UInt8, build: String) {
        self.startedAtMilliseconds = startedAtMilliseconds
        self.pid = pid
        self.deltaFormat = deltaFormat
        self.build = build
    }
}

/// The first thing each end says, and the one message whose shape must never change.
///
/// A client's hello is `helloSize` bytes and every answer starts with the same fixed-width
/// nine — magic, kind, and the range it speaks. So every version of either end can read every
/// other version's preamble, which is what stops version negotiation from being the thing
/// that cannot negotiate.
/// What a connection is for. Both kinds shake hands the same way, so the daemon has to be
/// told which it has before the first message after that means anything.
public enum Role: UInt16, Sendable, Equatable {
    /// The one connection an app keeps: what sessions there are, and starting or ending them.
    case control = 0
    /// One session's own, which carries its screens.
    case session = 1
}

public enum Preamble: Sendable, Equatable {
    case hello(speaks: ClosedRange<UInt16>, role: Role)
    case welcome(chosen: UInt16, speaks: ClosedRange<UInt16>, daemon: DaemonFacts)
    case incompatible(speaks: ClosedRange<UInt16>, build: String)

    static let magic: [UInt8] = Array("DRLD".utf8)
    /// Four of magic, one of kind, two each of lowest, highest, and what it is for.
    public static let helloSize = 11

    private enum Kind: UInt8 {
        case hello = 1
        case welcome = 2
        case incompatible = 3
    }

    public func encode() -> [UInt8] {
        var w = ByteWriter()
        w.bytes.append(contentsOf: Self.magic)
        switch self {
        case .hello(let speaks, let role):
            w.u8(Kind.hello.rawValue)
            w.u16(speaks.lowerBound)
            w.u16(speaks.upperBound)
            w.u16(role.rawValue)
        case .welcome(let chosen, let speaks, let daemon):
            w.u8(Kind.welcome.rawValue)
            w.u16(chosen)
            w.u16(speaks.lowerBound)
            w.u16(speaks.upperBound)
            w.u64(daemon.startedAtMilliseconds)
            w.u32(UInt32(bitPattern: daemon.pid))
            w.u8(daemon.deltaFormat)
            w.string(daemon.build)
        case .incompatible(let speaks, let build):
            w.u8(Kind.incompatible.rawValue)
            w.u16(speaks.lowerBound)
            w.u16(speaks.upperBound)
            w.string(build)
        }
        return w.bytes
    }

    public static func decode(_ bytes: [UInt8]) throws(SessionWire.Fault) -> Preamble {
        var r = ByteReader(bytes: bytes)
        guard try r.take(4) == magic else { throw .badMagic }
        guard let kind = Kind(rawValue: try r.u8()) else { throw .invalid("preamble kind") }
        switch kind {
        case .hello:
            let speaks = try r.versions()
            guard let role = Role(rawValue: try r.u16()) else { throw .invalid("what the connection is for") }
            return .hello(speaks: speaks, role: role)
        case .welcome:
            let chosen = try r.u16()
            let speaks = try r.versions()
            let daemon = DaemonFacts(
                startedAtMilliseconds: try r.u64(), pid: Int32(bitPattern: try r.u32()),
                deltaFormat: try r.u8(), build: try r.string())
            guard speaks.contains(chosen) else { throw .invalid("a version it does not speak") }
            return .welcome(chosen: chosen, speaks: speaks, daemon: daemon)
        case .incompatible:
            return .incompatible(speaks: try r.versions(), build: try r.string())
        }
    }

    /// The version two ends settle on, or nil when they have none in common.
    public static func agree(_ ours: ClosedRange<UInt16>, _ theirs: ClosedRange<UInt16>) -> UInt16? {
        let top = min(ours.upperBound, theirs.upperBound)
        let bottom = max(ours.lowerBound, theirs.lowerBound)
        return bottom <= top ? top : nil
    }
}

// MARK: - The pieces every message is built from

extension ByteWriter {
    mutating func i64(_ v: Int) {
        u64(UInt64(bitPattern: Int64(v)))
    }

    mutating func blob(_ bytes: [UInt8]) {
        u32(UInt32(bytes.count))
        self.bytes.append(contentsOf: bytes)
    }

    mutating func optionalString(_ s: String?) {
        bool(s != nil)
        if let s { string(s) }
    }

    mutating func launch(_ l: ShellLaunch) {
        string(l.executable)
        u32(UInt32(l.arguments.count))
        for argument in l.arguments { string(argument) }
        // Sorted, so what crosses the wire is what `ChildProcess.spawn` would have built.
        let environment = l.environment.sorted { $0.key < $1.key }
        u32(UInt32(environment.count))
        for (key, value) in environment {
            string(key)
            string(value)
        }
        optionalString(l.workingDirectory)
    }

    mutating func configuration(_ c: Terminal.Configuration) {
        u32(UInt32(clamping: c.columns))
        u32(UInt32(clamping: c.rows))
        u64(UInt64(clamping: c.scrollbackLimitBytes))
        palette(c.palette)
        bool(c.answersChecksumRequests)
        string(c.version)
        u32(UInt32(clamping: c.cellPixelWidth))
        u32(UInt32(clamping: c.cellPixelHeight))
    }

    mutating func status(_ s: Session.Status) {
        switch s {
        case .running:
            u8(0)
            u32(0)
        case .exited(let how):
            switch how {
            case nil:
                u8(1)
                u32(0)
            case .exited(let code):
                u8(2)
                u32(UInt32(bitPattern: code))
            case .signaled(let signal):
                u8(3)
                u32(UInt32(bitPattern: signal))
            }
        }
    }

    mutating func region(_ r: TextRegion) {
        u64(r.start.line)
        i64(r.start.column)
        u64(r.end.line)
        i64(r.end.column)
        bool(r.isRectangular)
    }

    mutating func foreground(_ f: ForegroundProcess?) {
        bool(f != nil)
        guard let f else { return }
        u32(UInt32(bitPattern: f.pid))
        string(f.name)
        optionalString(f.workingDirectory)
        bool(f.isShell)
    }

    mutating func session(_ d: SessionDescription) {
        u64(d.id.value)
        status(d.status)
        u32(UInt32(clamping: d.columns))
        u32(UInt32(clamping: d.rows))
        string(d.shellExecutable)
        u64(d.startedAtMilliseconds)
        blob(d.metadata)
    }
}

extension ByteReader {
    mutating func versions() throws(SessionWire.Fault) -> ClosedRange<UInt16> {
        let lowest = try u16()
        let highest = try u16()
        guard lowest <= highest else { throw .invalid("a version range that runs backwards") }
        return lowest...highest
    }

    mutating func i64() throws(SessionWire.Fault) -> Int {
        Int(Int64(bitPattern: try u64()))
    }

    mutating func blob(limit: Int) throws(SessionWire.Fault) -> [UInt8] {
        let n = try count(elementSize: 1)
        guard n <= limit else { throw .invalid("more bytes than allowed") }
        return try take(n)
    }

    mutating func optionalString() throws(SessionWire.Fault) -> String? {
        try bool() ? try string() : nil
    }

    mutating func sessionID() throws(SessionWire.Fault) -> SessionID {
        SessionID(try u64())
    }

    mutating func launch() throws(SessionWire.Fault) -> ShellLaunch {
        let executable = try string()
        // Each argument costs at least its own four-byte length, so `count` already refuses a
        // forged number far larger than the bytes left; the limit is about what is sensible.
        let argumentCount = try count(elementSize: 4)
        guard argumentCount <= SessionWire.largestArguments else { throw .invalid("too many arguments") }
        var arguments: [String] = []
        arguments.reserveCapacity(argumentCount)
        for _ in 0..<argumentCount { arguments.append(try string()) }

        let entries = try count(elementSize: 8)
        guard entries <= SessionWire.largestEnvironment else { throw .invalid("too many environment entries") }
        var environment: [String: String] = [:]
        environment.reserveCapacity(entries)
        for _ in 0..<entries {
            let key = try string()
            environment[key] = try string()
        }
        return ShellLaunch(
            executable: executable, arguments: arguments, environment: environment,
            workingDirectory: try optionalString())
    }

    mutating func configuration() throws(SessionWire.Fault) -> Terminal.Configuration {
        let columns = Int(try u32())
        let rows = Int(try u32())
        guard columns >= 1, columns <= SessionWire.widestTerminal else { throw .invalid("columns") }
        guard rows >= 1, rows <= SessionWire.tallestTerminal else { throw .invalid("rows") }
        let scrollback = Int(clamping: try u64())
        guard scrollback >= 0, scrollback <= SessionWire.largestScrollback else { throw .invalid("scrollback") }
        let palette = try palette()
        let answers = try bool()
        let version = try string()
        let cellWidth = Int(try u32())
        let cellHeight = Int(try u32())
        guard cellWidth <= 1_000, cellHeight <= 1_000 else { throw .invalid("cell size") }
        return Terminal.Configuration(
            columns: columns, rows: rows, scrollbackLimitBytes: scrollback, palette: palette,
            answersChecksumRequests: answers, version: version, cellPixelWidth: cellWidth,
            cellPixelHeight: cellHeight)
    }

    mutating func status() throws(SessionWire.Fault) -> Session.Status {
        let kind = try u8()
        let value = Int32(bitPattern: try u32())
        switch kind {
        case 0: return .running
        case 1: return .exited(nil)
        case 2: return .exited(.exited(code: value))
        case 3: return .exited(.signaled(signal: value))
        default: throw .invalid("status")
        }
    }

    mutating func region() throws(SessionWire.Fault) -> TextRegion {
        let startLine = try u64()
        let startColumn = try i64()
        let endLine = try u64()
        let endColumn = try i64()
        let rectangular = try bool()
        // A region's line numbers come from another process. Reading one is a walk from the
        // first line to the last on the thread that owns the engine, so a span ending at
        // `UInt64.max` would leave that session's shell unable to answer ever again.
        guard endLine >= startLine, endLine - startLine < UInt64(SessionWire.longestRegionLines) else {
            throw .invalid("a region spanning more lines than there can be")
        }
        for column in [startColumn, endColumn] {
            guard column >= 0, column <= SessionWire.widestColumn else { throw .invalid("column") }
        }
        return TextRegion(
            TextPoint(line: startLine, column: startColumn), TextPoint(line: endLine, column: endColumn),
            rectangular: rectangular)
    }

    mutating func foreground() throws(SessionWire.Fault) -> ForegroundProcess? {
        guard try bool() else { return nil }
        return ForegroundProcess(
            pid: Int32(bitPattern: try u32()), name: try string(), workingDirectory: try optionalString(),
            isShell: try bool())
    }

    mutating func session() throws(SessionWire.Fault) -> SessionDescription {
        SessionDescription(
            id: try sessionID(), status: try status(), columns: Int(try u32()), rows: Int(try u32()),
            shellExecutable: try string(), startedAtMilliseconds: try u64(),
            metadata: try blob(limit: SessionWire.largestMetadata))
    }
}

extension SessionWire {
    /// The most lines one region may span, which is `TextExtractor`'s own cap.
    public static let longestRegionLines = TextExtractor.longestRegion
}
