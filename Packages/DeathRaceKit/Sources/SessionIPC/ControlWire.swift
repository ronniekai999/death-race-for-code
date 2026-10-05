import IPCKit
import PTYKit
import ScreenProtocol
import SessionKit
import VTCore

/// Why the daemon would not do something.
public enum Refusal: UInt8, Error, Sendable, Equatable {
    case atCapacity = 1
    case unknownSession = 2
    /// Another client is watching it. Taking a session from under someone is never implicit.
    case alreadyAttached = 3
    case shellWouldNotStart = 4
    /// A newer app has asked this daemon to finish: it starts nothing more.
    case handingOver = 5
    case malformed = 6
}

/// The one connection an app keeps for as long as it runs: what sessions there are, and
/// starting, taking up or ending them. Screens never come down it.
public enum ControlRequest: Sendable, Equatable {
    case list
    case spawn(request: UInt32, launch: ShellLaunch, configuration: Terminal.Configuration, metadata: [UInt8])
    case adopt(request: UInt32, id: SessionID)
    /// Where a session belongs, for putting it back in a window after a relaunch. The daemon
    /// stores these bytes and never looks inside them.
    case setMetadata(id: SessionID, metadata: [UInt8])
    /// Ends a session this client is not watching.
    case end(id: SessionID)
    /// Start nothing more, and finish when the last session does. What a newer app says to
    /// the daemon an older one left running, instead of killing it.
    case handOver
    case goodbye

    private enum Tag: UInt8 {
        case list = 0x10
        case spawn = 0x11
        case adopt = 0x12
        case setMetadata = 0x13
        case end = 0x14
        case handOver = 0x15
        case goodbye = 0x16
    }

    public func encode() -> [UInt8] {
        var w = ByteWriter()
        switch self {
        case .list:
            w.u8(Tag.list.rawValue)
        case .spawn(let request, let launch, let configuration, let metadata):
            w.u8(Tag.spawn.rawValue)
            w.u32(request)
            w.launch(launch)
            w.configuration(configuration)
            w.blob(metadata)
        case .adopt(let request, let id):
            w.u8(Tag.adopt.rawValue)
            w.u32(request)
            w.u64(id.value)
        case .setMetadata(let id, let metadata):
            w.u8(Tag.setMetadata.rawValue)
            w.u64(id.value)
            w.blob(metadata)
        case .end(let id):
            w.u8(Tag.end.rawValue)
            w.u64(id.value)
        case .handOver:
            w.u8(Tag.handOver.rawValue)
        case .goodbye:
            w.u8(Tag.goodbye.rawValue)
        }
        return w.bytes
    }

    public static func decode(_ bytes: [UInt8]) throws(SessionWire.Fault) -> ControlRequest {
        var r = ByteReader(bytes: bytes)
        guard let tag = Tag(rawValue: try r.u8()) else { throw .invalid("control request") }
        let message: ControlRequest
        switch tag {
        case .list: message = .list
        case .spawn:
            message = .spawn(
                request: try r.u32(), launch: try r.launch(), configuration: try r.configuration(),
                metadata: try r.blob(limit: SessionWire.largestMetadata))
        case .adopt: message = .adopt(request: try r.u32(), id: try r.sessionID())
        case .setMetadata:
            message = .setMetadata(id: try r.sessionID(), metadata: try r.blob(limit: SessionWire.largestMetadata))
        case .end: message = .end(id: try r.sessionID())
        case .handOver: message = .handOver
        case .goodbye: message = .goodbye
        }
        guard r.isAtEnd else { throw .invalid("trailing bytes") }
        return message
    }
}

public enum ControlReply: Sendable, Equatable {
    case sessions([SessionDescription])
    /// A session is started, or taken up, and `token` opens its own connection. Single use.
    case ready(request: UInt32, id: SessionID, token: [UInt8])
    case failed(request: UInt32, reason: Refusal, detail: String)
    /// Unasked for: a session's shell ended, so a tab nobody has taken up still learns how.
    case sessionEnded(id: SessionID, status: Session.Status)

    private enum Tag: UInt8 {
        case sessions = 0x90
        case ready = 0x91
        case failed = 0x93
        case sessionEnded = 0x94
    }

    public func encode() -> [UInt8] {
        var w = ByteWriter()
        switch self {
        case .sessions(let list):
            w.u8(Tag.sessions.rawValue)
            w.u32(UInt32(list.count))
            for session in list { w.session(session) }
        case .ready(let request, let id, let token):
            w.u8(Tag.ready.rawValue)
            w.u32(request)
            w.u64(id.value)
            w.blob(token)
        case .failed(let request, let reason, let detail):
            w.u8(Tag.failed.rawValue)
            w.u32(request)
            w.u8(reason.rawValue)
            w.string(detail)
        case .sessionEnded(let id, let status):
            w.u8(Tag.sessionEnded.rawValue)
            w.u64(id.value)
            w.status(status)
        }
        return w.bytes
    }

    public static func decode(_ bytes: [UInt8]) throws(SessionWire.Fault) -> ControlReply {
        var r = ByteReader(bytes: bytes)
        guard let tag = Tag(rawValue: try r.u8()) else { throw .invalid("control reply") }
        let message: ControlReply
        switch tag {
        case .sessions:
            // Every description carries at least an id, a status and five lengths.
            let n = try r.count(elementSize: 29)
            var list: [SessionDescription] = []
            list.reserveCapacity(n)
            for _ in 0..<n { list.append(try r.session()) }
            message = .sessions(list)
        case .ready:
            message = .ready(
                request: try r.u32(), id: try r.sessionID(), token: try r.blob(limit: SessionWire.tokenSize))
        case .failed:
            let request = try r.u32()
            guard let reason = Refusal(rawValue: try r.u8()) else { throw .invalid("refusal") }
            message = .failed(request: request, reason: reason, detail: try r.string())
        case .sessionEnded:
            message = .sessionEnded(id: try r.sessionID(), status: try r.status())
        }
        guard r.isAtEnd else { throw .invalid("trailing bytes") }
        return message
    }
}
