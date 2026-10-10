import Foundation
import Vault

/// The local (Mac) side of Maze: listing a folder, reading a file to upload, and writing a
/// downloaded file. A struct of closures with a real `.local` default, injected so transfers
/// are testable without touching the disk — the same shape as `AppCore/GitHead.FileSystem`.
public struct LocalFileSystem: Sendable {
    /// The user's home directory, where a pane opens by default.
    public var homeDirectory: @Sendable () -> String
    /// A folder's entries, already classified and sorted; empty when it can't be read.
    public var entries: @Sendable (_ directory: String) -> [FileEntry]
    /// A whole file's bytes, or nil when it can't be read.
    public var readFile: @Sendable (_ path: String) -> [UInt8]?
    /// Write bytes to a path atomically; false on failure.
    public var writeFile: @Sendable (_ bytes: [UInt8], _ path: String, _ overwrite: Bool) -> Bool
    /// Test the destination itself, including dangling symbolic links. Listing rows are not authority.
    public var exists: @Sendable (_ path: String) throws -> Bool
    /// Open bounded streaming readers and staged writers off the main actor.
    public var openUpload: @Sendable (String) async throws -> TransferSource
    public var openDownload: @Sendable (String) async throws -> TransferDestination
    /// Create a folder (and any missing parents); false on failure.
    public var createDirectory: @Sendable (_ path: String) -> Bool

    public init(
        homeDirectory: @escaping @Sendable () -> String,
        entries: @escaping @Sendable (String) -> [FileEntry],
        readFile: @escaping @Sendable (String) -> [UInt8]?,
        writeFile: @escaping @Sendable ([UInt8], String, Bool) -> Bool,
        createDirectory: @escaping @Sendable (String) -> Bool,
        exists: (@Sendable (String) throws -> Bool)? = nil,
        openUpload: (@Sendable (String) async throws -> TransferSource)? = nil,
        openDownload: (@Sendable (String) async throws -> TransferDestination)? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.entries = entries
        self.readFile = readFile
        self.writeFile = writeFile
        self.createDirectory = createDirectory
        self.openUpload =
            openUpload ?? { path in
                guard let bytes = await Task.detached(operation: { readFile(path) }).value else {
                    throw SFTPError.invalid("could not read \(path)")
                }
                return TransferSource(size: UInt64(bytes.count)) { offset, count in
                    guard offset <= UInt64(bytes.count) else { throw SFTPError.invalid("invalid read offset") }
                    let start = Int(offset)
                    return Array(bytes[start..<min(bytes.count, start + count)])
                }
            }
        self.openDownload =
            openDownload ?? { path in
                let buffer = MemoryDownload()
                return TransferDestination(
                    write: { bytes, offset in try await buffer.write(bytes, offset: offset) },
                    commit: { overwrite in
                        let bytes = await buffer.bytes
                        guard await Task.detached(operation: { writeFile(bytes, path, overwrite) }).value else {
                            throw SFTPError.invalid("could not write \(path)")
                        }
                    })
            }
        self.exists =
            exists ?? { path in entries(Listing.parent(of: path)).contains { $0.name == Listing.name(of: path) } }
    }

    /// The real filesystem: FileManager listings and bounded descriptor IO with an
    /// atomic, cancellation-aware publish of completed downloads.
    public static let local = LocalFileSystem(
        homeDirectory: { NSHomeDirectory() },
        entries: { directory in
            let manager = FileManager.default
            guard let names = try? manager.contentsOfDirectory(atPath: directory) else { return [] }
            let entries = names.map { name -> FileEntry in
                let attributes = try? manager.attributesOfItem(atPath: Listing.join(directory, name))
                let type = attributes?[.type] as? FileAttributeType
                let kind: FileEntry.Kind =
                    type == .typeDirectory ? .directory : (type == .typeSymbolicLink ? .symlink : .file)
                let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
                let modified = (attributes?[.modificationDate] as? Date).map {
                    UInt32(min(Double(UInt32.max), max(0, $0.timeIntervalSince1970)))
                }
                return FileEntry(name: name, kind: kind, size: size, modified: modified)
            }
            return Listing.sorted(entries)
        },
        readFile: { path in (try? AtomicFile.read(path)) ?? nil },
        writeFile: { bytes, path, overwrite in
            do {
                let file = try LocalDownload(path: path)
                try file.write(bytes, offset: 0)
                try file.commit(overwrite: overwrite)
                return true
            } catch { return false }
        },
        createDirectory: { path in
            (try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)) != nil
        },
        exists: { try LocalDownload.exists($0) },
        openUpload: { path in
            let file = try await fileWorker { try LocalUpload(path: path) }
            return TransferSource(size: file.size) { offset, length in
                try await fileWorker { try file.read(offset: offset, length: length) }
            }
        },
        openDownload: { path in
            let file = try await fileWorker { try LocalDownload(path: path) }
            return TransferDestination(
                write: { bytes, offset in try await fileWorker { try file.write(bytes, offset: offset) } },
                commit: { overwrite in try await fileWorker { try file.commit(overwrite: overwrite) } })
        }
    )
}

/// Detached IO must inherit cancellation explicitly, especially during fsync before publish.
private func fileWorker<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
    try Task.checkCancellation()
    let worker = Task.detached {
        try Task.checkCancellation(); return try operation()
    }
    return try await withTaskCancellationHandler {
        try await worker.value
    } onCancel: {
        worker.cancel()
    }
}

// Only the in-memory test seam uses this fallback; the real filesystem stages on disk.
private actor MemoryDownload {
    var bytes: [UInt8] = []
    func write(_ chunk: [UInt8], offset: UInt64) throws {
        guard offset <= UInt64(2 << 30), chunk.count <= (2 << 30) - Int(offset) else {
            throw SFTPError.invalid("in-memory download too large")
        }
        let end = Int(offset) + chunk.count
        if end > bytes.count { bytes.append(contentsOf: repeatElement(0, count: end - bytes.count)) }
        bytes.replaceSubrange(Int(offset)..<end, with: chunk)
    }
}
