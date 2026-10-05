/// The SFTP version 3 wire format (draft-ietf-secsh-filexfer-02), which Maze speaks itself
/// over a host's existing ssh connection. One packet is `uint32 length` + `byte type` + a
/// payload of big-endian integers and `uint32`-length-prefixed byte strings.
///
/// Big-endian (SSH network order) and strict: like `ScreenProtocol/DeltaCodec`, every length
/// is checked against the bytes that remain before anything is allocated, so a hostile or
/// corrupt server cannot make the client over-allocate or crash. Trailing bytes inside a
/// packet are ignored rather than rejected, because the protocol lets a server append
/// extension fields (notably on `VERSION`) we don't model.

/// Everything that can go wrong decoding a packet or talking to the server.
public enum SFTPError: Error, Equatable, Sendable {
    /// The packet ended before a field it promised.
    case truncated
    /// A field held something the format doesn't allow.
    case invalid(String)
    /// A packet type we don't implement.
    case unknownPacket(UInt8)
    /// A reply of the wrong kind for the request (e.g. DATA where a HANDLE was due).
    case unexpectedReply(String)
    /// The server answered a request with an error status.
    case status(code: UInt32, message: String)
    /// The ssh transport closed before the reply arrived.
    case transportClosed
    /// A reply didn't arrive in time.
    case timedOut
}

/// SFTP v3 constants: the version, packet type tags, open flags, status codes and attribute
/// flags. Kept together so the codec and the client read the same numbers.
public enum SFTP {
    public static let version: UInt32 = 3

    /// The most entries one `NAME` reply may carry. OpenSSH sends about a hundred per
    /// `READDIR`, so this is generous; it exists because the length check alone lets a single
    /// legal frame declare over a million minimal entries.
    public static let maxNameEntries = 65_536
    /// The most of a `STATUS` message to keep. The rest is dropped rather than carried into a
    /// sentence on screen, a log line and a transfer row that is kept until you clear it.
    public static let maxStatusMessage = 512

    /// Packet type tags.
    public enum Kind {
        public static let initialize: UInt8 = 1
        public static let version: UInt8 = 2
        public static let open: UInt8 = 3
        public static let close: UInt8 = 4
        public static let read: UInt8 = 5
        public static let write: UInt8 = 6
        public static let lstat: UInt8 = 7
        public static let fstat: UInt8 = 8
        public static let setstat: UInt8 = 9
        public static let fsetstat: UInt8 = 10
        public static let opendir: UInt8 = 11
        public static let readdir: UInt8 = 12
        public static let remove: UInt8 = 13
        public static let mkdir: UInt8 = 14
        public static let rmdir: UInt8 = 15
        public static let realpath: UInt8 = 16
        public static let stat: UInt8 = 17
        public static let rename: UInt8 = 18
        public static let status: UInt8 = 101
        public static let handle: UInt8 = 102
        public static let data: UInt8 = 103
        public static let name: UInt8 = 104
        public static let attrs: UInt8 = 105
    }

    /// `OPEN` flags (`pflags`).
    public enum Open {
        public static let read: UInt32 = 0x0000_0001
        public static let write: UInt32 = 0x0000_0002
        public static let append: UInt32 = 0x0000_0004
        public static let create: UInt32 = 0x0000_0008
        public static let truncate: UInt32 = 0x0000_0010
        public static let exclusive: UInt32 = 0x0000_0020
    }

    /// `STATUS` codes.
    public enum Status {
        public static let ok: UInt32 = 0
        public static let eof: UInt32 = 1
        public static let noSuchFile: UInt32 = 2
        public static let permissionDenied: UInt32 = 3
        public static let failure: UInt32 = 4
        public static let badMessage: UInt32 = 5
        public static let noConnection: UInt32 = 6
        public static let connectionLost: UInt32 = 7
        public static let opUnsupported: UInt32 = 8
    }

    /// `ATTRS` flag bits.
    enum Attr {
        static let size: UInt32 = 0x0000_0001
        static let uidgid: UInt32 = 0x0000_0002
        static let permissions: UInt32 = 0x0000_0004
        static let acmodtime: UInt32 = 0x0000_0008
        static let extended: UInt32 = 0x8000_0000
    }
}

