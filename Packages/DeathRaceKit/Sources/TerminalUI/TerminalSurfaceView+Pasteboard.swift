import AppKit
import SurfaceCore
import VTCore

/// Pasting and dropping.
///
/// Text and files reach the program as a paste, marked as one when the program asked for
/// that (bracketed paste, mode 2004). Without the marks, a shell runs each pasted line as it
/// arrives, so before such a paste the view shows what would run and asks (`PasteWarning`).
extension TerminalSurfaceView {
    /// Edit › Paste (⌘V).
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        paste(text: text)
    }

    /// Sends `text` as a paste, asking first when it could run commands nobody saw.
    func paste(text: String) {
        guard let mirror = model?.mirror else { return }
        guard pasteProtection, let warning = PasteWarning(text: text, modes: mirror.modes) else {
            return sendPaste(text)
        }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = warning.title
        alert.informativeText = warning.message
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = Self.preview(warning.preview)
        Task { [weak self] in
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            self?.sendPaste(text)
        }
    }

    private func sendPaste(_ text: String) {
        guard let mirror = model?.mirror, let session, case .running = session.status else { return }
        guard session.send(InputEncoder.paste(text, modes: mirror.modes)) else {
            // More is waiting for the program than the session holds (16 MB).
            let alert = NSAlert()
            alert.messageText = "That paste is too large to send at once."
            alert.informativeText =
                "The program has not read enough of what was already sent. Paste less at a time, or save the text to a file and have the program read it."
            if let window { alert.beginSheetModal(for: window, completionHandler: nil) }
            return
        }
    }

    /// The text about to be pasted, in a small scrolling box under the question.
    private static func preview(_ text: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 440, height: 150)
        scroll.borderType = .bezelBorder
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.string = text
        }
        return scroll
    }

    // MARK: - Drops

    /// Files and text dragged onto the terminal.
    static let droppedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .string]

    override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: Self.droppedTypes) == nil ? [] : .copy
    }

    /// Dropped files become their paths, quoted for the shell as Terminal does; dropped text
    /// is pasted.
    override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let urls =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            paste(text: ShellQuoting.quote(paths: urls.map { $0.path(percentEncoded: false) }))
            return true
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return false }
        paste(text: text)
        return true
    }
}
