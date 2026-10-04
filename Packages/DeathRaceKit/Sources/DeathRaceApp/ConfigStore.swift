import AppKit
import ConfigKit
import UniformTypeIdentifiers

/// The settings file, and what it said when last read.
@MainActor
final class ConfigStore {
    let url: URL
    private(set) var config = Config()
    /// What in the file could not be used, at the last read.
    private(set) var diagnostics: [ConfigDiagnostic] = []
    /// The file exists but could not be read.
    private(set) var readFailed = false

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

    /// Opens the file in the default text editor, creating it from the template first if
    /// there is none. The file has no extension, so it is opened with the editor for plain
    /// text rather than with whatever claims extensionless files.
    func openInEditor() throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(ConfigSchema.template.utf8).write(to: url, options: .withoutOverwriting)
        }
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
