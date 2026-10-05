/// What Maze needs of a host's filesystem, behind a seam so the window is driven headless in
/// tests with a stand-in. `SFTPClient` is the real one.
public protocol RemoteFiles: Sendable {
    func realPath(_ path: String) async throws -> String
    func list(_ path: String) async throws -> [SFTPName]
    func stat(_ path: String) async throws -> SFTPAttributes
    func mkdir(_ path: String, attributes: SFTPAttributes) async throws
    func remove(_ path: String) async throws
    func rmdir(_ path: String) async throws
    func rename(from oldPath: String, to newPath: String) async throws
    /// Download a whole file, reporting bytes done out of the total as it goes.
    func download(_ path: String, progress: @Sendable @escaping (UInt64, UInt64) -> Void) async throws -> [UInt8]
    /// Upload bytes, reporting bytes done out of the total as it goes.
    func upload(
        _ path: String, bytes: [UInt8], attributes: SFTPAttributes,
        progress: @Sendable @escaping (UInt64, UInt64) -> Void
    ) async throws
    func shutDown() async
}

extension SFTPClient: RemoteFiles {}
