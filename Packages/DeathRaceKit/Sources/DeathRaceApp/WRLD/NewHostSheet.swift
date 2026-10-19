import AppKit
import LegendsUI
import SSHKit
import SwiftUI
import Vault

/// "New Host…": a sheet on the window in front, or a window of its own when there is none.
/// Adding opens the host in a new tab of that window, or, from Open in Maze, in Maze.
@MainActor
final class NewHostSheet {
    private let sheet: ThemedSheet
    private let view: NewHostView

    /// `subtitle` says what the host is for, under the title; `NewHostView.savedSubtitle`
    /// when nil. `add` saves the host and returns its id, or says what's wrong. `finished`
    /// hears once the sheet is gone: the new host's id, or nil when cancelled.
    init(
        jumpHosts: [(id: HostID, name: String)], subtitle: String? = nil, parent: NSWindow?, chrome: Chrome,
        add: @escaping @MainActor (HostDraft) async -> Result<HostID, WRLDService.AddFailure>,
        finished: @escaping @MainActor (HostID?) -> Void
    ) {
        let sheet = ThemedSheet(title: "New Host", parent: parent, chrome: chrome)
        self.sheet = sheet
        // Weak: the view is the panel's, and the panel is the sheet's.
        view = NewHostView(
            jumpHosts: jumpHosts.map { NewHostView.JumpHost(id: $0.id, name: $0.name) },
            subtitle: subtitle ?? NewHostView.savedSubtitle, add: add,
            done: { [weak sheet] id in
                sheet?.close()
                finished(id)
            })
    }

    var panel: NSPanel { sheet.panel }

    func show() {
        sheet.show(view)
    }
}

/// The fields, as the WRLD board's inspector lays them out: each under its label, User and
/// Port side by side.
struct NewHostView: View {
    struct JumpHost: Identifiable, Hashable {
        let id: HostID
        let name: String
    }

    enum SignInChoice: Hashable {
        case automatic, secureEnclave, keyFile
    }

    /// What New Host… says: where the host goes, and what it leaves alone.
    static let savedSubtitle = "Saved in WRLD on this Mac. Your ~/.ssh/config isn’t changed."
    /// What Open in Maze says with no host to open.
    static let mazeSubtitle = "Maze shows a host’s files beside this Mac’s. Add one and Maze opens on it."

    let jumpHosts: [JumpHost]
    let subtitle: String
    let add: @MainActor (HostDraft) async -> Result<HostID, WRLDService.AddFailure>
    /// The new host's id, or nil when cancelled.
    let done: @MainActor (HostID?) -> Void

    @State private var draft = HostDraft()
    @State private var signIn = SignInChoice.automatic
    @State private var keyFile = ""
    @State private var problem: String? = nil
    @State private var working = false
    @FocusState private var nameFocused: Bool
    @Environment(\.legends) private var palette

    var body: some View {
        SheetLayout(symbol: "server.rack", title: "New host", subtitle: subtitle) {
            LabeledField("Name") {
                TextField("prod-api", text: $draft.name).wrldField().focused($nameFocused)
            }
            LabeledField("Address") {
                TextField("10.0.4.21 or server.example.com", text: $draft.address).wrldField(monospaced: true)
            }
            HStack(alignment: .top, spacing: 10) {
                LabeledField("User") {
                    TextField("Your name on this Mac", text: $draft.user).wrldField(monospaced: true)
                }
                LabeledField("Port") {
                    TextField("22", text: $draft.port).wrldField(monospaced: true)
                }
                .frame(width: 90)
            }
            LabeledField("Sign in with") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Sign in with", selection: $signIn) {
                        Text("Automatic").tag(SignInChoice.automatic)
                        Text("Secure Enclave key").tag(SignInChoice.secureEnclave)
                        Text("Key file").tag(SignInChoice.keyFile)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    signInDetail
                }
            }
            // A jump host is one of WRLD's own; with none yet there is nothing to choose.
            if !jumpHosts.isEmpty {
                LabeledField("Jump host") {
                    Picker("Jump host", selection: $draft.jumpHostID) {
                        Text("None").tag(HostID?.none)
                        ForEach(jumpHosts) { host in
                            Text(host.name).tag(HostID?.some(host.id))
                        }
                    }
                    .labelsHidden()
                }
            }
            if let problem {
                Text(problem)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } buttons: {
            if working { ProgressView().controlSize(.small) }
            Button("Cancel") { done(nil) }
                .buttonStyle(.wrld(.ghost))
                .keyboardShortcut(.cancelAction)
            Button("Add host", action: submit)
                .buttonStyle(.wrld(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(working)
        }
        .onAppear { nameFocused = true }
    }

    /// What the chosen way of signing in means, or the key file to use.
    @ViewBuilder private var signInDetail: some View {
        switch signIn {
        case .automatic:
            note("Your ssh agent and keys, then a password if the server asks for one.")
        case .secureEnclave:
            note(
                """
                The key is made in this Mac’s Secure Enclave and never leaves it: it can’t be \
                backed up or moved to another Mac. Touch ID asks now, and at each login, where \
                macOS calls it “ctccardtoken”. The first connection signs in as usual and puts \
                the key on the server. Servers need OpenSSH 8.2 or later.
                """)
        case .keyFile:
            HStack(spacing: 8) {
                TextField("~/.ssh/id_ed25519", text: $keyFile).wrldField(monospaced: true)
                Button("Choose…", action: chooseKeyFile).buttonStyle(.wrld(.plain))
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5)).foregroundStyle(palette.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func submit() {
        var draft = draft
        switch signIn {
        case .automatic: draft.signIn = .automatic
        case .secureEnclave: draft.signIn = .newSecureEnclaveKey
        case .keyFile: draft.signIn = .keyFile((keyFile as NSString).expandingTildeInPath)
        }
        working = true
        problem = nil
        Task {
            let result = await add(draft)
            working = false
            switch result {
            case .success(let id): done(id)
            case .failure(let failure): problem = failure.sentence
            }
        }
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        if panel.runModal() == .OK, let url = panel.url { keyFile = url.path }
    }
}