/// A file's attributes, as much of them as a v3 server sends. Every field is optional because
/// the wire carries only the ones whose flag is set. Owner (uid+gid) and times (atime+mtime)
/// are paired because their flags cover both at once, so the format can't carry one without
/// the other.
public struct SFTPAttributes: Equatable, Sendable {
    public var size: UInt64?
    public var owner: Owner?
    public var permissions: UInt32?
    public var times: Times?

    public struct Owner: Equatable, Sendable {
        public var uid: UInt32
        public var gid: UInt32
        public init(uid: UInt32, gid: UInt32) {
            self.uid = uid
            self.gid = gid
        }
    }

    public struct Times: Equatable, Sendable {
        public var accessed: UInt32
        public var modified: UInt32
        public init(accessed: UInt32, modified: UInt32) {
            self.accessed = accessed
            self.modified = modified
        }
    }

    public init(
        size: UInt64? = nil, owner: Owner? = nil, permissions: UInt32? = nil, times: Times? = nil
    ) {
        self.size = size
        self.owner = owner
        self.permissions = permissions
        self.times = times
    }

    /// No attributes set (flags 0) — what `OPEN`/`MKDIR` send when they carry no metadata.
    public static let none = SFTPAttributes()

    /// The modification time, if the server sent one.
    public var modified: UInt32? { times?.modified }

    /// True when the permission bits say this is a directory (`S_IFDIR`).
    public var isDirectory: Bool { permissions.map { $0 & 0o170000 == 0o040000 } ?? false }
    /// True when the permission bits say this is a symbolic link (`S_IFLNK`).
    public var isSymlink: Bool { permissions.map { $0 & 0o170000 == 0o120000 } ?? false }
}

/// One entry of a `NAME` reply: the bare filename, the server's `ls -l`-style long name, and
/// the file's attributes.
public struct SFTPName: Equatable, Sendable {
    public var filename: String
    public var longname: String
    public var attributes: SFTPAttributes

    public init(filename: String, longname: String, attributes: SFTPAttributes) {
        self.filename = filename
        self.longname = longname
        self.attributes = attributes
    }
}

/// A decoded SFTP packet. The client sends the request cases and receives the reply cases; the
/// test fake server does the reverse, so every case round-trips through `encode`/`decode`.
public enum SFTPPacket: Equatable, Sendable {
    // Handshake.
    case initialize(version: UInt32)
    case version(version: UInt32)
    // Requests.
    case open(id: UInt32, path: String, pflags: UInt32, attributes: SFTPAttributes)
    case close(id: UInt32, handle: [UInt8])
    case read(id: UInt32, handle: [UInt8], offset: UInt64, length: UInt32)
    case write(id: UInt32, handle: [UInt8], offset: UInt64, data: [UInt8])
    case lstat(id: UInt32, path: String)
    case fstat(id: UInt32, handle: [UInt8])
    case setstat(id: UInt32, path: String, attributes: SFTPAttributes)
    case fsetstat(id: UInt32, handle: [UInt8], attributes: SFTPAttributes)
    case opendir(id: UInt32, path: String)
    case readdir(id: UInt32, handle: [UInt8])
    case remove(id: UInt32, path: String)
    case mkdir(id: UInt32, path: String, attributes: SFTPAttributes)
    case rmdir(id: UInt32, path: String)
    case realpath(id: UInt32, path: String)
    case stat(id: UInt32, path: String)
    case rename(id: UInt32, oldPath: String, newPath: String)
    // Replies.
    case status(id: UInt32, code: UInt32, message: String)
    case handle(id: UInt32, handle: [UInt8])
    case data(id: UInt32, data: [UInt8])
    case name(id: UInt32, entries: [SFTPName])
    case attrs(id: UInt32, attributes: SFTPAttributes)

