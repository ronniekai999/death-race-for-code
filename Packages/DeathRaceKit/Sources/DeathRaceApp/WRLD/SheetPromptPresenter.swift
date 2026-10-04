import AppKit
import SSHKit

/// ssh's questions as sheets on the window in front: a new host key to trust, a password
/// with "Save in the Keychain", a one-time code, a yes-or-no question. A question whose ssh
/// ends while its sheet is up takes the sheet down, answering no.
@MainActor
final class SheetPromptPresenter: PromptPresenter {
    func answer(_ question: AskpassQuestion) async -> PromptAnswer {
        let sheet = PromptSheet(question)
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey }
        let response = await withTaskCancellationHandler {
            await sheet.run(on: window)
        } onCancel: {
            Task { @MainActor in sheet.dismiss() }
        }
        return sheet.answer(for: response)
    }

    /// The pane already says it's connecting, and macOS shows its own Touch ID panel for a
    /// Secure Enclave key: nothing more to show.
    func notice(_ prompt: AskpassPrompt, for context: AskpassContext) async {}
}

/// One question's alert, its fields, and what its buttons mean.
@MainActor
private final class PromptSheet {
    let question: AskpassQuestion
    let alert = NSAlert()
    private var field: NSTextField?
    private var remember: NSButton?
    private weak var window: NSWindow?
    private var isModal = false

    init(_ question: AskpassQuestion) {
        self.question = question
        let prompt = question.prompt
        let host = question.context.hostName
        switch prompt.kind {
        case .newHostKey(let address, let keyType, let fingerprint):
            alert.messageText = "Trust \(host)’s host key?"
            alert.informativeText = """
                This is the first connection to \(address). Its \(keyType ?? "host") key’s fingerprint is:

                \(fingerprint ?? "(not given)")

                Trust it only if it matches the fingerprint the server shows, or the one its administrator gave you.
                """
            alert.addButton(withTitle: "Trust and Connect")
            alert.addButton(withTitle: "Cancel")
        case .password(let hop):
            alert.messageText = "Password for \(hop.user)@\(hop.host)"
            alert.informativeText =
                question.savedSecretFailed ? "The saved password didn’t work." : "To connect to \(host)."
            addField(secret: true)
        case .keyboardInteractive(let hop, let text):
            alert.messageText = "\(hop.user)@\(hop.host) asks:"
            alert.informativeText =
                question.savedSecretFailed ? "\(text)\n\nThe saved password didn’t work." : text
            addField(secret: true)
        case .passphrase(let file):
            alert.messageText = "Passphrase for \((file as NSString).lastPathComponent)"
            alert.informativeText =
                question.savedSecretFailed ? "The saved passphrase didn’t work." : "To connect to \(host) with \(file)."
            addField(secret: true)
        case .pin:
            alert.messageText = "PIN for your security key"
            alert.informativeText = "To connect to \(host)."
            addField(secret: true)
        case .confirmation(let text):
            alert.messageText = text
            alert.addButton(withTitle: "Yes")
            alert.addButton(withTitle: "Cancel")
        case .notice(let text), .other(let text):
            alert.messageText = "ssh asks:"
            alert.informativeText = text
            addField(secret: prompt.isSecret)
        }
    }

    /// A field for the answer, and "Save in the Keychain" when there is a place to save it.
    private func addField(secret: Bool) {
        let field = secret ? NSSecureTextField() : NSTextField()
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.setAccessibilityLabel(alert.messageText)
        var views: [NSView] = [field]
        if question.canRemember {
            let remember = NSButton(checkboxWithTitle: "Save in the Keychain", target: nil, action: nil)
            // Asked again after the saved one failed: saving the new one replaces it.
            remember.state = question.savedSecretFailed ? .on : .off
            views.append(remember)
            self.remember = remember
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: question.canRemember ? 56 : 24)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        self.field = field
    }

    /// Shows the sheet on `window`, or as a dialog of its own when there is none.
    func run(on window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window, window.attachedSheet == nil {
            self.window = window
            return await alert.beginSheetModal(for: window)
        }
        isModal = true
        defer { isModal = false }
        return alert.runModal()
    }

    /// Takes the sheet down, as Cancel.
    func dismiss() {
        if let window, alert.window.sheetParent === window {
            window.endSheet(alert.window, returnCode: .cancel)
        } else if isModal {
            NSApp.abortModal()
        }
    }

    func answer(for response: NSApplication.ModalResponse) -> PromptAnswer {
        guard response == .alertFirstButtonReturn else { return .cancel }
        if let field {
            return .text(field.stringValue, remember: remember?.state == .on)
        }
        return .yes
    }
}
