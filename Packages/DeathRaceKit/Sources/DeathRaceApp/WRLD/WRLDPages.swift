import AppCore
import AppKit
import LegendsUI
import SSHKit
import SwiftUI
import Vault

/// A page's heading: its tile, eyebrow and title, and a word at the right.
struct PageHeading: View {
    let symbol: String
    let eyebrow: String
    let title: String
    var detail: String?
    @Environment(\.legends) private var palette

    var body: some View {
        HStack(spacing: 10) {
            Tile(symbol: symbol)
            VStack(alignment: .leading, spacing: 1) {
                Eyebrow(eyebrow)
                Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(palette.ink)
            }
            Spacer(minLength: 0)
            if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(palette.inkMuted) }
        }
    }
}

/// A rounded row on the deep ground, as Come & Go's tunnels are drawn.
struct PageRow<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.legends) private var palette

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.groundDeep))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.line, lineWidth: 1))
    }
}

// MARK: - Keys

/// This Mac's Secure Enclave keys WRLD made, and the public keys in ~/.ssh.
struct WRLDKeysPage: View {
    let model: WRLDBoardModel

    var body: some View {
        let palette = model.palette
        let enclave = model.vault.keys.filter { $0.kind == .secureEnclave }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PageHeading(symbol: "key", eyebrow: "Vault", title: "Keys")
                Eyebrow("This Mac’s Secure Enclave", count: enclave.count).padding(.top, 6)
                if enclave.isEmpty {
                    Text("New Host… makes one: it never leaves this Mac, and each login asks for Touch ID.")
                        .font(.system(size: 12)).foregroundStyle(palette.inkMuted)
                }
                ForEach(enclave) { key in
                    KeyRow(
                        model: model, title: key.label, kind: "Secure Enclave · Touch ID", publicKey: key.publicKey,
                        usedBy: model.vault.hosts.filter { $0.connection?.identity == .secureEnclave(key.id) }.map(
                            \.name))
                }
                Eyebrow("Key files in ~/.ssh", count: model.keyFiles.count).padding(.top, 6)
                ForEach(model.keyFiles) { file in
                    KeyRow(
                        model: model, title: file.name,
                        kind: String(file.publicKey.split(separator: " ").first ?? "key"), publicKey: file.publicKey,
                        usedBy: [])
                }
            }
            .padding(18)
        }
        .onAppear { model.refreshFiles() }
    }
}

struct KeyRow: View {
    let model: WRLDBoardModel
    let title: String
    let kind: String
    let publicKey: String
    let usedBy: [String]

    var body: some View {
        let palette = model.palette
        PageRow {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.ink)
                    ChipView(chip: HostChip(kind, isKey: true))
                    Spacer(minLength: 0)
                    Button("Copy Public Key") { WRLDBoardModel.copy(publicKey) }.buttonStyle(.wrld(.ghost))
                }
                Text(publicKey)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.inkFaint)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                if !usedBy.isEmpty {
                    Text("Signs in to " + ListFormatter.localizedString(byJoining: usedBy))
                        .font(.system(size: 12)).foregroundStyle(palette.inkMuted)
                }
            }
        }
    }
}

// MARK: - Wishing Well

/// The snippets: each with its command and fields, Insert and Run into the window in
/// front, and a form to add or change one.
struct WishingWellPage: View {
    let model: WRLDBoardModel
    @State private var expanded: SnippetID?
    @State private var editing: Snippet?

    var body: some View {
        let palette = model.palette
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PageHeading(
                    symbol: "chevron.right.2", eyebrow: "Vault", title: "Wishing Well",
                    detail: WRLDBoard.counted(model.vault.snippets.count, "snippet"))
                Text("Insert and Run type into the active pane of the window in front, and every armed pane with it.")
                    .font(.system(size: 12)).foregroundStyle(palette.inkMuted)
                if let editing {
                    SnippetEditor(model: model, snippet: editing) { self.editing = nil }
                        .id(editing.id)
                } else {
                    Button("New Snippet") { editing = Snippet(name: "", text: "") }.buttonStyle(.wrld)
                }
                ForEach(model.vault.snippets) { snippet in
                    SnippetRow(
                        model: model, snippet: snippet, isExpanded: expanded == snippet.id,
                        toggle: { expanded = expanded == snippet.id ? nil : snippet.id },
                        edit: { editing = snippet })
                }
            }
            .padding(18)
        }
    }
}

