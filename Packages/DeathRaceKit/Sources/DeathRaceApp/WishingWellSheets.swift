import AppCore
import AppKit
import LegendsUI
import SwiftUI
import Vault

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
    @Environment(\.legends) private var palette

    var body: some View {
        SheetLayout(symbol: "chevron.right.2", title: name, subtitle: "↵ types it in; ⌘↵ runs it.") {
            ForEach(fill.fields, id: \.name) { field in
                LabeledField(field.name) {
                    if field.choices.isEmpty {
                        TextField(field.defaultValue ?? "", text: value(field.name))
                            .wrldField(monospaced: true)
                            .accessibilityLabel(field.name)
                    } else {
                        Picker(field.name, selection: value(field.name)) {
                            ForEach(field.choices, id: \.self) { choice in Text(choice).tag(choice) }
                        }
                        .labelsHidden()
                    }
                }
            }
            LabeledField("Command") {
                Text(fill.command)
                    .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(palette.ink)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.groundDeep))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.line, lineWidth: 1)
                    )
                    .accessibilityLabel("Command: \(fill.command)")
            }
        } buttons: {
            Button("Cancel") { done(nil) }
                .buttonStyle(.wrld(.ghost))
                .keyboardShortcut(.cancelAction)
            Button(WishingWell.insertTitle(panes: panes)) { done(.insert(fill.command)) }
                .buttonStyle(.wrld)
                .keyboardShortcut(.defaultAction)
            Button(WishingWell.runTitle(panes: panes)) { done(.run(fill.command)) }
                .buttonStyle(.wrld(.primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!fill.isComplete)
        }
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
    @Environment(\.legends) private var palette

    var body: some View {
        SheetLayout(symbol: "chevron.right.2", title: "Save to Wishing Well") {
            LabeledField("Name") {
                TextField("deploy", text: $name).wrldField()
            }
            LabeledField("Command") {
                // A set height: a text editor scrolls, so it asks for none of its own.
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 88)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.groundDeep))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(
                            palette.lineStrong, lineWidth: 1))
                Text(
                    "{{name}} asks for a value each time; {{env:prod|staging}} offers choices; {{version=2.4.1}} has a default."
                )
                .font(.system(size: 11)).foregroundStyle(palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.danger)
            }
        } buttons: {
            Button("Cancel") { done() }
                .buttonStyle(.wrld(.ghost))
                .keyboardShortcut(.cancelAction)
            Button("Save", action: submit)
                .buttonStyle(.wrld(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(isBlank(name) || isBlank(text))
        }
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
