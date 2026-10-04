import AppKit
import ConfigKit
import UniformTypeIdentifiers

/// Why the settings file was not changed.
struct ConfigFileError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// The settings file, and what it said when last read.
@MainActor
final class ConfigStore {
    let url: URL
    private(set) var config = Config()
    /// What in the file could not be used, at the last read.
    private(set) var diagnostics: [ConfigDiagnostic] = []
    /// The file exists but could not be read.
    private(set) var readFailed = false
    /// After each write, with what was written, so a watcher does not report it back.
    var onWrite: ((Data) -> Void)?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        url = URL(fileURLWithPath: ConfigLocation.path(environment: environment, home: NSHomeDirectory()))
        load()
    }

    /// Reads the file again. A missing file is no error: it means every default.
    func load() {
        readFailed = false
        if let data = FileManager.default.contents(atPath: url.path) {
            (config, diagnostics) = Config.parse(String(decoding: data, as: UTF8.self))
        } else {
            readFailed = FileManager.default.fileExists(atPath: url.path)
            config = Config()
            diagnostics = []
        }
    }

    /// Changes the file with `change`, given its text (the template when there is none), writes
    /// it in one step, and reads it again; returns what was written. A file that is a link,
    /// into a dotfiles repository say, stays one: the file it points to is the one written.
    /// A file that exists but cannot be read, or is not UTF-8 text, is left alone: writing
    /// the template over it would lose it.
    @discardableResult
    func update(_ change: (String) -> String) throws -> Data {
        let manager = FileManager.default
        let target = url.resolvingSymlinksInPath()
        let current: String
        if manager.fileExists(atPath: target.path) {
            guard let contents = manager.contents(atPath: target.path) else {
                throw ConfigFileError("Death Race can’t read \(target.path), so it left the file as it is.")
            }
            guard let text = String(data: contents, encoding: .utf8) else {
                throw ConfigFileError("\(target.path) isn’t UTF-8 text, so Death Race left it as it is.")
            }
            current = text
        } else {
            current = ConfigSchema.template
        }
        let data = Data(change(current).utf8)
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        onWrite?(data)
        load()
        return data
    }

    /// Writes the template if there is no file yet.
    func createIfMissing() throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: url.path) else { return }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(ConfigSchema.template.utf8)
        try data.write(to: url, options: .withoutOverwriting)
        onWrite?(data)
    }

    /// Opens the file in the default text editor, creating it from the template first if
    /// there is none. The file has no extension, so it is opened with the editor for plain
    /// text rather than with whatever claims extensionless files.
    func openInEditor() throws {
        try createIfMissing()
        let workspace = NSWorkspace.shared
        if let editor = workspace.urlForApplication(toOpen: .plainText) {
            workspace.open(
                [url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: nil)
        } else {
            _ = workspace.open(url)
        }
    }

    /// Tells the user what could not be used, if anything: as a sheet on `window`, or as a
    /// modal alert without one.
    func reportProblems(in window: NSWindow?) {
        guard readFailed || !diagnostics.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if readFailed {
            alert.messageText = "Death Race could not read its settings"
            alert.informativeText = "\(url.path) exists but could not be opened. Every setting is at its default."
        } else {
            alert.messageText =
                diagnostics.count == 1
                ? "One setting could not be used" : "\(diagnostics.count) settings could not be used"
            let shown = diagnostics.prefix(6).map(\.description)
            let more = diagnostics.count > shown.count ? ["…and \(diagnostics.count - shown.count) more."] : []
            alert.informativeText =
                (shown + more).joined(separator: "\n") + "\n\nThose settings keep their defaults."
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Settings")
        if let window {
            Task { [weak self] in
                if await alert.beginSheetModal(for: window) == .alertSecondButtonReturn { try? self?.openInEditor() }
            }
        } else if alert.runModal() == .alertSecondButtonReturn {
            try? openInEditor()
        }
    }
}