    /// The request id this packet carries, or nil for the handshake packets which have none.
    public var id: UInt32? {
        switch self {
        case .initialize, .version: return nil
        case .open(let id, _, _, _), .close(let id, _), .read(let id, _, _, _), .write(let id, _, _, _),
            .lstat(let id, _), .fstat(let id, _), .setstat(let id, _, _), .fsetstat(let id, _, _),
            .opendir(let id, _), .readdir(let id, _), .remove(let id, _), .mkdir(let id, _, _),
            .rmdir(let id, _), .realpath(let id, _), .stat(let id, _), .rename(let id, _, _),
            .status(let id, _, _), .handle(let id, _), .data(let id, _), .name(let id, _),
            .attrs(let id, _):
            return id
        }
    }

    // MARK: - Encoding

    /// The full wire frame: `uint32 length` + `byte type` + payload.
    public func encode() -> [UInt8] {
        var w = SFTPWriter()
        switch self {
        case .initialize(let version): w.u8(SFTP.Kind.initialize); w.u32(version)
        case .version(let version): w.u8(SFTP.Kind.version); w.u32(version)
        case .open(let id, let path, let pflags, let attributes):
            w.u8(SFTP.Kind.open); w.u32(id); w.string(path); w.u32(pflags); w.attributes(attributes)
        case .close(let id, let handle): w.u8(SFTP.Kind.close); w.u32(id); w.byteString(handle)
        case .read(let id, let handle, let offset, let length):
            w.u8(SFTP.Kind.read); w.u32(id); w.byteString(handle); w.u64(offset); w.u32(length)
        case .write(let id, let handle, let offset, let data):
            w.u8(SFTP.Kind.write); w.u32(id); w.byteString(handle); w.u64(offset); w.byteString(data)
        case .lstat(let id, let path): w.u8(SFTP.Kind.lstat); w.u32(id); w.string(path)
        case .fstat(let id, let handle): w.u8(SFTP.Kind.fstat); w.u32(id); w.byteString(handle)
        case .setstat(let id, let path, let attributes):
            w.u8(SFTP.Kind.setstat); w.u32(id); w.string(path); w.attributes(attributes)
        case .fsetstat(let id, let handle, let attributes):
            w.u8(SFTP.Kind.fsetstat); w.u32(id); w.byteString(handle); w.attributes(attributes)
        case .opendir(let id, let path): w.u8(SFTP.Kind.opendir); w.u32(id); w.string(path)
        case .readdir(let id, let handle): w.u8(SFTP.Kind.readdir); w.u32(id); w.byteString(handle)
        case .remove(let id, let path): w.u8(SFTP.Kind.remove); w.u32(id); w.string(path)
        case .mkdir(let id, let path, let attributes):
            w.u8(SFTP.Kind.mkdir); w.u32(id); w.string(path); w.attributes(attributes)
        case .rmdir(let id, let path): w.u8(SFTP.Kind.rmdir); w.u32(id); w.string(path)
        case .realpath(let id, let path): w.u8(SFTP.Kind.realpath); w.u32(id); w.string(path)
        case .stat(let id, let path): w.u8(SFTP.Kind.stat); w.u32(id); w.string(path)
        case .rename(let id, let oldPath, let newPath):
            w.u8(SFTP.Kind.rename); w.u32(id); w.string(oldPath); w.string(newPath)
        case .status(let id, let code, let message):
            w.u8(SFTP.Kind.status); w.u32(id); w.u32(code); w.string(message); w.string("")
        case .handle(let id, let handle): w.u8(SFTP.Kind.handle); w.u32(id); w.byteString(handle)
        case .data(let id, let data): w.u8(SFTP.Kind.data); w.u32(id); w.byteString(data)
        case .name(let id, let entries):
            w.u8(SFTP.Kind.name); w.u32(id); w.u32(UInt32(entries.count))
            for entry in entries {
                w.string(entry.filename); w.string(entry.longname); w.attributes(entry.attributes)
            }
        case .attrs(let id, let attributes): w.u8(SFTP.Kind.attrs); w.u32(id); w.attributes(attributes)
        }
        // Frame it: a 4-byte big-endian length of everything after the length field.
        var framed = SFTPWriter()
        framed.u32(UInt32(w.bytes.count))
        framed.bytes.append(contentsOf: w.bytes)
        return framed.bytes
    }

    // MARK: - Decoding

