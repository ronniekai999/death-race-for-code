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
    public var writeFile: @Sendable (_ bytes: [UInt8], _ path: String) -> Bool
    /// Create a folder (and any missing parents); false on failure.
    public var createDirectory: @Sendable (_ path: String) -> Bool

    public init(
        homeDirectory: @escaping @Sendable () -> String,
        entries: @escaping @Sendable (String) -> [FileEntry],
        readFile: @escaping @Sendable (String) -> [UInt8]?,
        writeFile: @escaping @Sendable ([UInt8], String) -> Bool,
        createDirectory: @escaping @Sendable (String) -> Bool
    ) {
        self.homeDirectory = homeDirectory
        self.entries = entries
        self.readFile = readFile
        self.writeFile = writeFile
        self.createDirectory = createDirectory
    }

    /// The real filesystem: `FileManager` for listing, `Vault/AtomicFile` for the atomic write
    /// a download lands through.
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
        writeFile: { bytes, path in (try? AtomicFile.write(bytes, to: path)) != nil },
        createDirectory: { path in
            (try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)) != nil
        }
    )
}