struct SnippetRow: View {
    let model: WRLDBoardModel
    let snippet: Snippet
    let isExpanded: Bool
    let toggle: () -> Void
    let edit: () -> Void
    @State private var fill: SnippetFill

    init(
        model: WRLDBoardModel, snippet: Snippet, isExpanded: Bool, toggle: @escaping () -> Void,
        edit: @escaping () -> Void
    ) {
        self.model = model
        self.snippet = snippet
        self.isExpanded = isExpanded
        self.toggle = toggle
        self.edit = edit
        _fill = State(initialValue: SnippetFill(snippet.text))
    }

    var body: some View {
        let palette = model.palette
        let uses = model.state.uses(of: snippet.id)
        PageRow {
            VStack(alignment: .leading, spacing: 8) {
                // The name and command open and close it; the fields and buttons don't.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("»").foregroundStyle(palette.accent)
                        Text(snippet.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.ink)
                        Spacer(minLength: 0)
                        if uses > 0 {
                            Text(uses == 1 ? "used once" : "used \(uses) times")
                                .font(.system(size: 11)).foregroundStyle(palette.inkFaint)
                        }
                    }
                    Text(snippet.text)
                        .font(.system(size: 13, design: .monospaced)).foregroundStyle(palette.ink)
                        .lineLimit(isExpanded ? nil : 2)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(isExpanded ? "Hides its fields" : "Shows its fields, Insert and Run")
                if isExpanded {
                    ForEach(fill.fields, id: \.name) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            FieldLabel(field.name)
                            if field.choices.isEmpty {
                                TextField(field.defaultValue ?? "", text: value(field.name))
                                    .wrldField(monospaced: true)
                            } else {
                                Picker(field.name, selection: value(field.name)) {
                                    ForEach(field.choices, id: \.self) { choice in Text(choice).tag(choice) }
                                }
                                .labelsHidden()
                            }
                        }
                    }
                    if !fill.fields.isEmpty {
                        Text(fill.command)
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.inkMuted)
                            .lineLimit(3)
                    }
                    HStack(spacing: 8) {
                        Button("Insert") { type(run: false) }.buttonStyle(.wrld)
                        Button("Run") { type(run: true) }.buttonStyle(.wrld(.primary)).disabled(!fill.isComplete)
                        Spacer(minLength: 0)
                        Button("Edit") { edit() }.buttonStyle(.wrld(.ghost))
                        Button("Remove…") { confirmRemoval() }.buttonStyle(.wrld(.destructive))
                    }
                }
            }
        }
        // The fill is seeded once per row; after the snippet's command is edited, rebuild it
        // so Insert and Run use the new text and show the new fields.
        .onChange(of: snippet.text) { _, text in fill = SnippetFill(text) }
    }

    private func value(_ name: String) -> Binding<String> {
        Binding(get: { fill.values[name] ?? "" }, set: { fill.values[name] = $0 })
    }

    private func type(run: Bool) {
        model.host?.typeSnippet(fill.command, run: run, from: snippet.id)
    }

    private func confirmRemoval() {
        let alert = NSAlert()
        alert.messageText = "Remove “\(snippet.name)” from Wishing Well?"
        let hosts = model.vault.hosts(runningOnConnect: snippet.id).map(\.name)
        if !hosts.isEmpty {
            alert.informativeText =
                "\(ListFormatter.localizedString(byJoining: hosts)) run\(hosts.count == 1 ? "s" : "") it on connect, and will run nothing."
        }
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let id = snippet.id
        Task {
            guard let window = NSApp.keyWindow,
                await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
            else { return }
            model.edit { $0.removeSnippet(id) }
        }
    }
}

