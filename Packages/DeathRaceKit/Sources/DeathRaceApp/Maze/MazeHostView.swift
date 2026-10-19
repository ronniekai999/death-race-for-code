import LegendsUI
import SwiftUI
import Vault

/// Open in Maze from a pane with no host of its own: which host's files. A button per host,
/// Legends first; picking one is the answer, so there is nothing to confirm.
struct MazeHostView: View {
    struct Choice: Identifiable, Hashable {
        let id: HostID
        let name: String
        /// Where it is, when WRLD knows: an `~/.ssh/config` name it couldn't read has none.
        let address: String?
    }

    let choices: [Choice]
    /// The host picked, or nil when cancelled.
    let done: @MainActor (HostID?) -> Void
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
            ForEach(choices) { choice in
                Button {
                    done(choice.id)
                } label: {
                    HStack(spacing: 10) {
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
                .accessibilityLabel([choice.name, choice.address].compactMap { $0 }.joined(separator: ", "))
            }
        }
    }
}
