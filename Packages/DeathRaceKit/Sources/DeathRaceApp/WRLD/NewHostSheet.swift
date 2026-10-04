import AppKit
import SSHKit
import SwiftUI
import Vault

/// "New Host…": a sheet on the window in front, or a window of its own when there is none.
/// Adding opens the host in a new tab of that window.
@MainActor
final class NewHostSheet {
    private let panel: NSPanel
    private weak var parent: NSWindow?

    /// `add` saves the host and returns its id, or says what's wrong. `finished` hears once
    /// the sheet is gone: the new host's id, or nil when cancelled.
    init(
        jumpHosts: [(id: HostID, name: String)], parent: NSWindow?,
        add: @escaping @MainActor (HostDraft) async -> Result<HostID, WRLDService.AddFailure>,
        finished: @escaping @MainActor (HostID?) -> Void
    ) {
        self.parent = parent
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420), styleMask: [.titled], backing: .buffered,
            defer: false)
        panel.title = "New Host"
        let view = NewHostView(
            jumpHosts: jumpHosts.map { NewHostView.JumpHost(id: $0.id, name: $0.name) },
            add: add,
            done: { [weak self] id in
                self?.close()
                finished(id)
            })
        panel.contentViewController = NSHostingController(rootView: view)
    }

    func show() {
        if let parent, parent.attachedSheet == nil {
            parent.beginSheet(panel)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func close() {
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        } else {
            panel.orderOut(nil)
        }
    }
}

/// The fields, as the WRLD board's inspector words them.
struct NewHostView: View {
    struct JumpHost: Identifiable, Hashable {
        let id: HostID
        let name: String
    }

    enum SignInChoice: Hashable {
        case automatic, secureEnclave, keyFile
    }

    let jumpHosts: [JumpHost]
    let add: @MainActor (HostDraft) async -> Result<HostID, WRLDService.AddFailure>
    /// The new host's id, or nil when cancelled.
    let done: @MainActor (HostID?) -> Void

    @State private var draft = HostDraft()
    @State private var signIn = SignInChoice.automatic
    @State private var keyFile = ""
    @State private var problem: String? = nil
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                TextField("Name", text: $draft.name, prompt: Text("prod-api"))
                TextField("Address", text: $draft.address, prompt: Text("10.0.4.21 or server.example.com"))
                TextField("User", text: $draft.user, prompt: Text("Your name on this Mac"))
                TextField("Port", text: $draft.port, prompt: Text("22"))
                Picker("Jump host", selection: $draft.jumpHostID) {
                    Text("None").tag(HostID?.none)
                    ForEach(jumpHosts) { host in
                        Text(host.name).tag(HostID?.some(host.id))
                    }
                }
                Picker("Sign in with", selection: $signIn) {
                    Text("Automatic").tag(SignInChoice.automatic)
                    Text("A new Secure Enclave key").tag(SignInChoice.secureEnclave)
                    Text("A key file").tag(SignInChoice.keyFile)
                }
                if signIn == .keyFile {
                    HStack {
                        TextField("Key file", text: $keyFile, prompt: Text("~/.ssh/id_ed25519"))
                        Button("Choose…", action: chooseKeyFile)
                    }
                }
            }
            .formStyle(.grouped)
            if signIn == .secureEnclave {
                Text(
                    """
                    The key is made in this Mac’s Secure Enclave and never leaves it: it can’t be \
                    backed up or moved to another Mac. Touch ID asks now, and at each login, where \
                    macOS calls it “ctccardtoken”. The first connection signs in as usual and puts \
                    the key on the server. Servers need OpenSSH 8.2 or later.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Add Host", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
            }
        }
        .padding(20)
        .frame(width: 460)
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
