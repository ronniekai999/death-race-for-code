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

    /// What a session will take from a server. A hostile one is otherwise an unbounded sink
    /// on the far end of a pipe; these are the absolute caps on top of the codec's
    /// bytes-remaining checks, the same discipline `ScreenProtocol/DeltaCodec` keeps. They are
    /// injectable so a test can reach a cap without doing two hundred thousand entries' worth
    /// of work, which under Thread Sanitizer is enough to starve its neighbours.
    public struct Limits: Sendable, Equatable {
        /// The most entries one directory may have. A server need never send the `EOF` that
        /// ends a `READDIR` loop: one measured run swallowed 264,000 entries in a second and
        /// a half and was still going.
        public var directoryEntries: Int
        /// The largest file a download will take. It exists because a download is held whole
        /// in memory before it is written, so a server that keeps answering `READ` is
        /// otherwise unbounded — it need not stop at the size it reported. A streaming
        /// download would replace this with a real limit of the disk; see docs/PERF.md.
        public var downloadBytes: Int
        public var transferBytes: UInt64
        public var pipelineDepth: Int

        public init(
            directoryEntries: Int = 200_000, downloadBytes: Int = 2 << 30, transferBytes: UInt64 = 1 << 40,
            pipelineDepth: Int = 8
        ) {
            self.directoryEntries = directoryEntries
            self.downloadBytes = max(0, downloadBytes)
            self.transferBytes = transferBytes
            self.pipelineDepth = min(32, max(1, pipelineDepth))
        }

        public static let `default` = Limits()
    }

    private let transport: any SFTPTransport
    private let limits: Limits
    private var nextID: UInt32 = 0
    private struct Pending {
        let continuation: CheckedContinuation<SFTPPacket, any Error>
        var deadline: Task<Void, Never>?
        var sender: Task<Void, Never>?
    }
    private var pending: [UInt32: Pending] = [:]
    // Only cancelled, already-sent requests may receive one late reply. Cap this set so a
    // server that never answers cancellation cannot consume memory indefinitely.
    private var retired: Set<UInt32> = []
    private let requestTimeout: Duration
    private var readerTask: Task<Void, Never>?
    private var sessionError: (any Error)?
    public private(set) var serverVersion: UInt32?

    public init(transport: any SFTPTransport, limits: Limits = .default, requestTimeout: Duration = .seconds(30)) {
        self.transport = transport
        self.limits = limits
        self.requestTimeout = requestTimeout
    }

    /// Internal diagnostics used to synchronize cancellation with a completed send.
    var sendingRequestCount: Int { pending.values.filter { $0.sender != nil }.count }

    // MARK: - Lifecycle

    /// Send `INIT`, await `VERSION`, and start matching replies. Safe to call once.
    public func start() async throws {
        guard serverVersion == nil else { return }
        guard readerTask == nil else { throw SFTPError.invalid("handshake already in progress") }
        readerTask = Task { await self.readLoop() }
        do {
            let reply = try await request(.initialize(version: SFTP.version), id: 0)
            guard case .version(let version) = reply, version == SFTP.version else {
                throw SFTPError.unexpectedReply("expected SFTP VERSION 3")
            }
            serverVersion = version
        } catch {
            await shutDown()
            throw error
        }
    }

    public func shutDown() async {
        readerTask?.cancel()
        failAll(with: SFTPError.transportClosed)
        await transport.close()
    }

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                let packet = try SFTPPacket.decode(frame: await transport.receive())
                let id: UInt32
                if case .version = packet, serverVersion == nil, pending[0] != nil {
                    id = 0
                } else if let packetID = packet.id {
                    id = packetID
                } else {
                    throw SFTPError.invalid("unexpected handshake packet")
                }
                if pending[id] != nil {
                    complete(id, result: .success(packet))
                } else if retired.remove(id) == nil {
                    throw SFTPError.invalid("a reply to a request that was never sent")
                }
            } catch {
                failAll(with: error)
                await transport.close()
                return
            }
        }
    }

    private func complete(_ id: UInt32, result: Result<SFTPPacket, any Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.deadline?.cancel()
        request.sender?.cancel()
        request.continuation.resume(with: result)
    }

    private func failAll(with error: any Error) {
        if sessionError == nil { sessionError = error }
        for id in Array(pending.keys) { complete(id, result: .failure(error)) }
        retired.removeAll()
    }

    private func abandon(_ id: UInt32, error: any Error) async {
        guard let request = pending[id] else { return }
        let sending = request.sender != nil
        retired.insert(id)
        complete(id, result: .failure(error))
        // A blocked write may have sent half a frame: the stream cannot safely be reused.
        // After a complete write, only this request is cancelled; its late reply is discarded.
        if sending || id == 0 || retired.count >= 1024 {
            failAll(with: error)
            await transport.close()
        }
    }

    // MARK: - Request / reply

    private func nextRequestID() -> UInt32 {
        repeat { nextID &+= 1 } while nextID == 0 || pending[nextID] != nil || retired.contains(nextID)
        return nextID
    }

    private func request(_ packet: SFTPPacket, id explicitID: UInt32? = nil) async throws -> SFTPPacket {
        try Task.checkCancellation()
        if let sessionError { throw sessionError }
        guard let id = explicitID ?? packet.id else { throw SFTPError.invalid("request without id") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = Pending(continuation: continuation)
                pending[id]?.deadline = Task {
                    do { try await Task.sleep(for: requestTimeout) } catch { return }
                    await abandon(id, error: SFTPError.timedOut)
                }
                // Register before sending: a reply can arrive before send returns. An
                // unstructured sender also lets a deadline resolve a blocked send.
                pending[id]?.sender = Task {
                    do {
                        try await transport.send(packet.encode())
                        pending[id]?.sender = nil
                    } catch {
                        complete(id, result: .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { await self.abandon(id, error: CancellationError()) }
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
                case .name(_, let batch):
                    guard entries.count + batch.count <= limits.directoryEntries else {
                        throw SFTPError.invalid("more than \(limits.directoryEntries) entries in one directory")
                    }
                    entries.append(contentsOf: batch)
                case .status(_, let code, let message):
                    if code == SFTP.Status.eof { break loop }
                    throw SFTPError.status(code: code, message: message)
                default: throw SFTPError.unexpectedReply("READDIR")
                }
            }
        } catch {
            await cleanup(handle)
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
        case .data(_, let data):
            // A server may answer short, never long: a 16 MiB `DATA` for a 32 KiB request is
            // how a transfer loop becomes an unbounded one.
            guard data.count <= Int(length) else { throw SFTPError.invalid("more DATA than was asked for") }
            return data
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

    /// Download a file whole, reporting bytes done out of the total after each chunk. The
    /// total comes from the open file's own size; a server that returns short reads is handled
    /// by advancing only as far as it actually gave us. Cancelling the calling task stops it.
    public func download(
        _ path: String, progress: @Sendable @escaping (UInt64, UInt64) -> Void
    ) async throws -> [UInt8] {
        let handle = try await open(path, pflags: SFTP.Open.read)
        var data: [UInt8] = []
        do {
            let total = try await fstat(handle).size ?? 0
            progress(0, total)
            var offset: UInt64 = 0
            while let chunk = try await read(handle, offset: offset, length: UInt32(Self.chunkSize)), !chunk.isEmpty {
                try Task.checkCancellation()
                guard data.count + chunk.count <= limits.downloadBytes else {
                    throw SFTPError.invalid("the file is larger than Maze will take in one piece")
                }
                data.append(contentsOf: chunk)
                offset += UInt64(chunk.count)
                // A file that grew since the stat still reports a sane fraction.
                progress(offset, max(total, offset))
            }
        } catch {
            await cleanup(handle)
            throw error
        }
        try await close(handle)
        return data
    }

    /// Upload bytes to a new (or truncated) file, reporting progress and optionally stamping
    /// its attributes after. Cancelling the calling task stops it part-written.
    public func upload(
        _ path: String, bytes: [UInt8], attributes: SFTPAttributes, overwrite: Bool = false,
        progress: @Sendable @escaping (UInt64, UInt64) -> Void
    ) async throws {
        let flags = SFTP.Open.write | SFTP.Open.create | (overwrite ? SFTP.Open.truncate : SFTP.Open.exclusive)
        let handle = try await open(path, pflags: flags)
        do {
            let total = UInt64(bytes.count)
            progress(0, total)
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let end = min(offset + Self.chunkSize, bytes.count)
                try await write(handle, offset: UInt64(offset), data: Array(bytes[offset..<end]))
                offset = end
                progress(UInt64(offset), total)
            }
            if attributes != .none { try await fsetstat(handle, attributes) }
        } catch {
            await cleanup(handle)
            throw error
        }
        try await close(handle)
    }

    /// Close in a fresh task after cancellation: a cancelled task cannot issue CLOSE. Do
    /// not delay the user's Stop action while a server also stalls that cleanup request.
    private func cleanup(_ handle: Handle) async {
        if Task.isCancelled { Task { try? await self.close(handle) } } else { try? await close(handle) }
    }

    /// Bounded pipelining: no more than pipelineDepth chunks (default 256 KiB) resident.
    public func upload(
        _ path: String, source: TransferSource, overwrite: Bool,
        progress: @Sendable @escaping (UInt64, UInt64) -> Void
    ) async throws {
        guard source.size <= limits.transferBytes else {
            throw SFTPError.invalid("the file exceeds the transfer limit")
        }
        let flags = SFTP.Open.write | SFTP.Open.create | (overwrite ? SFTP.Open.truncate : SFTP.Open.exclusive)
        let handle = try await open(path, pflags: flags)
        do {
            progress(0, source.size)
            try await transferChunks(size: source.size, progress: progress) { offset, length in
                try Task.checkCancellation()
                var bytes: [UInt8] = []
                while bytes.count < length {
                    let part = try await source.read(offset + UInt64(bytes.count), length - bytes.count)
                    guard !part.isEmpty, part.count <= length - bytes.count else {
                        throw SFTPError.invalid("the local file changed during upload")
                    }
                    bytes.append(contentsOf: part)
                }
                try Task.checkCancellation()
                try await self.write(handle, offset: offset, data: bytes)
            }
            try await close(handle)
        } catch { await cleanup(handle); throw error }
    }

    public func download(
        _ path: String, destination: TransferDestination,
        progress: @Sendable @escaping (UInt64, UInt64) -> Void
    ) async throws {
        let handle = try await open(path, pflags: SFTP.Open.read)
        do {
            guard let size = try await fstat(handle).size, size <= limits.transferBytes else {
                throw SFTPError.invalid("the remote file has no usable size or exceeds the transfer limit")
            }
            progress(0, size)
            try await transferChunks(size: size, progress: progress) { offset, length in
                var bytes: [UInt8] = []
                while bytes.count < length {
                    try Task.checkCancellation()
                    guard
                        let part = try await self.read(
                            handle, offset: offset + UInt64(bytes.count),
                            length: UInt32(length - bytes.count)), !part.isEmpty
                    else {
                        throw SFTPError.invalid("the remote file changed during download")
                    }
                    bytes.append(contentsOf: part)
                }
                try Task.checkCancellation()
                try await destination.write(bytes, offset)
            }
            if let extra = try await read(handle, offset: size, length: 1), !extra.isEmpty {
                throw SFTPError.invalid("the remote file changed during download")
            }
            try await close(handle)
        } catch { await cleanup(handle); throw error }
    }

    private func transferChunks(
        size: UInt64, progress: @Sendable (UInt64, UInt64) -> Void,
        work: @Sendable @escaping (UInt64, Int) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: UInt64.self) { group in
            var offset: UInt64 = 0
            var completed: UInt64 = 0
            func enqueue() {
                guard offset < size else { return }
                let start = offset
                let count = Int(min(UInt64(Self.chunkSize), size - start))
                offset += UInt64(count)
                group.addTask {
                    try await work(start, count); return UInt64(count)
                }
            }
            for _ in 0..<limits.pipelineDepth { enqueue() }
            while let count = try await group.next() {
                try Task.checkCancellation()
                completed += count
                progress(completed, size)
                enqueue()
            }
        }
    }

    /// Download a file whole, without watching its progress.
    public func download(_ path: String) async throws -> [UInt8] {
        try await download(path, progress: { _, _ in })
    }

    /// Upload bytes, without watching their progress.
    public func upload(_ path: String, bytes: [UInt8], attributes: SFTPAttributes = .none, overwrite: Bool = false)
        async throws
    {
        try await upload(path, bytes: bytes, attributes: attributes, overwrite: overwrite, progress: { _, _ in })
    }
}
