import Foundation
import SFTPKit
import Testing

@testable import SFTPKit

private typealias MazeModel = SFTPKit.MazeModel<Int>

/// A host's files in memory. `MazeModel` drives it exactly as it drives an `SFTPClient`: an
/// actor, so the model's transfer tasks reach it off the main actor as they really would.
actor FakeRemoteFiles: RemoteFiles {
    private var contents: [String: [UInt8]] = [:]
    private var directories: Set<String> = ["/", "/var", "/var/www"]
    private let home = "/var/www"
    /// Thrown by the next transfer, for the failure case.
    private var nextFailure: (any Error)?
    /// Makes a transfer run until it's cancelled, for the Stop case.
    private var holds = false
    private(set) var isShutDown = false

    init(files: [String: [UInt8]] = [:]) {
        contents = files
    }

    func failNextTransfer(with error: any Error) { nextFailure = error }
    func holdTransfers() { holds = true }
    func add(directory: String) { directories.insert(directory) }
    func file(_ path: String) -> [UInt8]? { contents[path] }

    func realPath(_ path: String) async throws -> String { path == "." ? home : path }

    func list(_ path: String) async throws -> [SFTPName] {
        guard directories.contains(path) else { throw SFTPError.status(code: 2, message: "No such file") }
        // A real server sends these two; Maze has to drop them.
        var names: [SFTPName] = [
            SFTPName(filename: ".", longname: "", attributes: .directoryAttributes),
            SFTPName(filename: "..", longname: "", attributes: .directoryAttributes),
        ]
        for directory in directories where directory != path && Listing.parent(of: directory) == path {
            names.append(
                SFTPName(
                    filename: Self.leaf(of: directory), longname: "", attributes: .directoryAttributes))
        }
        for (file, bytes) in contents where Listing.parent(of: file) == path {
            names.append(
                SFTPName(
                    filename: Self.leaf(of: file), longname: "",
                    attributes: SFTPAttributes(size: UInt64(bytes.count))))
        }
        return names
    }

    func stat(_ path: String) async throws -> SFTPAttributes {
        if directories.contains(path) { return .directoryAttributes }
        guard let bytes = contents[path] else { throw SFTPError.status(code: 2, message: "No such file") }
        return SFTPAttributes(size: UInt64(bytes.count))
    }

    func mkdir(_ path: String, attributes: SFTPAttributes) async throws { directories.insert(path) }
    func remove(_ path: String) async throws { contents[path] = nil }
    func rmdir(_ path: String) async throws { directories.remove(path) }

    func rename(from oldPath: String, to newPath: String) async throws {
        contents[newPath] = contents[oldPath]
        contents[oldPath] = nil
    }

    func download(_ path: String, progress: @Sendable @escaping (UInt64, UInt64) -> Void) async throws -> [UInt8] {
        try await beginTransfer()
        guard let bytes = contents[path] else { throw SFTPError.status(code: 2, message: "No such file") }
        progress(UInt64(bytes.count), UInt64(bytes.count))
        return bytes
    }

    func upload(
        _ path: String, bytes: [UInt8], attributes: SFTPAttributes, overwrite: Bool,
        progress: @Sendable @escaping (UInt64, UInt64) -> Void
    ) async throws {
        try await beginTransfer()
        guard overwrite || contents[path] == nil else { throw SFTPError.status(code: 4, message: "file exists") }
        contents[path] = bytes
        progress(UInt64(bytes.count), UInt64(bytes.count))
    }

    func shutDown() async { isShutDown = true }

    /// What every transfer does first: fail if the test said to, or run until cancelled.
    private func beginTransfer() async throws {
        if let nextFailure {
            self.nextFailure = nil
            throw nextFailure
        }
        while holds {
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    private static func leaf(of path: String) -> String {
        String(path[path.index(after: path.lastIndex(of: "/") ?? path.startIndex)...])
    }
}

extension SFTPAttributes {
    /// A directory, as a server reports one: `S_IFDIR` in the permission bits.
    fileprivate static let directoryAttributes = SFTPAttributes(permissions: 0o040_755)
}

/// This Mac's side in memory, so no test touches the disk. Locked, because the seam's
/// closures run on whichever thread a transfer is on, as the real one does.
final class FakeLocalDisk: @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [String: [UInt8]]
    let home: String

    init(home: String = "/Users/r/Downloads", files: [String: [UInt8]] = [:]) {
        self.home = home
        contents = files
    }

    func file(_ path: String) -> [UInt8]? { lock.withLock { contents[path] } }

    var fileSystem: LocalFileSystem {
        LocalFileSystem(
            homeDirectory: { [self] in home },
            entries: { [self] directory in
                let here = lock.withLock { contents.filter { Listing.parent(of: $0.key) == directory } }
                return Listing.sorted(
                    here.map { file, bytes in
                        FileEntry(
                            name: String(file.dropFirst(directory == "/" ? 1 : directory.count + 1)), kind: .file,
                            size: UInt64(bytes.count))
                    })
            },
            readFile: { [self] path in lock.withLock { contents[path] } },
            writeFile: { [self] bytes, path, overwrite in
                lock.withLock {
                    guard overwrite || contents[path] == nil else { return false }
                    contents[path] = bytes
                    return true
                }
            },
            createDirectory: { _ in true })
    }
}

@MainActor
private func makeModel(_ files: FakeRemoteFiles, _ disk: FakeLocalDisk = FakeLocalDisk()) -> MazeModel {
    MazeModel(
        hostName: "prod-api", files: files, fileSystem: disk.fileSystem,
        palette: 0)
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MazeModelTests {
    @Test func bothPanesList() async throws {
        let disk = FakeLocalDisk(files: ["/Users/r/Downloads/notes.md": Array("hello".utf8)])
        let host = FakeRemoteFiles(files: ["/var/www/index.html": Array("<h1>999</h1>".utf8)])
        let model = makeModel(host, disk)
        await model.start()
        // The host's folder came from REALPATH ".", not a guess.
        #expect(model.remotePath == "/var/www")
        #expect(model.localPath == "/Users/r/Downloads")
        #expect(model.localRows.map(\.name) == ["notes.md"])
        #expect(model.remoteRows.map(\.name) == ["index.html"])
        // "." and ".." are never rows.
        #expect(!model.remoteRows.contains { $0.name == "." || $0.name == ".." })
        #expect(model.problem == nil)
    }

    @Test func foldersComeFirst() async throws {
        let host = FakeRemoteFiles(files: ["/var/www/a.txt": [], "/var/www/z.txt": []])
        await host.add(directory: "/var/www/releases")
        let model = makeModel(host)
        await model.start()
        #expect(model.remoteRows.map(\.name) == ["releases", "a.txt", "z.txt"])
    }

    @Test func steppingIntoAFolderAndBackUp() async throws {
        let host = FakeRemoteFiles()
        await host.add(directory: "/var/www/releases")
        let model = makeModel(host)
        await model.start()
        let folder = try #require(model.remoteRows.first { $0.name == "releases" })
        await model.open(folder, on: .remote)
        #expect(model.remotePath == "/var/www/releases")
        await model.goUp(on: .remote)
        #expect(model.remotePath == "/var/www")
    }

    @Test func aFolderThatCannotBeReadSaysSo() async throws {
        let model = makeModel(FakeRemoteFiles())
        await model.start()
        model.remotePath = "/root"
        await model.refreshRemote()
        #expect(model.problem == "Could not read /root: No such file")
    }

    @Test func uploadMovesTheBytesAndShowsTheRow() async throws {
        let disk = FakeLocalDisk(files: ["/Users/r/Downloads/app.tar.gz": Array(repeating: 7, count: 2_048)])
        let host = FakeRemoteFiles()
        let model = makeModel(host, disk)
        await model.start()
        model.localSelected = "app.tar.gz"
        await model.upload()
        #expect(await host.file("/var/www/app.tar.gz") == Array(repeating: 7, count: 2_048))
        let transfer = try #require(model.transfers.transfers.first)
        #expect(transfer.direction == .upload)
        #expect(transfer.state == .finished)
        #expect(transfer.fraction == 1)
        // The host's pane shows what landed there.
        #expect(model.remoteRows.map(\.name) == ["app.tar.gz"])
    }

    @Test func downloadWritesTheFileHere() async throws {
        let disk = FakeLocalDisk()
        let host = FakeRemoteFiles(files: ["/var/www/index.html": Array("<h1>999</h1>".utf8)])
        let model = makeModel(host, disk)
        await model.start()
        model.remoteSelected = "index.html"
        await model.download()
        #expect(disk.file("/Users/r/Downloads/index.html") == Array("<h1>999</h1>".utf8))
        #expect(model.transfers.transfers.first?.state == .finished)
        #expect(model.localRows.map(\.name) == ["index.html"])
    }

    /// `Listing.remote` already refuses a name holding a separator, but Download is the line
    /// that decides where a host's bytes land on this Mac, so it checks for itself: a row that
    /// got past the listing somehow must still not write outside the folder on screen.
    @Test func downloadRefusesANameThatIsNotAName() async throws {
        let disk = FakeLocalDisk()
        let host = FakeRemoteFiles()
        let model = makeModel(host, disk)
        await model.start()
        model.remoteRows = [FileEntry(name: "../../.ssh/authorized_keys", kind: .file, size: 7)]
        await model.download("../../.ssh/authorized_keys")
        #expect(model.transfers.transfers.isEmpty)
        #expect(model.problem == "The host offered a file whose name can't be used here.")
        #expect(disk.file("/Users/r/.ssh/authorized_keys") == nil)
    }

    @Test func aFolderIsNeverDownloaded() async throws {
        let host = FakeRemoteFiles()
        await host.add(directory: "/var/www/releases")
        let model = makeModel(host)
        await model.start()
        model.remoteSelected = "releases"
        await model.download()
        #expect(model.transfers.transfers.isEmpty)
    }

    @Test func aFailedTransferSaysWhyOnItsRow() async throws {
        let disk = FakeLocalDisk(files: ["/Users/r/Downloads/notes.md": Array("hello".utf8)])
        let host = FakeRemoteFiles()
        await host.failNextTransfer(with: SFTPError.status(code: 3, message: "Permission denied"))
        let model = makeModel(host, disk)
        await model.start()
        await model.upload("notes.md")
        #expect(model.transfers.transfers.first?.state == .failed("Permission denied"))
    }

    @Test func aFileThisMacCannotReadNeverStartsATransfer() async throws {
        let model = makeModel(FakeRemoteFiles(), FakeLocalDisk())
        await model.start()
        await model.upload("gone.txt")
        #expect(model.transfers.transfers.isEmpty)
        #expect(model.problem == "Could not read gone.txt from this Mac.")
    }

    @Test func missingListingRowsDoNotBypassOverwriteProtection() async {
        let disk = FakeLocalDisk(files: ["/Users/r/Downloads/index.html": [9]])
        let host = FakeRemoteFiles(files: ["/var/www/index.html": [1]])
        let model = makeModel(host, disk)
        await model.start()
        model.remoteRows = []
        model.isLoading = true
        var asked = false
        model.confirmOverwrite = { _ in
            asked = true; return false
        }
        await model.upload("index.html")
        #expect(asked)
        #expect(await host.file("/var/www/index.html") == [1])
        #expect(model.transfers.transfers.isEmpty)
    }

    @Test func navigationDuringADownloadQuestionDoesNotChangeTheDestination() async {
        let disk = FakeLocalDisk(files: ["/Users/r/Downloads/index.html": [9]])
        let host = FakeRemoteFiles(files: ["/var/www/index.html": [1]])
        let model = makeModel(host, disk)
        await model.start()
        model.confirmOverwrite = { _ in
            model.localPath = "/elsewhere"; return true
        }
        await model.download("index.html")
        #expect(model.transfers.transfers.isEmpty)
        #expect(disk.file("/elsewhere/index.html") == nil)
        #expect(disk.file("/Users/r/Downloads/index.html") == [9])
    }

    @Test func replacingAFileAsksFirst() async throws {
        let disk = FakeLocalDisk(files: ["/Users/r/Downloads/index.html": Array("mine".utf8)])
        let host = FakeRemoteFiles(files: ["/var/www/index.html": Array("theirs".utf8)])
        let model = makeModel(host, disk)
        await model.start()
        var asked: [String] = []
        model.confirmOverwrite = { name in
            asked.append(name)
            return false
        }
        // The host already has index.html, so uploading it asks; No leaves both sides alone.
        await model.upload("index.html")
        #expect(asked == ["index.html"])
        #expect(model.transfers.transfers.isEmpty)
        #expect(await host.file("/var/www/index.html") == Array("theirs".utf8))
        // Yes goes ahead.
        model.confirmOverwrite = { _ in true }
        await model.upload("index.html")
        #expect(await host.file("/var/www/index.html") == Array("mine".utf8))
        // Downloading onto a file that's already here asks too.
        asked = []
        model.confirmOverwrite = { name in
            asked.append(name)
            return false
        }
        await model.download("index.html")
        #expect(asked == ["index.html"])
        #expect(disk.file("/Users/r/Downloads/index.html") == Array("mine".utf8))
    }

    @Test func stopEndsATransferThatIsStillGoing() async throws {
        let disk = FakeLocalDisk(files: ["/Users/r/Downloads/big.bin": Array(repeating: 0, count: 64)])
        let host = FakeRemoteFiles()
        let model = makeModel(host, disk)
        await model.start()
        await host.holdTransfers()
        let upload = Task { await model.upload("big.bin") }
        // Bounded: `Task.yield()` doesn't throw on cancellation, so an unbounded wait here
        // would spin on the main actor for ever if the transfer never registered, and a time
        // limit cannot interrupt that.
        for _ in 0..<10_000 where model.transfers.transfers.isEmpty { await Task.yield() }
        let id = try #require(model.transfers.transfers.first?.id, "the transfer never started")
        model.cancel(id)
        await upload.value
        #expect(model.transfers[id]?.state == .cancelled)
        #expect(await host.file("/var/www/big.bin") == nil)
        // Clear takes the rows that are done away, and this one is.
        model.clearCompletedTransfers()
        #expect(model.transfers.transfers.isEmpty)
    }

    @Test func aFinderDropUploadsEachFile() async throws {
        let disk = FakeLocalDisk(files: [
            "/Volumes/stick/a.bin": [1, 2, 3], "/Volumes/stick/b.bin": [4, 5],
        ])
        let host = FakeRemoteFiles()
        let model = makeModel(host, disk)
        await model.start()
        // A drop carries paths from anywhere on this Mac, not just the folder the pane shows.
        await model.upload(dropped: ["/Volumes/stick/a.bin", "/Volumes/stick/b.bin"])
        #expect(await host.file("/var/www/a.bin") == [1, 2, 3])
        #expect(await host.file("/var/www/b.bin") == [4, 5])
        #expect(model.transfers.transfers.map(\.name) == ["a.bin", "b.bin"])
        #expect(model.transfers.transfers.allSatisfy { $0.state == .finished })
    }

    @Test func aDropOntoThisMacOnlyFetchesWhatTheHostsPaneShows() async throws {
        let disk = FakeLocalDisk()
        let host = FakeRemoteFiles(files: [
            "/var/www/index.html": Array("here".utf8), "/etc/shadow": Array("elsewhere".utf8),
        ])
        let model = makeModel(host, disk)
        await model.start()
        // Only the first is in the folder on screen; the other is ignored, as is stray text.
        await model.download(dropped: ["/var/www/index.html", "/etc/shadow", "not a path at all"])
        #expect(disk.file("/Users/r/Downloads/index.html") == Array("here".utf8))
        #expect(disk.file("/Users/r/Downloads/shadow") == nil)
        #expect(model.transfers.transfers.map(\.name) == ["index.html"])
    }

    @Test func closingEndsTheConnection() async throws {
        let host = FakeRemoteFiles()
        let model = makeModel(host)
        await model.start()
        await model.shutDown()
        #expect(await host.isShutDown)
    }

    @Test func everyFailureReadsAsASentence() {
        #expect(MazeModel.sentence(SFTPError.status(code: 3, message: "Permission denied")) == "Permission denied")
        #expect(MazeModel.sentence(SFTPError.status(code: 4, message: "")) == "the server refused it (code 4)")
        #expect(MazeModel.sentence(SFTPError.transportClosed) == "the connection closed")
        #expect(MazeModel.sentence(SFTPError.timedOut) == "it took too long")
        #expect(MazeModel.sentence(SFTPError.truncated) == "the server sent something unexpected")
        #expect(MazeModel.sentence(MazeModel.MazeFailure.cannotWrite("/x/y")) == "could not write /x/y")
    }
}
