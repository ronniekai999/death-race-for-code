import IPCKit
import PTYKit
import ScreenProtocol
import SessionKit
import VTCore

/// One session's own connection: the ten things `Session` can be told, the two it can be
/// asked, and the acknowledgement that paces its screens.
///
/// A connection a session, rather than one for all of them, because a program that has
/// stopped reading its pseudo-terminal fills its input queue — and on a shared connection the
/// daemon would then have to stop reading at all, which would hold up typing in every other
/// pane. One socket each gets that backpressure from the kernel, per session, for nothing.
public enum StreamRequest: Sendable, Equatable {
    /// The first thing a client says. The token came from the control connection and is good
    /// once.
    case attach(id: SessionID, token: [UInt8], wantsSnapshot: Bool)
    case input([UInt8], typed: Bool)
    case resize(columns: Int, rows: Int, cellPixelWidth: Int, cellPixelHeight: Int)
    case scroll(by: Int)
    case scrollToBottom
    case snapshot
    case focus(Bool)
    case setBasePalette(Palette)
    case clear(Terminal.ClearKind)
    case queryText(request: UInt32, region: TextRegion, generation: UInt64)
    case querySearch(request: UInt32, query: SearchQuery, generation: UInt64)
    case queryForeground(request: UInt32)
    /// Where is the block around this line. The engine owns the scrollback, so it is the
    /// only thing that can answer for a prompt the viewport no longer holds.
    case queryPrompt(request: UInt32, line: UInt64, generation: UInt64)
    /// The client has applied the delta at `version`, so the daemon may take the next one.
    case ack(version: UInt64)
    case close
    case detach

    private enum Tag: UInt8 {
        case attach = 0x20
        case input = 0x21
        case resize = 0x22
        case scroll = 0x23
        case scrollToBottom = 0x24
        case snapshot = 0x25
        case focus = 0x26
        case setBasePalette = 0x27
        case clear = 0x28
        case queryText = 0x29
        case queryForeground = 0x2A
        case querySearch = 0x2F
        case queryPrompt = 0x2E
        case ack = 0x2B
        case close = 0x2C
        case detach = 0x2D
    }

    /// Typed bytes and pastes are patient; everything else is small and urgent, so it goes
    /// first. This is what stops an acknowledgement waiting behind a sixteen-megabyte paste.
    public var lane: FrameWriter.Lane {
        if case .input = self { return .bulk }
        return .control
    }

    public func encode() -> [UInt8] {
        var w = ByteWriter()
        switch self {
        case .attach(let id, let token, let wantsSnapshot):
            w.u8(Tag.attach.rawValue)
            w.u64(id.value)
            w.blob(token)
            w.bool(wantsSnapshot)
        case .input(let bytes, let typed):
            w.u8(Tag.input.rawValue)
            w.bool(typed)
            w.blob(bytes)
        case .resize(let columns, let rows, let cellPixelWidth, let cellPixelHeight):
            w.u8(Tag.resize.rawValue)
            w.u32(UInt32(clamping: columns))
            w.u32(UInt32(clamping: rows))
            w.u32(UInt32(clamping: cellPixelWidth))
            w.u32(UInt32(clamping: cellPixelHeight))
        case .scroll(let lines):
            w.u8(Tag.scroll.rawValue)
            w.i64(lines)
        case .scrollToBottom:
            w.u8(Tag.scrollToBottom.rawValue)
        case .snapshot:
            w.u8(Tag.snapshot.rawValue)
        case .focus(let focused):
            w.u8(Tag.focus.rawValue)
            w.bool(focused)
        case .setBasePalette(let palette):
            w.u8(Tag.setBasePalette.rawValue)
            w.palette(palette)
        case .clear(let kind):
            w.u8(Tag.clear.rawValue)
            w.u8(kind == .toStart ? 0 : 1)
        case .queryText(let request, let region, let generation):
            w.u8(Tag.queryText.rawValue)
            w.u32(request)
            w.region(region)
            w.u64(generation)
        case .querySearch(let request, let query, let generation):
            w.u8(Tag.querySearch.rawValue)
            w.u32(request)
            w.string(query.needle)
            w.bool(query.caseSensitive)
            w.optionalU64(query.startLine)
            w.optionalU64(query.endLine)
            w.u64(generation)
        case .queryForeground(let request):
            w.u8(Tag.queryForeground.rawValue)
            w.u32(request)
        case .queryPrompt(let request, let line, let generation):
            w.u8(Tag.queryPrompt.rawValue)
            w.u32(request)
            w.u64(line)
            w.u64(generation)
        case .ack(let version):
            w.u8(Tag.ack.rawValue)
            w.u64(version)
        case .close:
            w.u8(Tag.close.rawValue)
        case .detach:
            w.u8(Tag.detach.rawValue)
        }
        return w.bytes
    }

