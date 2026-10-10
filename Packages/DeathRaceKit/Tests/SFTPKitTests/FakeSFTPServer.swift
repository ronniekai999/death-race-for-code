@testable import SFTPKit

/// An in-process SFTP v3 server over a tiny virtual filesystem, used as the client's transport
/// in tests: `send` decodes a request and enqueues the reply, `receive` hands replies back.
/// Enough of the protocol to exercise every client op without a real sshd.
actor FakeSFTPServer: SFTPTransport {
    private enum OpenHandle {
        case file(path: String, writing: Bool)
        case directory(path: String, emitted: Bool)
    }

    private var directories: Set<String> = ["/", "/home", "/home/user"]
    private var files: [String: [UInt8]] = [:]
    private var handles: [UInt8: OpenHandle] = [:]
    private var nextHandle: UInt8 = 1
    private var outbox: [[UInt8]] = []
    private var pending: CheckedContinuation<[UInt8], any Error>?
    private var closed = false

    /// Gives the client's read loop a turn before `send` returns, so the reply lands while
    /// the request is still suspended there — what a real transport does, where the reader is
    /// a thread of its own.
    private let answersDuringSend: Bool
    /// Answers an id the client cannot have issued, before any request exists, then drops the
    /// real one — a server making replies up.
    ///
    /// The id is deliberately not 1. Forging the id the client is about to use tests nothing:
    /// once `request` has put that id in `issued`, a `STATUS` carrying it is exactly what a
    /// legitimate reply looks like, and the client is right to take it — which made the test
    /// that did so pass or fail on whether the read loop drained the forgery before the next
    /// call registered its id. `UInt32.max` is never issued in any interleaving, because ids
    /// run 1, 2, 3 …, so the rule under test holds either way round.
    private let answersAheadOfRequests: Bool
    /// An id `nextRequestID` cannot reach in a test that makes a handful of requests.
    private static let forgedReplyID: UInt32 = .max
    /// Never sends the `EOF` that ends a `READDIR` loop.
    private let neverEndsReaddir: Bool
    private var readdirBatches = 0
    /// Answers each `READ` with far more than was asked for.
    private let answersReadsTooLong: Bool

    init(
        files: [String: [UInt8]] = [:], directories: [String] = [], answersDuringSend: Bool = false,
        answersAheadOfRequests: Bool = false, neverEndsReaddir: Bool = false, answersReadsTooLong: Bool = false
    ) {
        for (path, bytes) in files { self.files[path] = bytes }
        for directory in directories { self.directories.insert(directory) }
        self.answersDuringSend = answersDuringSend
        self.answersAheadOfRequests = answersAheadOfRequests
        self.neverEndsReaddir = neverEndsReaddir
        self.answersReadsTooLong = answersReadsTooLong
    }

    // MARK: - Transport

    func send(_ frame: [UInt8]) async throws {
        guard !closed else { throw SFTPError.transportClosed }
        let packet = try SFTPPacket.decode(frame: frame)
        if case .initialize = packet, answersAheadOfRequests {
            enqueue(SFTPPacket.version(version: SFTP.version).encode())
            // A reply to a request that was never made, and never will be. The real request
            // below is then dropped, so the only way the client comes back is by refusing it.
            enqueue(
                SFTPPacket.status(id: Self.forgedReplyID, code: SFTP.Status.ok, message: "").encode())
            return
        }
        if answersAheadOfRequests { return }
        for reply in replies(to: packet) { enqueue(reply.encode()) }
        if answersDuringSend {
            for _ in 0..<4 { await Task.yield() }
        }
    }

    func receive() async throws -> [UInt8] {
        if !outbox.isEmpty { return outbox.removeFirst() }
        if closed { throw SFTPError.transportClosed }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    func close() {
        closed = true
        pending?.resume(throwing: SFTPError.transportClosed)
        pending = nil
    }

    private func enqueue(_ frame: [UInt8]) {
        if let continuation = pending {
            pending = nil
            continuation.resume(returning: frame)
        } else {
            outbox.append(frame)
        }
    }

    // MARK: - Protocol logic

    private func replies(to packet: SFTPPacket) -> [SFTPPacket] {
        switch packet {
        case .initialize:
            return [.version(version: SFTP.version)]
        case .realpath(let id, let path):
            let resolved = path == "." || path.isEmpty ? "/home/user" : path
            return [
                .name(
                    id: id, entries: [SFTPName(filename: resolved, longname: resolved, attributes: directoryAttributes)]
                )
            ]
        case .stat(let id, let path), .lstat(let id, let path):
            guard let attributes = attributes(of: path) else { return [noSuchFile(id)] }
            return [.attrs(id: id, attributes: attributes)]
        case .opendir(let id, let path):
            guard directories.contains(normalize(path)) else { return [noSuchFile(id)] }
            return [.handle(id: id, handle: makeHandle(.directory(path: normalize(path), emitted: false)))]
        case .readdir(let id, let handle):
            guard let key = handle.first, case .directory(let path, let emitted) = handles[key] else {
                return [status(id, SFTP.Status.failure, "bad handle")]
            }
            if neverEndsReaddir {
                // A batch every time, and never the EOF that would end the client's loop.
                readdirBatches += 1
                return [
                    .name(
                        id: id,
                        entries: (0..<1_000).map {
                            SFTPName(filename: "f\(readdirBatches)-\($0)", longname: "", attributes: .none)
                        })
                ]
            }
            if emitted { return [status(id, SFTP.Status.eof, "")] }
            handles[key] = .directory(path: path, emitted: true)
            return [.name(id: id, entries: entries(in: path))]
        case .open(let id, let path, let pflags, _):
            let path = normalize(path)
            let writing = pflags & SFTP.Open.write != 0
            if writing {
                if pflags & SFTP.Open.exclusive != 0, files[path] != nil || directories.contains(path) {
                    return [status(id, SFTP.Status.failure, "file exists")]
                }
                if pflags & SFTP.Open.truncate != 0 || files[path] == nil { files[path] = [] }
                return [.handle(id: id, handle: makeHandle(.file(path: path, writing: true)))]
            }
            guard files[path] != nil else { return [noSuchFile(id)] }
            return [.handle(id: id, handle: makeHandle(.file(path: path, writing: false)))]
        case .read(let id, let handle, let offset, let length):
            guard let key = handle.first, case .file(let path, _) = handles[key], let data = files[path] else {
                return [status(id, SFTP.Status.failure, "bad handle")]
            }
            if answersReadsTooLong {
                return [.data(id: id, data: [UInt8](repeating: 1, count: Int(length) * 4))]
            }
            let start = Int(offset)
            if start >= data.count { return [status(id, SFTP.Status.eof, "")] }
            let end = min(start + Int(length), data.count)
            return [.data(id: id, data: Array(data[start..<end]))]
        case .write(let id, let handle, let offset, let bytes):
            guard let key = handle.first, case .file(let path, true) = handles[key] else {
                return [status(id, SFTP.Status.failure, "bad handle")]
            }
            var data = files[path] ?? []
            let start = Int(offset)
            if data.count < start + bytes.count {
                data.append(contentsOf: repeatElement(0, count: start + bytes.count - data.count))
            }
            data.replaceSubrange(start..<(start + bytes.count), with: bytes)
            files[path] = data
            return [okStatus(id)]
        case .fstat(let id, let handle):
            guard let key = handle.first, case .file(let path, _) = handles[key], let data = files[path] else {
                return [status(id, SFTP.Status.failure, "bad handle")]
            }
            return [.attrs(id: id, attributes: SFTPAttributes(size: UInt64(data.count), permissions: 0o100_644))]
        case .fsetstat(let id, _, _):
            return [okStatus(id)]
        case .close(let id, let handle):
            if let key = handle.first { handles[key] = nil }
            return [okStatus(id)]
        case .mkdir(let id, let path, _):
            directories.insert(normalize(path))
            return [okStatus(id)]
        case .rmdir(let id, let path):
            directories.remove(normalize(path))
            return [okStatus(id)]
        case .remove(let id, let path):
            guard files.removeValue(forKey: normalize(path)) != nil else { return [noSuchFile(id)] }
            return [okStatus(id)]
        case .rename(let id, let oldPath, let newPath):
            let from = normalize(oldPath), to = normalize(newPath)
            if let data = files.removeValue(forKey: from) { files[to] = data; return [okStatus(id)] }
            if directories.remove(from) != nil { directories.insert(to); return [okStatus(id)] }
            return [noSuchFile(id)]
        case .setstat(let id, _, _):
            return [okStatus(id)]
        default:
            // A reply packet, or one the client never sends.
            return [status(packet.id ?? 0, SFTP.Status.opUnsupported, "unsupported")]
        }
    }

    // MARK: - Virtual filesystem

    private var directoryAttributes: SFTPAttributes { SFTPAttributes(permissions: 0o040_755) }

    private func attributes(of path: String) -> SFTPAttributes? {
        let path = normalize(path)
        if let data = files[path] { return SFTPAttributes(size: UInt64(data.count), permissions: 0o100_644) }
        if directories.contains(path) { return directoryAttributes }
        return nil
    }

    private func entries(in directory: String) -> [SFTPName] {
        var names: [SFTPName] = [
            SFTPName(filename: ".", longname: ".", attributes: directoryAttributes),
            SFTPName(filename: "..", longname: "..", attributes: directoryAttributes),
        ]
        for path in directories where parent(path) == directory && path != directory {
            names.append(SFTPName(filename: name(path), longname: "d " + name(path), attributes: directoryAttributes))
        }
        for (path, data) in files where parent(path) == directory {
            names.append(
                SFTPName(
                    filename: name(path), longname: "f " + name(path),
                    attributes: SFTPAttributes(size: UInt64(data.count), permissions: 0o100_644)))
        }
        return names
    }

    private func makeHandle(_ state: OpenHandle) -> [UInt8] {
        let key = nextHandle
        nextHandle &+= 1
        handles[key] = state
        return [key]
    }

    private func okStatus(_ id: UInt32) -> SFTPPacket { status(id, SFTP.Status.ok, "") }
    private func noSuchFile(_ id: UInt32) -> SFTPPacket { status(id, SFTP.Status.noSuchFile, "no such file") }
    private func status(_ id: UInt32, _ code: UInt32, _ message: String) -> SFTPPacket {
        .status(id: id, code: code, message: message)
    }

    private func normalize(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    private func parent(_ path: String) -> String {
        let trimmed = normalize(path)
        guard trimmed != "/", let slash = trimmed.lastIndex(of: "/") else { return "/" }
        let head = String(trimmed[..<slash])
        return head.isEmpty ? "/" : head
    }

    private func name(_ path: String) -> String {
        let trimmed = normalize(path)
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }
}