    /// Decode a full wire frame (`uint32 length` + body). The length must match the bytes that
    /// follow it.
    public static func decode(frame: [UInt8]) throws(SFTPError) -> SFTPPacket {
        var r = SFTPReader(bytes: frame)
        let length = try r.u32()
        guard Int(length) == r.remaining else { throw .invalid("frame length") }
        return try decodeBody(&r)
    }

    /// Decode a packet body (`byte type` + payload) — what the transport has after it has read
    /// and stripped the 4-byte length prefix.
    public static func decode(body: [UInt8]) throws(SFTPError) -> SFTPPacket {
        var r = SFTPReader(bytes: body)
        return try decodeBody(&r)
    }

    private static func decodeBody(_ r: inout SFTPReader) throws(SFTPError) -> SFTPPacket {
        let type = try r.u8()
        switch type {
        case SFTP.Kind.initialize: return .initialize(version: try r.u32())
        case SFTP.Kind.version: return .version(version: try r.u32())
        case SFTP.Kind.open:
            return .open(id: try r.u32(), path: try r.string(), pflags: try r.u32(), attributes: try r.attributes())
        case SFTP.Kind.close: return .close(id: try r.u32(), handle: try r.byteString())
        case SFTP.Kind.read:
            return .read(id: try r.u32(), handle: try r.byteString(), offset: try r.u64(), length: try r.u32())
        case SFTP.Kind.write:
            return .write(id: try r.u32(), handle: try r.byteString(), offset: try r.u64(), data: try r.byteString())
        case SFTP.Kind.lstat: return .lstat(id: try r.u32(), path: try r.string())
        case SFTP.Kind.fstat: return .fstat(id: try r.u32(), handle: try r.byteString())
        case SFTP.Kind.setstat: return .setstat(id: try r.u32(), path: try r.string(), attributes: try r.attributes())
        case SFTP.Kind.fsetstat:
            return .fsetstat(id: try r.u32(), handle: try r.byteString(), attributes: try r.attributes())
        case SFTP.Kind.opendir: return .opendir(id: try r.u32(), path: try r.string())
        case SFTP.Kind.readdir: return .readdir(id: try r.u32(), handle: try r.byteString())
        case SFTP.Kind.remove: return .remove(id: try r.u32(), path: try r.string())
        case SFTP.Kind.mkdir: return .mkdir(id: try r.u32(), path: try r.string(), attributes: try r.attributes())
        case SFTP.Kind.rmdir: return .rmdir(id: try r.u32(), path: try r.string())
        case SFTP.Kind.realpath: return .realpath(id: try r.u32(), path: try r.string())
        case SFTP.Kind.stat: return .stat(id: try r.u32(), path: try r.string())
        case SFTP.Kind.rename: return .rename(id: try r.u32(), oldPath: try r.string(), newPath: try r.string())
        case SFTP.Kind.status:
            let id = try r.u32()
            let code = try r.u32()
            // v3 adds a message and language tag; older servers omit them. The server chooses
            // every byte, and it ends up in a sentence on screen, so keep only a line of it.
            let message = r.remaining > 0 ? String(try r.string().prefix(SFTP.maxStatusMessage)) : ""
            return .status(id: id, code: code, message: message)
        case SFTP.Kind.handle: return .handle(id: try r.u32(), handle: try r.byteString())
        case SFTP.Kind.data: return .data(id: try r.u32(), data: try r.byteString())
        case SFTP.Kind.name:
            let id = try r.u32()
            // Each entry is two strings and an attributes block: at least 12 bytes. The
            // bytes-remaining check alone is not enough here — a legal 16 MiB frame can
            // declare 1.4 million minimal entries, which decode to a hundred megabytes of
            // `SFTPName`. So this also has an absolute cap, as `DeltaCodec`'s rows do.
            let count = try r.count(elementSize: 12)
            guard count <= SFTP.maxNameEntries else { throw .invalid("too many entries in one NAME") }
            var entries: [SFTPName] = []
            entries.reserveCapacity(count)
            for _ in 0..<count {
                entries.append(
                    SFTPName(filename: try r.string(), longname: try r.string(), attributes: try r.attributes()))
            }
            return .name(id: id, entries: entries)
        case SFTP.Kind.attrs: return .attrs(id: try r.u32(), attributes: try r.attributes())
        default: throw .unknownPacket(type)
        }
    }
}