    public static func decode(_ bytes: [UInt8]) throws(SessionWire.Fault) -> StreamRequest {
        var r = ByteReader(bytes: bytes)
        guard let tag = Tag(rawValue: try r.u8()) else { throw .invalid("session request") }
        let message: StreamRequest
        switch tag {
        case .attach:
            message = .attach(
                id: try r.sessionID(), token: try r.blob(limit: SessionWire.tokenSize),
                wantsSnapshot: try r.bool())
        case .input:
            let typed = try r.bool()
            message = .input(try r.blob(limit: SessionWire.largestInputChunk), typed: typed)
        case .resize:
            let columns = Int(try r.u32())
            let rows = Int(try r.u32())
            guard columns >= 1, columns <= SessionWire.widestTerminal else { throw .invalid("columns") }
            guard rows >= 1, rows <= SessionWire.tallestTerminal else { throw .invalid("rows") }
            let cellWidth = Int(try r.u32())
            let cellHeight = Int(try r.u32())
            guard cellWidth <= 1_000, cellHeight <= 1_000 else { throw .invalid("cell size") }
            message = .resize(
                columns: columns, rows: rows, cellPixelWidth: cellWidth, cellPixelHeight: cellHeight)
        case .scroll: message = .scroll(by: try r.i64())
        case .scrollToBottom: message = .scrollToBottom
        case .snapshot: message = .snapshot
        case .focus: message = .focus(try r.bool())
        case .setBasePalette: message = .setBasePalette(try r.palette())
        case .clear:
            switch try r.u8() {
            case 0: message = .clear(.toStart)
            case 1: message = .clear(.scrollback)
            default: throw .invalid("what to clear")
            }
        case .queryText:
            message = .queryText(request: try r.u32(), region: try r.region(), generation: try r.u64())
        case .querySearch:
            let request = try r.u32()
            let needle = try r.string()
            guard needle.utf16.count <= SearchQuery.longestNeedle else { throw .invalid("search needle too long") }
            let query = SearchQuery(
                needle, caseSensitive: try r.bool(), startLine: try r.optionalU64(), endLine: try r.optionalU64())
            message = .querySearch(request: request, query: query, generation: try r.u64())
        case .queryForeground: message = .queryForeground(request: try r.u32())
        case .queryPrompt:
            message = .queryPrompt(request: try r.u32(), line: try r.u64(), generation: try r.u64())
        case .ack: message = .ack(version: try r.u64())
        case .close: message = .close
        case .detach: message = .detach
        }
        guard r.isAtEnd else { throw .invalid("trailing bytes") }
        return message
    }
}

public enum StreamReply: Sendable, Equatable {
    case attached(columns: Int, rows: Int)
    case refused(Refusal)
    /// A screen, exactly as `DeltaCodec` writes it. It is not re-encoded here: the format has
    /// been round-tripped in debug builds since Phase 1, and once more would be work for
    /// nothing on the one message that comes sixty times a second.
    case delta([UInt8])
    case status(Session.Status)
    case text(request: UInt32, String?)
    case foreground(request: UInt32, ForegroundProcess?)
    case promptSpan(request: UInt32, PromptSpan?)
    case searchPage(request: UInt32, SearchPage?)

    private enum Tag: UInt8 {
        case attached = 0xA0
        case refused = 0xA1
        case delta = 0xA2
        case status = 0xA3
        case text = 0xA4
        case foreground = 0xA5
        case promptSpan = 0xA6
        case searchPage = 0xA7
    }

    public var lane: FrameWriter.Lane {
        if case .delta = self { return .bulk }
        return .control
    }

    public func encode() -> [UInt8] {
        var w = ByteWriter()
        switch self {
        case .attached(let columns, let rows):
            w.u8(Tag.attached.rawValue)
            w.u32(UInt32(clamping: columns))
            w.u32(UInt32(clamping: rows))
        case .refused(let reason):
            w.u8(Tag.refused.rawValue)
            w.u8(reason.rawValue)
        case .delta(let bytes):
            w.u8(Tag.delta.rawValue)
            w.blob(bytes)
        case .status(let status):
            w.u8(Tag.status.rawValue)
            w.status(status)
        case .text(let request, let text):
            w.u8(Tag.text.rawValue)
            w.u32(request)
            w.optionalString(text)
        case .foreground(let request, let process):
            w.u8(Tag.foreground.rawValue)
            w.u32(request)
            w.foreground(process)
        case .searchPage(let request, let page):
            w.u8(Tag.searchPage.rawValue)
            w.u32(request)
            w.searchPage(page)
        case .promptSpan(let request, let span):
            w.u8(Tag.promptSpan.rawValue)
            w.u32(request)
            w.promptSpan(span)
        }
        return w.bytes
    }

    public static func decode(_ bytes: [UInt8]) throws(SessionWire.Fault) -> StreamReply {
        var r = ByteReader(bytes: bytes)
        guard let tag = Tag(rawValue: try r.u8()) else { throw .invalid("session reply") }
        let message: StreamReply
        switch tag {
        case .attached:
            message = .attached(columns: Int(try r.u32()), rows: Int(try r.u32()))
        case .refused:
            guard let reason = Refusal(rawValue: try r.u8()) else { throw .invalid("refusal") }
            message = .refused(reason)
        case .delta:
            message = .delta(try r.blob(limit: SessionWire.largestSessionFrame))
        case .status: message = .status(try r.status())
        case .text:
            let request = try r.u32()
            let text = try r.optionalString()
            guard text?.utf8.count ?? 0 <= SessionWire.largestTextReply else { throw .invalid("text too long") }
            message = .text(request: request, text)
        case .foreground:
            message = .foreground(request: try r.u32(), try r.foreground())
        case .searchPage:
            message = .searchPage(request: try r.u32(), try r.searchPage())
        case .promptSpan:
            message = .promptSpan(request: try r.u32(), try r.promptSpan())
        }
        guard r.isAtEnd else { throw .invalid("trailing bytes") }
        return message
    }
}
