import LegendsUI
import SwiftUI
import Vault

/// Open in Maze from a pane with no host of its own: which host's files. A button per host,
/// Legends first; picking one is the answer, so there is nothing to confirm.
///
/// Return takes the first and ⌘2 to ⌘9 the next, each row saying which, so the palette's
/// keyboard-only Open in Maze ends without the mouse. Keys rather than a selection walked
/// with the arrows: a button takes focus only with Full Keyboard Access on.
struct MazeHostView: View {
    struct Choice: Identifiable, Hashable {
        let id: HostRef
        let name: String
        /// Where it is, when WRLD knows: an `~/.ssh/config` name it couldn't read has none.
        let address: String?
    }

    let choices: [Choice]
    /// The host picked, or nil when cancelled.
    let done: @MainActor (HostRef?) -> Void
    @Environment(\.legends) private var palette

    /// How many fit before the list scrolls. A scrolling list asks for no height of its own,
    /// so past this it is given one, as the snippet editor is: about seven and a half rows,
    /// the half saying there is more.
    private static let visibleRows = 7
    private static let scrollingHeight: CGFloat = 255

    var body: some View {
        SheetLayout(
            symbol: "folder", title: "Open in Maze", subtitle: "This pane is on this Mac. Which host’s files?"
        ) {
            if choices.count > Self.visibleRows {
                ScrollView { rows }.frame(height: Self.scrollingHeight)
            } else {
                rows
            }
        } buttons: {
            Button("Cancel") { done(nil) }
                .buttonStyle(.wrld(.ghost))
                .keyboardShortcut(.cancelAction)
        }
    }

    private var rows: some View {
        VStack(spacing: 6) {
            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                Button {
                    done(choice.id)
                } label: {
                    HStack(spacing: 10) {
                        Text(Self.keyHint(index))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.inkFaint)
                            .frame(width: 22, alignment: .leading)
                        // The name before the address, when one has to give.
                        Text(choice.name).layoutPriority(1)
                        Spacer(minLength: 12)
                        if let address = choice.address {
                            Text(address)
                                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(palette.inkFaint)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.wrld)
                .keyboardShortcut(Self.shortcut(index))
                .accessibilityLabel([choice.name, choice.address].compactMap { $0 }.joined(separator: ", "))
            }
        }
    }

    /// Return for the first row, ⌘2 to ⌘9 for the next eight, and none past them.
    private static func shortcut(_ index: Int) -> KeyboardShortcut? {
        if index == 0 { return .defaultAction }
        guard index < 9 else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
    }

    private static func keyHint(_ index: Int) -> String {
        if index == 0 { return "↵" }
        return index < 9 ? "⌘\(index + 1)" : ""
    }
}
