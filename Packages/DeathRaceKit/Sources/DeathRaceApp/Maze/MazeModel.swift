import LegendsUI
import Observation
import SFTPKit

/// What Maze shows and does: a folder on this Mac beside a folder on the host, and the
/// transfers between them. Everything the window needs, behind the `RemoteFiles` and
/// `LocalFileSystem` seams, so `DeathRaceAppTests` drives it headless with stand-ins.
@MainActor @Observable final class MazeModel {
    enum Side: Equatable, Sendable {
        case local
        case remote
    }

    var palette: LegendsPalette
    /// The host's name, for the window's title row.
    let hostName: String

    var localPath: String
    var remotePath = "/"
    var localRows: [FileEntry] = []
    var remoteRows: [FileEntry] = []
    /// The row picked in each pane, by name.
    var localSelected: String?
    var remoteSelected: String?
    var transfers = TransferQueue()
    /// What went wrong, as a sentence, until the next action.
    var problem: String?
    /// True while a listing is being fetched.
    var isLoading = false

    /// Asked before a transfer would replace a file that is already there. The window shows a
    /// sheet; headless tests answer directly. Answering false cancels the transfer.
    @ObservationIgnored var confirmOverwrite: @MainActor (String) async -> Bool = { _ in true }

    @ObservationIgnored private let files: any RemoteFiles
    @ObservationIgnored private let fileSystem: LocalFileSystem
    @ObservationIgnored private var running: [TransferID: Task<Void, any Error>] = [:]

    init(
        hostName: String, files: any RemoteFiles, fileSystem: LocalFileSystem = .local,
        palette: LegendsPalette
    ) {
        self.hostName = hostName
        self.files = files
        self.fileSystem = fileSystem
        self.palette = palette
        localPath = fileSystem.homeDirectory()
    }

    // MARK: - Listing

    /// Resolve the host's home directory and fill both panes.
    func start() async {
        refreshLocal()
        if let home = try? await files.realPath(".") { remotePath = home }
        await refreshRemote()
    }

    func refreshLocal() {
        localRows = fileSystem.entries(localPath)
        if let localSelected, !localRows.contains(where: { $0.name == localSelected }) { self.localSelected = nil }
    }

    func refreshRemote() async {
        isLoading = true
        defer { isLoading = false }
        do {
            remoteRows = Listing.remote(try await files.list(remotePath))
            problem = nil
            if let remoteSelected, !remoteRows.contains(where: { $0.name == remoteSelected }) {
                self.remoteSelected = nil
            }
        } catch {
            problem = "Could not read \(remotePath): \(Self.sentence(error))"
        }
    }

    // MARK: - Moving around

    /// Open a row: step into a directory, or pick a file.
    func open(_ entry: FileEntry, on side: Side) async {
        switch side {
        case .local:
            guard entry.isDirectory || entry.kind == .symlink else {
                localSelected = entry.name
                return
            }
            localPath = Listing.join(localPath, entry.name)
            localSelected = nil
            refreshLocal()
        case .remote:
            guard entry.isDirectory || entry.kind == .symlink else {
                remoteSelected = entry.name
                return
            }
            remotePath = Listing.join(remotePath, entry.name)
            remoteSelected = nil
            await refreshRemote()
        }
    }

    /// Step up to the parent folder.
    func goUp(on side: Side) async {
        switch side {
        case .local:
            localPath = Listing.parent(of: localPath)
            localSelected = nil
            refreshLocal()
        case .remote:
            remotePath = Listing.parent(of: remotePath)
            remoteSelected = nil
            await refreshRemote()
        }
    }

    // MARK: - Transfers

    /// Send the picked local file (or a named one, for a drop) to the host's folder.
    func upload(_ name: String? = nil) async {
        guard let name = name ?? localSelected else { return }
        await uploadFile(at: Listing.join(localPath, name), named: name)
    }