// MARK: - Bytes (big-endian, defensively decoded)

struct SFTPWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) } }

    /// A `uint32`-length-prefixed run of raw bytes (an SFTP `string`): used for handles and data.
    mutating func byteString(_ b: [UInt8]) {
        u32(UInt32(b.count))
        bytes.append(contentsOf: b)
    }

    /// A `uint32`-length-prefixed UTF-8 string: used for paths and messages.
    mutating func string(_ s: String) { byteString(Array(s.utf8)) }

    mutating func attributes(_ a: SFTPAttributes) {
        var flags: UInt32 = 0
        if a.size != nil { flags |= SFTP.Attr.size }
        if a.owner != nil { flags |= SFTP.Attr.uidgid }
        if a.permissions != nil { flags |= SFTP.Attr.permissions }
        if a.times != nil { flags |= SFTP.Attr.acmodtime }
        u32(flags)
        if let size = a.size { u64(size) }
        if let owner = a.owner {
            u32(owner.uid)
            u32(owner.gid)
        }
        if let permissions = a.permissions { u32(permissions) }
        if let times = a.times {
            u32(times.accessed)
            u32(times.modified)
        }
    }
}

struct SFTPReader {
    let bytes: [UInt8]
    private(set) var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { index == bytes.count }
    var remaining: Int { bytes.count - index }

    mutating func take(_ n: Int) throws(SFTPError) -> [UInt8] {
        guard n >= 0, n <= remaining else { throw .truncated }
        defer { index += n }
        return Array(bytes[index..<(index + n)])
    }

    mutating func u8() throws(SFTPError) -> UInt8 {
        guard remaining >= 1 else { throw .truncated }
        defer { index += 1 }
        return bytes[index]
    }

    private mutating func integer<T: FixedWidthInteger>(_: T.Type) throws(SFTPError) -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw .truncated }
        var value: T = 0
        for offset in 0..<size { value = (value << 8) | T(bytes[index + offset]) }  // big-endian
        index += size
        return value
    }

    mutating func u32() throws(SFTPError) -> UInt32 { try integer(UInt32.self) }
    mutating func u64() throws(SFTPError) -> UInt64 { try integer(UInt64.self) }

    /// A count of elements that each take at least `elementSize` bytes, checked against what
    /// remains so a forged count cannot make the decoder allocate.
    mutating func count(elementSize: Int) throws(SFTPError) -> Int {
        let n = Int(try u32())
        guard n <= remaining / max(elementSize, 1) else { throw .truncated }
        return n
    }

    /// A `uint32`-length-prefixed run of raw bytes.
    mutating func byteString() throws(SFTPError) -> [UInt8] {
        let n = try count(elementSize: 1)
        return try take(n)
    }

    /// A `uint32`-length-prefixed UTF-8 string. A NUL is refused: Swift keeps it, but every C
    /// API the string later reaches — `open`, `rename` — stops there, so `".zshrc\0.txt"`
    /// would show one name and write another. POSIX forbids NUL in a filename anyway.
    mutating func string() throws(SFTPError) -> String {
        let bytes = try byteString()
        guard !bytes.contains(0) else { throw .invalid("a string with a NUL in it") }
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func attributes() throws(SFTPError) -> SFTPAttributes {
        let flags = try u32()
        var a = SFTPAttributes()
        if flags & SFTP.Attr.size != 0 { a.size = try u64() }
        if flags & SFTP.Attr.uidgid != 0 {
            a.owner = SFTPAttributes.Owner(uid: try u32(), gid: try u32())
        }
        if flags & SFTP.Attr.permissions != 0 { a.permissions = try u32() }
        if flags & SFTP.Attr.acmodtime != 0 {
            a.times = SFTPAttributes.Times(accessed: try u32(), modified: try u32())
        }
        if flags & SFTP.Attr.extended != 0 {
            // Consume extensions we don't model so the rest of the packet still parses.
            let pairs = try count(elementSize: 8)
            for _ in 0..<pairs {
                _ = try byteString()
                _ = try byteString()
            }
        }
        return a
    }
}
