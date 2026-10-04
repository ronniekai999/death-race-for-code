import AppCore
import AppKit
import LegendsUI
import SSHKit
import SwiftUI
import Vault

/// The selected host, to look over and change: how it's reached (for a host WRLD
/// describes itself), its group, tags and Legend pin, its tunnels, what it runs on connect,
/// and a saved password. A change to how it's reached waits for Save, the rest applies at
/// once.
struct WRLDInspector: View {
    let model: WRLDBoardModel
    let host: WRLDHost
    @State private var draft: HostDraft
    @State private var keyFile = ""
    @State private var problem: String?
    @State private var tags: String
    @State private var naming = false
    @State private var newGroup = ""

    init(model: WRLDBoardModel, host: WRLDHost) {
        self.model = model
        self.host = host
        let draft = HostDraft(editing: host) ?? HostDraft(name: host.name)
        _draft = State(initialValue: draft)
        if case .keyFile(let path) = draft.signIn { _keyFile = State(initialValue: path) }
        _tags = State(initialValue: host.tags.joined(separator: ", "))
    }

    var body: some View {
        let palette = model.palette
        let status = model.status(of: host)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    StatusDotView(dot: status.dot, size: 10)
                    Text(host.name).font(.system(size: 22, weight: .bold)).foregroundStyle(palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if host.isLegend { ChipView(chip: HostChip("Legend")) }
                }
                Text(status.line).font(.system(size: 12)).foregroundStyle(palette.inkMuted)

                if host.connection != nil {
                    connectionFields
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel("Reached as ~/.ssh/config says")
                        Text(model.address(of: host))
                            .font(.system(size: 13, design: .monospaced)).foregroundStyle(palette.ink)
                        Text(
                            "WRLD keeps its group, tags, tunnels and what it runs on connect. Nothing in the file changes."
                        )
                        .font(.system(size: 12)).foregroundStyle(palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                groupField
                VStack(alignment: .leading, spacing: 5) {
                    FieldLabel("Tags")
                    TextField("prod, homelab", text: $tags)
                        .wrldField()
                        .onSubmit(saveTags)
                }
                Toggle(isOn: legend) { Text("Pin to Legends").foregroundStyle(palette.ink) }
                    .toggleStyle(.neon)
                if host.connection != nil {
                    Toggle(isOn: forwardAgent) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Forward your ssh agent").foregroundStyle(palette.ink)
                            Text("The server can sign in elsewhere with your keys while you're connected.")
                                .font(.system(size: 11)).foregroundStyle(palette.inkMuted)
                        }
                    }
                    .toggleStyle(.neon)
                }

                tunnelsField
                onConnectField
                if model.savedPasswords.contains(host.id) {
                    HStack {
                        Text("A password is saved in the Keychain.").font(.system(size: 12))
                            .foregroundStyle(palette.inkMuted)
                        Spacer(minLength: 0)
                        Button("Forget") { model.forgetPassword(host.id) }.buttonStyle(.wrld(.ghost))
                    }
                }

                HStack(spacing: 8) {
                    Button("Connect") { model.connect(host) }.buttonStyle(.wrld(.primary))
                    if let publicKey = publicKey {
                        Button("Copy Public Key") { WRLDBoardModel.copy(publicKey) }.buttonStyle(.wrld(.ghost))
                    }
                    Spacer(minLength: 0)
                    Button("Remove…") { WRLDRemoval.confirm(host, in: model) }.buttonStyle(.wrld(.destructive))
                }
                .padding(.top, 6)
            }
            .padding(18)
        }
        .background(palette.groundDeep)
        .alert("New Group", isPresented: $naming) {
            TextField("Name", text: $newGroup)
            Button("Add") {
                let name = newGroup
                model.edit { vault in
                    // A blank name makes no group, and moves the host nowhere.
                    if let id = vault.addGroup(named: name) { vault.move(host.id, to: id) }
                }
                newGroup = ""
            }
            Button("Cancel", role: .cancel) { newGroup = "" }
        } message: {
            Text("\(host.name) goes in it.")
        }
    }

    // MARK: - How it's reached

    @ViewBuilder private var connectionFields: some View {
        let palette = model.palette
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel("Name")
            TextField("prod-api", text: $draft.name).wrldField()
        }
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel("Address")
            TextField("10.0.4.21 or server.example.com", text: $draft.address).wrldField(monospaced: true)
        }
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                FieldLabel("User")
                TextField("Your name on this Mac", text: $draft.user).wrldField(monospaced: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                FieldLabel("Port")
                TextField("22", text: $draft.port).wrldField(monospaced: true)
            }
            .frame(width: 90)
        }
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel("Sign in with")
            Picker("Sign in with", selection: signInChoice) {
                Text("Automatic").tag(SignInChoice.automatic)
                ForEach(model.vault.keys.filter { $0.kind == .secureEnclave }) { key in
                    Text("Secure Enclave key · \(key.label)").tag(SignInChoice.secureEnclave(key.id))
                }
                Text("A key file").tag(SignInChoice.keyFile)
            }
            .labelsHidden()
            if case .keyFile = draft.signIn {
                HStack {
                    TextField("~/.ssh/id_ed25519", text: $keyFile).wrldField(monospaced: true)
                    Button("Choose…", action: chooseKeyFile).buttonStyle(.wrld)
                }
            }
            if case .secureEnclaveKey = draft.signIn {
                Text("The private key never leaves this Mac's Secure Enclave. Each login asks for your fingerprint.")
                    .font(.system(size: 11)).foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel("Jump host")
            Picker("Jump host", selection: $draft.jumpHostID) {
                Text("None").tag(HostID?.none)
                ForEach(model.vault.jumpChoices(for: host.id)) { choice in
                    Text(choice.name).tag(HostID?.some(choice.id))
                }
            }
            .labelsHidden()
        }
        if let problem {
            Text(problem).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.danger)
        }
        if edited != nil || problem != nil {
            HStack {
                Button("Revert") {
                    draft = HostDraft(editing: host) ?? draft
                    problem = nil
                }
                .buttonStyle(.wrld(.ghost))
                Spacer(minLength: 0)
                Button("Save", action: save).buttonStyle(.wrld(.primary)).keyboardShortcut(.defaultAction)
            }
        }
    }

    /// The draft as it would be saved, when it differs from the host.
    private var edited: HostDraft? {
        var current = draft
        if case .keyFile = current.signIn { current.signIn = .keyFile(keyFile) }
        return current == HostDraft(editing: host) ? nil : current
    }

    private func save() {
        guard let current = edited else { return }
        do {
            let updated = try current.applied(to: host)
            problem = nil
            model.edit { $0.update(updated) }
        } catch {
            problem = error.sentence
        }
    }

    enum SignInChoice: Hashable {
        case automatic, keyFile
        case secureEnclave(KeyID)
    }

    private var signInChoice: Binding<SignInChoice> {
        Binding(
            get: {
                switch draft.signIn {
                case .automatic, .newSecureEnclaveKey: .automatic
                case .secureEnclaveKey(let key): .secureEnclave(key)
                case .keyFile: .keyFile
                }
            },
            set: { choice in
                switch choice {
                case .automatic: draft.signIn = .automatic
                case .secureEnclave(let key): draft.signIn = .secureEnclaveKey(key)
                case .keyFile: draft.signIn = .keyFile(keyFile)
                }
            })
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        if panel.runModal() == .OK, let url = panel.url { keyFile = url.path }
    }

    /// The host's Secure Enclave key, for "Copy Public Key".
    private var publicKey: String? {
        guard case .secureEnclave(let id) = host.connection?.identity else { return nil }
        return model.vault.key(id)?.publicKey
    }

    // MARK: - The rest, applied at once

    @ViewBuilder private var groupField: some View {
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel("Group")
            Picker("Group", selection: group) {
                Text("None").tag(GroupID?.none)
                ForEach(model.vault.groups) { group in
                    Text(group.name).tag(GroupID?.some(group.id))
                }
            }
            .labelsHidden()
            Button("New Group…") { naming = true }.buttonStyle(.wrld(.ghost))
        }
    }

    private var group: Binding<GroupID?> {
        Binding(get: { host.groupID }, set: { id in model.edit { $0.move(host.id, to: id) } })
    }

    private var legend: Binding<Bool> {
        Binding(get: { host.isLegend }, set: { on in model.edit { $0.setLegend(host.id, on) } })
    }

    private var forwardAgent: Binding<Bool> {
        Binding(
            get: { host.connection?.forwardAgent ?? false },
            set: { on in
                guard case .wrld(var connection) = host.source else { return }
                connection.forwardAgent = on
                var updated = host
                updated.source = .wrld(connection)
                model.edit { $0.update(updated) }
            })
    }

    private func saveTags() {
        let list = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard list != host.tags else { return }
        var updated = host
        updated.tags = list
        model.edit { $0.update(updated) }
    }

    @ViewBuilder private var tunnelsField: some View {
        let palette = model.palette
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("Come & Go")
            ForEach(model.tunnels(on: host)) { row in
                HStack(spacing: 8) {
                    Text(SidebarModel.shortName(row.tunnel.spec))
                        .font(.system(size: 13, design: .monospaced)).foregroundStyle(palette.ink)
                    Spacer(minLength: 0)
                    Toggle(isOn: Binding(get: { row.isOpen }, set: { _ in model.toggleTunnel(row.id) })) {
                        EmptyView()
                    }
                    .toggleStyle(.neon)
                    .labelsHidden()
                    .accessibilityLabel(row.tunnel.spec.summary(host: host.name))
                }
            }
            Button("Add a Tunnel…") {
                model.tunnelHost = host.id
                model.place = .comeAndGo
            }
            .buttonStyle(.wrld(.ghost))
        }
    }

    @ViewBuilder private var onConnectField: some View {
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel("On connect, run from Wishing Well")
            Picker("On connect", selection: onConnect) {
                Text("Nothing").tag(SnippetID?.none)
                ForEach(model.vault.snippets) { snippet in
                    Text(snippet.name).tag(SnippetID?.some(snippet.id))
                }
            }
            .labelsHidden()
        }
    }

    private var onConnect: Binding<SnippetID?> {
        Binding(
            get: { host.onConnectSnippetID },
            set: { id in
                var updated = host
                updated.onConnectSnippetID = id
                model.edit { $0.update(updated) }
            })
    }
}