/// A snippet's name and command, to add or change.
struct SnippetEditor: View {
    let model: WRLDBoardModel
    let done: () -> Void
    @State private var snippet: Snippet

    init(model: WRLDBoardModel, snippet: Snippet, done: @escaping () -> Void) {
        self.model = model
        self.done = done
        _snippet = State(initialValue: snippet)
    }

    var body: some View {
        let palette = model.palette
        PageRow {
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel("Name")
                TextField("deploy", text: $snippet.name).wrldField()
                FieldLabel("Command")
                TextEditor(text: $snippet.text)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 70)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.groundDeep))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(
                            palette.lineStrong, lineWidth: 1))
                Text(
                    "{{name}} asks for a value each time; {{env:prod|staging}} offers choices; {{version=2.4.1}} has a default."
                )
                .font(.system(size: 11)).foregroundStyle(palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer(minLength: 0)
                    Button("Cancel", action: done).buttonStyle(.wrld(.ghost))
                    Button("Save") {
                        var saved = snippet
                        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.edit { $0.save(saved) }
                        done()
                    }
                    .buttonStyle(.wrld(.primary))
                    .disabled(
                        snippet.name.allSatisfy(\.isWhitespace) || snippet.text.allSatisfy(\.isWhitespace))
                }
            }
        }
    }
}

// MARK: - Come & Go

/// The tunnels, each with its switch, and the form that adds one, as on the Come & Go
/// board.
struct ComeAndGoPage: View {
    @Bindable var model: WRLDBoardModel
    @State private var kind = TunnelSpec.Kind.local
    @State private var listen = ""
    @State private var forwardTo = ""
    @State private var through: HostID?
    @State private var opensWithConnection = false
    @State private var problem: String?

    var body: some View {
        let palette = model.palette
        let open = model.tunnels.filter(\.isOpen).count
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PageHeading(
                    symbol: "arrow.left.arrow.right", eyebrow: "Come & Go", title: "Tunnels",
                    detail: open == 1 ? "1 open" : "\(open) open")
                if model.tunnels.isEmpty {
                    Text("A tunnel brings a port on a server, or one it can reach, to this Mac. Add one below.")
                        .font(.system(size: 12)).foregroundStyle(palette.inkMuted)
                }
                ForEach(model.tunnels) { row in TunnelRowView(model: model, row: row) }
                Rectangle().fill(palette.line).frame(height: 1).padding(.vertical, 4)
                Eyebrow("Add a tunnel")
                Picker("Kind", selection: $kind) {
                    Text("Local").tag(TunnelSpec.Kind.local)
                    Text("Remote").tag(TunnelSpec.Kind.remote)
                    Text("Dynamic").tag(TunnelSpec.Kind.dynamic)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(kind == .remote ? "Listen on the server" : "Listen on")
                        TextField("6379", text: $listen).wrldField(monospaced: true)
                    }
                    if kind != .dynamic {
                        VStack(alignment: .leading, spacing: 5) {
                            FieldLabel("Forward to")
                            TextField("cache:6379", text: $forwardTo).wrldField(monospaced: true)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    FieldLabel("Through")
                    Picker("Through", selection: $through) {
                        Text("Choose a host").tag(HostID?.none)
                        ForEach(model.vault.hosts) { host in Text(host.name).tag(HostID?.some(host.id)) }
                    }
                    .labelsHidden()
                }
                Toggle(isOn: $opensWithConnection) {
                    Text("Opens whenever that host connects").foregroundStyle(palette.ink)
                }
                .toggleStyle(.neon)
                if let problem {
                    Text(problem).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.danger)
                }
                HStack(spacing: 10) {
                    Text("Opens on the connection you already have, so it never asks you to log in again.")
                        .font(.system(size: 12)).foregroundStyle(palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Open Tunnel", action: add).buttonStyle(.wrld(.primary)).disabled(through == nil)
                }
            }
            .padding(18)
        }
        .onAppear {
            if let host = model.tunnelHost {
                through = host
                model.tunnelHost = nil
            }
        }
    }

    private func add() {
        guard let host = through else { return }
        let spec: TunnelSpec
        do {
            spec = try TunnelSpec.parse(kind: kind, listen: listen, forwardTo: forwardTo)
        } catch {
            problem = Vault.TunnelProblem.spec(error).sentence
            return
        }
        let tunnel = Tunnel(spec: spec, opensWithConnection: opensWithConnection)
        var check = model.vault
        do {
            try check.addTunnel(tunnel, to: host)
        } catch {
            problem = error.sentence
            return
        }
        problem = nil
        model.edit { vault in _ = try? vault.addTunnel(tunnel, to: host) }
        model.toggleTunnel(tunnel.id)
        listen = ""
        forwardTo = ""
    }
}

