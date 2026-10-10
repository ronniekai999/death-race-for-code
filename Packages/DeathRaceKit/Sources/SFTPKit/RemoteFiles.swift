/// What Maze needs of a host's filesystem, behind a seam so the window is driven headless in
/// tests with a stand-in. `SFTPClient` is the real one.
public protocol RemoteFiles: Sendable {
    func realPath(_ path: String) async throws -> String
    func list(_ path: String) async throws -> [SFTPName]
    func stat(_ path: String) async throws -> SFTPAttributes
    func lstat(_ path: String) async throws -> SFTPAttributes
    func mkdir(_ path: String, attributes: SFTPAttributes) async throws
    func remove(_ path: String) async throws
    func rmdir(_ path: String) async throws
    func rename(from oldPath: String, to newPath: String) async throws
    /// Download a whole file, reporting bytes done out of the total as it goes.
    func download(_ path: String, progress: @Sendable @escaping (UInt64, UInt64) -> Void) async throws -> [UInt8]
    /// Upload bytes, reporting bytes done out of the total as it goes.
    func upload(
        _ path: String, bytes: [UInt8], attributes: SFTPAttributes, overwrite: Bool,
        progress: @Sendable @escaping (UInt64, UInt64) -> Void
    ) async throws
    func upload(
        _ path: String, source: TransferSource, overwrite: Bool,
        progress: @Sendable @escaping (UInt64, UInt64) -> Void) async throws
    func download(
        _ path: String, destination: TransferDestination,
        progress: @Sendable @escaping (UInt64, UInt64) -> Void) async throws
    func shutDown() async
}

extension SFTPClient: RemoteFiles {}

public extension RemoteFiles {
    func lstat(_ path: String) async throws -> SFTPAttributes { try await stat(path) }

    // Compatibility for small, in-memory test doubles. SFTPClient implements bounded I/O.
    func upload(
        _ path: String, source: TransferSource, overwrite: Bool,
        progress: @Sendable @escaping (UInt64, UInt64) -> Void
    ) async throws {
        guard source.size <= UInt64(2 << 30) else { throw SFTPError.invalid("in-memory upload too large") }
        var bytes: [UInt8] = []
        while UInt64(bytes.count) < source.size {
            try Task.checkCancellation()
            let chunk = try await source.read(UInt64(bytes.count), SFTPClient.chunkSize)
            guard !chunk.isEmpty, UInt64(bytes.count + chunk.count) <= source.size else {
                throw SFTPError.invalid("the local file changed during upload")
            }
            bytes.append(contentsOf: chunk)
        }
        try await upload(path, bytes: bytes, attributes: .none, overwrite: overwrite, progress: progress)
    }

    func download(
        _ path: String, destination: TransferDestination,
        progress: @Sendable @escaping (UInt64, UInt64) -> Void
    ) async throws {
        let bytes = try await download(path, progress: progress)
        try Task.checkCancellation()
        try await destination.write(bytes, 0)
    }
}
