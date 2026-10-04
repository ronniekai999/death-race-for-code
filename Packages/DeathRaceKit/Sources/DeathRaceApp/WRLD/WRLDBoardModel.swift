import AppCore
import AppKit
import Foundation
import LegendsUI
import Observation
import SSHKit
import Vault

/// What the WRLD window asks of the app: sessions and snippets go to the window in front.
@MainActor
protocol WRLDWindowHost: AnyObject {
    /// A session on `host` in the window in front: in a new tab, or beside its active pane.
    func connect(_ host: HostRef, beside: Bool)
    /// `command`, a snippet filled in, typed into the window in front's active pane and
    /// every armed pane with it, with Return to `run` it; that window comes forward.
    func typeSnippet(_ command: String, run: Bool, from snippet: SnippetID)
    /// The New Host sheet.
    func newHost(_ sender: Any?)
}

/// What the WRLD window shows and changes. It's drawn from WRLD as it last changed; a
/// change goes to WRLD, which saves it and says so, and the window draws again from that,
/// so it always shows what the vault holds.
@MainActor
@Observable
final class WRLDBoardModel {
    var vault = Vault()
    var state = WRLDState()
    /// Hosts with a connection open, by `WRLDState.key(for:)`.
    var connected: Set<String> = []
    /// Come & Go's rows, with what the board knows of each tunnel.
    var tunnels: [TunnelBoard.Row] = []
    /// Names in ~/.ssh/config WRLD doesn't hold and wasn't asked to leave be.
    var importable: [String] = []
    /// ~/.ssh/config's own description of a name, for its card.
    var aliases: [String: SSHConfigDiscovery.Alias] = [:]
    var knownHosts: [KnownHosts.Entry] = []
    /// Public key files in ~/.ssh, for the Keys page.
    var keyFiles: [KeyFile] = []
    /// Hosts the Keychain holds a password for.
    var savedPasswords: Set<HostID> = []
    var place: WRLDBoard.Place = .allHosts
    /// The host Come & Go's add form starts with: the one "Add a Tunnel…" came from.
    var tunnelHost: HostID?
    var query = ""
    var selected: HostID?
    var palette: LegendsPalette
    /// Why the last change didn't happen, in a sentence.
    var problem: String?
    /// What relative times count from; it moves on whenever WRLD changes.
    var now = Date()

    @ObservationIgnored weak var wrld: WRLDService?
    @ObservationIgnored weak var host: (any WRLDWindowHost)?

    init(palette: LegendsPalette) {
        self.palette = palette
    }

    /// Everything again, from WRLD.
    func refresh() {
        guard let wrld else { return }
        vault = wrld.vault
        state = wrld.state
        connected = wrld.connectedKeys
        tunnels = wrld.tunnelRows
        importable = wrld.importable
        aliases = Dictionary(wrld.discovered.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        savedPasswords = Set(vault.hosts.map(\.id).filter { wrld.hasSavedPassword($0) })
        now = Date()
        if let selected, vault.host(selected) == nil { self.selected = nil }
    }

    // MARK: - What the views read

    var hostRows: [WRLDBoard.ListRow] { WRLDBoard.hostRows(vault: vault) }
    var vaultRows: [WRLDBoard.ListRow] { WRLDBoard.vaultRows(vault: vault, knownHosts: knownHosts.count) }
    var summary: String { WRLDBoard.summary(vault: vault) }
    var sections: [WRLDBoard.CardSection] { WRLDBoard.cards(for: place, vault: vault, query: query) }
    var selectedHost: WRLDHost? { selected.flatMap(vault.host) }

    func status(of host: WRLDHost) -> HostStatus {
        let ref = HostRef.vault(host.id)
        return HostStatus(
            facts: state.facts(ref), isConnected: connected.contains(host.connectionKey), now: now)
    }

    func chips(for host: WRLDHost) -> [HostChip] {
        HostChips.chips(for: host, in: vault, savedPassword: savedPasswords.contains(host.id))
    }

    /// "ubuntu@10.0.4.21", "ubuntu@10.0.4.21:2222", or what ~/.ssh/config says of a name.
    func address(of host: WRLDHost) -> String {
        switch host.source {
        case .wrld(let connection):
            let port = connection.port.map { ":\($0)" } ?? ""
            return (connection.user.map { $0 + "@" } ?? "") + connection.address + port
        case .sshConfig(let alias):
            guard let found = aliases[alias] else { return "~/.ssh/config" }
            return (found.user.map { $0 + "@" } ?? "") + (found.hostName ?? alias)
        }
    }

    /// The tunnels on `host`, with what the board knows of each.
    func tunnels(on host: WRLDHost) -> [TunnelBoard.Row] {
        tunnels.filter { row in host.tunnels.contains { $0.id == row.id } }
    }

    // MARK: - Changes

    /// Makes `change` to the vault; when it couldn't be saved, says so.
    func edit(_ change: (inout Vault) -> Void) {
        guard let wrld else { return }
        problem = wrld.edit(change) ? nil : "WRLD couldn’t save that change."
    }

    func connect(_ host: WRLDHost, beside: Bool = false) {
        self.host?.connect(.vault(host.id), beside: beside)
    }

    func toggleTunnel(_ id: TunnelID) {
        guard let wrld else { return }
        Task { await wrld.toggleTunnel(id) }
    }

    func importAll() {
        let names = importable
        edit { $0.importAliases(names) }
    }

    func dismissImports() {
        wrld?.dismissImports()
    }

    /// Reads ~/.ssh's public keys and known_hosts again, off the main thread.
    func refreshFiles() {
        guard let wrld else { return }
        Task {
            knownHosts = await wrld.knownHosts()
            keyFiles = await Self.publicKeyFiles(in: NSHomeDirectory() + "/.ssh")
        }
    }

    /// Forgets the keys ssh trusts for `name`, then reads the file again.
    func forget(_ name: String) {
        guard let wrld else { return }
        Task {
            do {
                try await wrld.forgetKnownHost(name)
                problem = nil
            } catch {
                switch error {
                case .refused(let why): problem = "ssh-keygen didn’t forget \(name): \(why)"
                }
            }
            knownHosts = await wrld.knownHosts()
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Forgets the password the Keychain holds for `host`.
    func forgetPassword(_ host: HostID) {
        wrld?.forgetPassword(host)
        refresh()
    }

    /// A public key file in ~/.ssh.
    struct KeyFile: Equatable, Identifiable {
        var name: String
        var publicKey: String
        var id: String { name }
    }

    /// The `.pub` files in `folder`, their first lines.
    nonisolated static func publicKeyFiles(in folder: String) async -> [KeyFile] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return files.filter { $0.hasSuffix(".pub") }.sorted().compactMap { file in
            guard let text = try? String(contentsOfFile: folder + "/" + file, encoding: .utf8),
                let line = text.split(whereSeparator: \.isNewline).first
            else { return nil }
            return KeyFile(name: file, publicKey: String(line))
        }
    }
}
