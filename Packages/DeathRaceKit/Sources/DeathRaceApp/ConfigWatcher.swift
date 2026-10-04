import Dispatch
import Foundation

/// Calls back after the settings file changes, once edits have settled.
///
/// Two kernel event sources, so nothing runs while nothing changes: one on the folder, which
/// sees editors that save by writing a new file and renaming it over the old one, and one on
/// the file itself, for editors that write in place. Until the folder exists, the nearest
/// folder above it that does is watched instead, to see it made. A change counts only when
/// the contents differ from the last ones seen.
@MainActor
final class ConfigWatcher {
    let file: URL
    var onChange: (() -> Void)?
    /// Quiet after the last event before reading the file.
    static let settle: TimeInterval = 0.15

    private var folderSource: (any DispatchSourceFileSystemObject)?
    /// The folder `folderSource` watches.
    private var watchedFolder: URL?
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var pending: DispatchWorkItem?
    private var lastContents: Data?

    init(file: URL) {
        self.file = file
        lastContents = FileManager.default.contents(atPath: file.path)
    }

    /// Starts watching, or starts again on the folder nearest the file that exists now.
    func start() {
        stop()
        let folder = Self.nearestFolder(to: file)
        watchedFolder = folder
        folderSource = Self.source(for: folder, events: .write) { [weak self] in
            self?.changed()
        }
        watchFile()
    }

    func stop() {
        folderSource?.cancel()
        folderSource = nil
        watchedFolder = nil
        fileSource?.cancel()
        fileSource = nil
        pending?.cancel()
        pending = nil
    }

    /// The file's own source, opened again whenever the file is replaced.
    private func watchFile() {
        fileSource?.cancel()
        fileSource = Self.source(for: file, events: [.write, .extend, .delete, .rename]) { [weak self] in
            self?.changed()
        }
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.settled() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    private func settled() {
        pending = nil
        if watchedFolder != Self.nearestFolder(to: file) {
            // A folder on the way to the file was made, or taken away.
            start()
        } else {
            // A save by rename leaves the old file's source watching nothing.
            watchFile()
        }
        let contents = FileManager.default.contents(atPath: file.path)
        guard contents != lastContents else { return }
        lastContents = contents
        onChange?()
    }

    /// A written file: the watcher has seen these contents already, so it does not report
    /// Death Race's own writes back to it.
    func noteWritten(_ contents: Data) {
        lastContents = contents
        if watchedFolder != Self.nearestFolder(to: file) { start() }
    }

    /// The file's folder, or the nearest folder above it that exists.
    static func nearestFolder(to file: URL) -> URL {
        var folder = file.deletingLastPathComponent()
        var isFolder: ObjCBool = false
        while folder.pathComponents.count > 1,
            !(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue)
        {
            folder = folder.deletingLastPathComponent()
        }
        return folder
    }

    private static func source(
        for url: URL, events: DispatchSource.FileSystemEvent, handler: @escaping @MainActor () -> Void
    ) -> (any DispatchSourceFileSystemObject)? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: events, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { handler() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}