/// "Remove prod-api from WRLD?", naming what goes with it.
enum WRLDRemoval {
    @MainActor
    static func confirm(_ host: WRLDHost, in model: WRLDBoardModel) {
        let alert = NSAlert()
        alert.messageText = "Remove \(host.name) from WRLD?"
        var details: [String] = []
        let jumping = model.vault.hosts(jumpingThrough: host.id).map(\.name)
        if jumping.count == 1 { details.append("\(jumping[0]) goes through it, and will connect directly.") }
        if jumping.count > 1 {
            details.append(
                "\(ListFormatter.localizedString(byJoining: jumping)) go through it, and will connect directly.")
        }
        if !host.tunnels.isEmpty {
            details.append(host.tunnels.count == 1 ? "Its tunnel goes too." : "Its tunnels go too.")
        }
        if host.sshConfigAlias != nil { details.append("It stays in ~/.ssh/config.") }
        alert.informativeText = details.joined(separator: " ")
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let remove = { [weak model] in
            guard let model, let wrld = model.wrld else { return }
            if model.selected == host.id { model.selected = nil }
            Task { await wrld.remove(host.id) }
        }
        guard let window = NSApp.keyWindow else {
            if alert.runModal() == .alertFirstButtonReturn { remove() }
            return
        }
        Task {
            if await alert.beginSheetModal(for: window) == .alertFirstButtonReturn { remove() }
        }
    }
}