    /// Send a file from anywhere on this Mac — what a Finder drop onto the host pane does.
    func uploadFile(at localFile: String, named name: String) async {
        if remoteRows.contains(where: { $0.name == name }), await !confirmOverwrite(name) { return }
        guard let bytes = fileSystem.readFile(localFile) else {
            problem = "Could not read \(name) from this Mac."
            return
        }
        let remote = Listing.join(remotePath, name)
        let id = transfers.enqueue(.upload, name: name, localPath: localFile, remotePath: remote)
        transfers.begin(id, total: UInt64(bytes.count))
        await run(id) { [files] in
            try await files.upload(remote, bytes: bytes, attributes: .none) { [weak self] done, _ in
                Task { @MainActor in self?.transfers.progress(id, done: done) }
            }
        }
        await refreshRemote()
    }

    /// Bring the picked remote file down into the local folder.
    func download(_ name: String? = nil) async {
        guard let name = name ?? remoteSelected,
            let row = remoteRows.first(where: { $0.name == name }), !row.isDirectory
        else { return }
        if localRows.contains(where: { $0.name == name }), await !confirmOverwrite(name) { return }
        let remote = Listing.join(remotePath, name)
        let local = Listing.join(localPath, name)
        let id = transfers.enqueue(.download, name: name, localPath: local, remotePath: remote)
        transfers.begin(id, total: row.size)
        await run(id) { [files, fileSystem] in
            let bytes = try await files.download(remote) { [weak self] done, _ in
                Task { @MainActor in self?.transfers.progress(id, done: done) }
            }
            guard fileSystem.writeFile(bytes, local) else { throw MazeFailure.cannotWrite(local) }
        }
        refreshLocal()
    }

    /// Files dropped onto the host's pane, from Finder or from this Mac's pane: each goes
    /// into the folder the host's pane shows, one at a time so the window stays answerable.
    func upload(dropped paths: [String]) async {
        for path in paths {
            await uploadFile(at: path, named: Listing.name(of: path))
        }
    }

    /// Remote files dropped onto this Mac's pane. Only a path in the folder the host's pane
    /// shows is fetched, so a drag from anywhere else — stray text, another app — does
    /// nothing rather than something surprising.
    func download(dropped paths: [String]) async {
        for path in paths where Listing.parent(of: path) == remotePath {
            await download(Listing.name(of: path))
        }
    }

    /// Stop a transfer that is still going.
    func cancel(_ id: TransferID) {
        running[id]?.cancel()
        transfers.cancel(id)
    }

    func clearCompletedTransfers() {
        transfers.clearCompleted()
    }

    /// Close the connection. The one place the ssh subsystem is ended.
    func shutDown() async {
        for task in running.values { task.cancel() }
        running = [:]
        await files.shutDown()
    }

    /// Run a transfer's work, keeping it cancellable and recording how it ended.
    private func run(_ id: TransferID, _ work: @escaping @Sendable () async throws -> Void) async {
        let task = Task { try await work() }
        running[id] = task
        do {
            try await task.value
            transfers.finish(id)
        } catch is CancellationError {
            transfers.cancel(id)
        } catch {
            transfers.fail(id, Self.sentence(error))
        }
        running[id] = nil
    }

    enum MazeFailure: Error, Equatable {
        case cannotWrite(String)
    }

    /// An error as a sentence for a transfer row or the problem line.
    static func sentence(_ error: any Error) -> String {
        if let error = error as? MazeFailure {
            switch error {
            case .cannotWrite(let path): return "could not write \(path)"
            }
        }
        guard let error = error as? SFTPError else { return "\(error)" }
        switch error {
        case .status(_, let message) where !message.isEmpty: return message
        case .status(let code, _): return "the server refused it (code \(code))"
        case .transportClosed: return "the connection closed"
        case .timedOut: return "it took too long"
        case .truncated, .invalid, .unknownPacket, .unexpectedReply:
            return "the server sent something unexpected"
        }
    }
}
