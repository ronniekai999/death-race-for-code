import AppCore
import AppKit
import SwiftUI
import Vault

/// A Wishing Well sheet on the window in front, or a panel of its own when that window has
/// one already: a snippet's fields, or a selection being saved.
@MainActor
final class WishingWellSheet {
    private let panel: NSPanel
    private weak var parent: NSWindow?

    init(title: String, parent: NSWindow?) {
        self.parent = parent
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered,
            defer: false)
        panel.title = title
    }

    func show(_ view: some View) {
        panel.contentViewController = NSHostingController(rootView: view)
        if let parent, parent.attachedSheet == nil {
            parent.beginSheet(panel)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        } else {
            panel.orderOut(nil)
        }
    }
}

/// What a snippet's sheet was closed with.
enum SnippetChoice: Equatable {
    /// Typed in, without Return.
    case insert(String)
    /// Typed in, then Return.
    case run(String)
}

/// A snippet's fields, one per placeholder, and the command they make. ↵ inserts it and ⌘↵
/// runs it, as in Hear Me Calling; while the tab is armed the buttons say how many panes.
struct SnippetFillView: View {
    let name: String
    /// The panes it goes to: the active one, and every armed pane with it.
    let panes: Int
    @State var fill: SnippetFill
    let done: @MainActor (SnippetChoice?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                ForEach(fill.fields, id: \.name) { field in
                    if field.choices.isEmpty {
                        TextField(field.name, text: value(field.name), prompt: Text(field.defaultValue ?? ""))
                    } else {
                        Picker(field.name, selection: value(field.name)) {
                            ForEach(field.choices, id: \.self) { choice in Text(choice).tag(choice) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Text(fill.command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Command: \(fill.command)")
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(WishingWell.insertTitle(panes: panes)) { done(.insert(fill.command)) }
                    .keyboardShortcut(.defaultAction)
                Button(WishingWell.runTitle(panes: panes)) { done(.run(fill.command)) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!fill.isComplete)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func value(_ name: String) -> Binding<String> {
        Binding(get: { fill.values[name] ?? "" }, set: { fill.values[name] = $0 })
    }
}

/// A selection on its way into Wishing Well: its name and command, to change before saving.
struct SaveSnippetView: View {
    @State var name: String
    @State var text: String
    /// Saves the snippet; false when it couldn't be.
    let save: @MainActor (Snippet) -> Bool
    let done: @MainActor () -> Void
    @State private var problem: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                TextField("Name", text: $name)
                LabeledContent("Command") {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 72)
                }
            }
            .formStyle(.grouped)
            Text("Write {{name}} where the command should ask for a value each time.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { done() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBlank(name) || isBlank(text))
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func isBlank(_ text: String) -> Bool { text.allSatisfy(\.isWhitespace) }

    private func submit() {
        let snippet = Snippet(name: name.trimmingCharacters(in: .whitespacesAndNewlines), text: text)
        if save(snippet) {
            done()
        } else {
            problem = "WRLD couldn’t save the snippet."
        }
    }
}
