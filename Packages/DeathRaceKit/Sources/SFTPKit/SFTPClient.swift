/// An SFTP v3 client over an `SFTPTransport`. It does the version handshake, assigns a request
/// id to each packet, and matches replies to requests by that id with a background read loop,
/// so several requests can be in flight at once. Every op throws `SFTPError.status` when the
/// server answers with an error code, and `SFTPError.transportClosed` if the ssh connection
/// drops mid-request.
public actor SFTPClient {
    /// An opaque file or directory handle the server gave us.
    public struct Handle: Sendable, Equatable {
        public let bytes: [UInt8]
    }

    private let transport: any SFTPTransport
    private var nextID: UInt32 = 0
    private var waiters: [UInt32: CheckedContinuation<SFTPPacket, any Error>] = [:]
    private var readerTask: Task<Void, Never>?
    private var sessionError: (any Error)?
    /// The protocol version the server agreed to, once the handshake has run.
    public private(set) var serverVersion: UInt32?

    public init(transport: any SFTPTransport) {
        self.transport = transport
    }

    // MARK: - Lifecycle

    /// Send `INIT`, await `VERSION`, and start matching replies. Safe to call once.
    public func start() async throws {
        guard serverVersion == nil else { return }
        try await transport.send(SFTPPacket.initialize(version: SFTP.version).encode())
        let frame = try await transport.receive()
        guard case .version(let version) = try SFTPPacket.decode(frame: frame) else {
            throw SFTPError.unexpectedReply("expected VERSION")
        }
        serverVersion = version
        readerTask = Task { await self.readLoop() }
    }

    /// Close the transport and fail any requests still waiting.
    public func shutDown() async {
        readerTask?.cancel()
        failAll(with: SFTPError.transportClosed)
        await transport.close()
    }

    private func readLoop() async {
        while true {
            let frame: [UInt8]
            do {
                frame = try await transport.receive()
            } catch {
                failAll(with: SFTPError.transportClosed)
                return
            }
            guard let packet = try? SFTPPacket.decode(frame: frame) else {
                // A frame we can't parse means the stream desynced — fail the session.
                failAll(with: SFTPError.invalid("undecodable reply"))
                return
            }
            guard let id = packet.id else { continue }  // no id-bearing handshake packets mid-session
            if let waiter = waiters.removeValue(forKey: id) { waiter.resume(returning: packet) }
        }
    }

    private func failAll(with error: any Error) {
        if sessionError == nil { sessionError = error }
        let pending = waiters
        waiters = [:]
        for (_, waiter) in pending { waiter.resume(throwing: error) }
    }

    // MARK: - Request / reply

    private func nextRequestID() -> UInt32 {
        nextID &+= 1
        return nextID
    }

    private func request(_ packet: SFTPPacket) async throws -> SFTPPacket {
        if let sessionError { throw sessionError }
        guard let id = packet.id else { throw SFTPError.invalid("request without id") }
        // Send first: the reply can't arrive before the server sees the request, and the
        // continuation below registers the waiter synchronously once send returns, so the
        // read loop (which runs only at suspension points) can't deliver before we're ready.
        try await transport.send(packet.encode())
        return try await withCheckedThrowingContinuation { continuation in
            if let sessionError {
                continuation.resume(throwing: sessionError)
            } else {
                waiters[id] = continuation
            }
        }
    }

    private func expectOK(_ reply: SFTPPacket, _ op: String) throws {
        guard case .status(_, let code, let message) = reply else { throw SFTPError.unexpectedReply(op) }
        guard code == SFTP.Status.ok else { throw SFTPError.status(code: code, message: message) }
    }

    private func expectHandle(_ reply: SFTPPacket, _ op: String) throws -> Handle {
        switch reply {
        case .handle(_, let bytes): return Handle(bytes: bytes)
        case .status(_, let code, let message): throw SFTPError.status(code: code, message: message)
        default: throw SFTPError.unexpectedReply(op)
        }
    }

    private func expectAttrs(_ reply: SFTPPacket, _ op: String) throws -> SFTPAttributes {
        switch reply {
        case .attrs(_, let attributes): return attributes
        case .status(_, let code, let message): throw SFTPError.status(code: code, message: message)
        default: throw SFTPError.unexpectedReply(op)
        }
    }

    // MARK: - Path operations

    /// Resolve a path (expanding `.`, `~` and symlinks) to its absolute form.
    public func realPath(_ path: String) async throws -> String {
        let reply = try await request(.realpath(id: nextRequestID(), path: path))
        switch reply {
        case .name(_, let entries):
            guard let first = entries.first else { throw SFTPError.unexpectedReply("empty REALPATH") }
            return first.filename
        case .status(_, let code, let message): throw SFTPError.status(code: code, message: message)
        default: throw SFTPError.unexpectedReply("REALPATH")
        }
    }

    /// The entries of a directory, including `.` and `..` as the server sends them.
    public func list(_ path: String) async throws -> [SFTPName] {
        let handle = try await openDirectory(path)
        var entries: [SFTPName] = []
        do {
            loop: while true {
                let reply = try await request(.readdir(id: nextRequestID(), handle: handle.bytes))
                switch reply {
                case .name(_, let batch): entries.append(contentsOf: batch)
                case .status(_, let code, let message):
                    if code == SFTP.Status.eof { break loop }
                    throw SFTPError.status(code: code, message: message)
                default: throw SFTPError.unexpectedReply("READDIR")
                }
            }
        } catch {
            try? await close(handle)
            throw error
        }
        try await close(handle)
        return entries
    }

    /// A path's attributes, following symlinks.
    public func stat(_ path: String) async throws -> SFTPAttributes {
        try expectAttrs(try await request(.stat(id: nextRequestID(), path: path)), "STAT")
    }

    /// A path's attributes, not following symlinks.
    public func lstat(_ path: String) async throws -> SFTPAttributes {
        try expectAttrs(try await request(.lstat(id: nextRequestID(), path: path)), "LSTAT")
    }

    public func mkdir(_ path: String, attributes: SFTPAttributes = .none) async throws {
        try expectOK(try await request(.mkdir(id: nextRequestID(), path: path, attributes: attributes)), "MKDIR")
    }

    public func rmdir(_ path: String) async throws {
        try expectOK(try await request(.rmdir(id: nextRequestID(), path: path)), "RMDIR")
    }

    public func remove(_ path: String) async throws {
        try expectOK(try await request(.remove(id: nextRequestID(), path: path)), "REMOVE")
    }

    public func rename(from oldPath: String, to newPath: String) async throws {
        try expectOK(
            try await request(.rename(id: nextRequestID(), oldPath: oldPath, newPath: newPath)), "RENAME")
    }

    // MARK: - File handles

    public func openDirectory(_ path: String) async throws -> Handle {
        try expectHandle(try await request(.opendir(id: nextRequestID(), path: path)), "OPENDIR")
    }

    public func open(_ path: String, pflags: UInt32, attributes: SFTPAttributes = .none) async throws -> Handle {
        try expectHandle(
            try await request(.open(id: nextRequestID(), path: path, pflags: pflags, attributes: attributes)), "OPEN")
    }

    public func close(_ handle: Handle) async throws {
        try expectOK(try await request(.close(id: nextRequestID(), handle: handle.bytes)), "CLOSE")
    }

    public func fstat(_ handle: Handle) async throws -> SFTPAttributes {
        try expectAttrs(try await request(.fstat(id: nextRequestID(), handle: handle.bytes)), "FSTAT")
    }

    public func fsetstat(_ handle: Handle, _ attributes: SFTPAttributes) async throws {
        try expectOK(
            try await request(.fsetstat(id: nextRequestID(), handle: handle.bytes, attributes: attributes)), "FSETSTAT")
    }

    /// Read a chunk at `offset`; nil at end of file. The server may return fewer bytes than
    /// asked, so callers advance by what they actually got.
    public func read(_ handle: Handle, offset: UInt64, length: UInt32) async throws -> [UInt8]? {
        let reply = try await request(.read(id: nextRequestID(), handle: handle.bytes, offset: offset, length: length))
        switch reply {
        case .data(_, let data): return data
        case .status(_, let code, let message):
            if code == SFTP.Status.eof { return nil }
            throw SFTPError.status(code: code, message: message)
        default: throw SFTPError.unexpectedReply("READ")
        }
    }

    public func write(_ handle: Handle, offset: UInt64, data: [UInt8]) async throws {
        try expectOK(
            try await request(.write(id: nextRequestID(), handle: handle.bytes, offset: offset, data: data)), "WRITE")
    }

    // MARK: - Whole-file transfers

    /// The default transfer chunk: OpenSSH caps a single READ/WRITE payload at 32 KiB over the
    /// default channel window, so larger requests just get split anyway.
    public static let chunkSize = 32_768

    /// Download a file whole. Sequential and correct against short reads; the pipelined,
    /// progress-reporting transfer path lives in the transfer layer.
    public func download(_ path: String) async throws -> [UInt8] {
        let handle = try await open(path, pflags: SFTP.Open.read)
        var data: [UInt8] = []
        do {
            var offset: UInt64 = 0
            while let chunk = try await read(handle, offset: offset, length: UInt32(Self.chunkSize)), !chunk.isEmpty {
                data.append(contentsOf: chunk)
                offset += UInt64(chunk.count)
            }
        } catch {
            try? await close(handle)
            throw error
        }
        try await close(handle)
        return data
    }

    /// Upload bytes to a new (or truncated) file, optionally stamping its attributes after.
    public func upload(_ path: String, bytes: [UInt8], attributes: SFTPAttributes = .none) async throws {
        let handle = try await open(
            path, pflags: SFTP.Open.write | SFTP.Open.create | SFTP.Open.truncate)
        do {
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + Self.chunkSize, bytes.count)
                try await write(handle, offset: UInt64(offset), data: Array(bytes[offset..<end]))
                offset = end
            }
            if attributes != .none { try await fsetstat(handle, attributes) }
        } catch {
            try? await close(handle)
            throw error
        }
        try await close(handle)
    }
}