struct TunnelRowView: View {
    let model: WRLDBoardModel
    let row: TunnelBoard.Row

    var body: some View {
        let palette = model.palette
        // "5432 → db:5432", then "Local · through prod-api · open since 10:42".
        let parts = row.text(time: { $0.formatted(date: .omitted, time: .shortened) }).components(separatedBy: " · ")
        PageRow {
            HStack(spacing: 12) {
                StatusDotView(dot: row.isOpen ? .connected : row.state == .opening ? .answering : .unknown)
                VStack(alignment: .leading, spacing: 2) {
                    Text(parts.first ?? "")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(palette.ink)
                    Text(parts.dropFirst().joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(isFailed ? palette.danger : palette.inkMuted)
                }
                Spacer(minLength: 0)
                Toggle(
                    isOn: Binding(
                        get: { row.isOpen || row.state == .opening }, set: { _ in model.toggleTunnel(row.id) })
                ) {
                    EmptyView()
                }
                .toggleStyle(.neon)
                .labelsHidden()
                .accessibilityLabel(row.isOpen ? "Turn off \(parts.first ?? "")" : "Turn on \(parts.first ?? "")")
            }
        }
        .contextMenu {
            Toggle(
                "Opens with the Connection",
                isOn: Binding(
                    get: { row.tunnel.opensWithConnection },
                    set: { on in model.edit { $0.setOpensWithConnection(row.id, on) } }))
            Divider()
            Button("Remove", role: .destructive) {
                guard let wrld = model.wrld else { return }
                Task { await wrld.removeTunnel(row.id) }
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = row.state { return true }
        return false
    }
}

// MARK: - Known hosts

/// The host keys ssh trusts, from ~/.ssh/known_hosts, which plain ssh shares; forgetting
/// one is the step after a host's key changed and the new one was checked.
struct KnownHostsPage: View {
    let model: WRLDBoardModel

    var body: some View {
        let palette = model.palette
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PageHeading(
                    symbol: "checkmark.shield", eyebrow: "Vault", title: "Known hosts",
                    detail: WRLDBoard.counted(model.knownHosts.count, "key"))
                Text("The keys ssh trusts, in ~/.ssh/known_hosts. Plain ssh uses the same file.")
                    .font(.system(size: 12)).foregroundStyle(palette.inkMuted)
                if let problem = model.problem {
                    Text(problem).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.danger)
                }
                ForEach(model.knownHosts) { entry in
                    PageRow {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(entry.title)
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(entry.isHashed ? palette.inkMuted : palette.ink)
                                    .lineLimit(1)
                                ChipView(chip: HostChip(entry.type, isKey: true))
                                Spacer(minLength: 0)
                                if let name = entry.hosts.first {
                                    Button("Forget…") { confirmForget(name) }.buttonStyle(.wrld(.ghost))
                                }
                            }
                            Text(entry.fingerprint)
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.inkFaint)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(18)
        }
        .onAppear { model.refreshFiles() }
    }

    private func confirmForget(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "Forget the keys ssh trusts for \(name)?"
        alert.informativeText =
            "ssh asks again the next time you connect, as for a new host. Do this after a host’s key changed and you’ve checked that the new one is right."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        Task {
            guard let window = NSApp.keyWindow,
                await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
            else { return }
            model.forget(name)
        }
    }
}
