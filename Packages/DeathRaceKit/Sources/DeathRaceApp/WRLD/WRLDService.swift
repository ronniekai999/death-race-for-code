import AppCore
import Foundation
import PTYKit
import SSHKit
import Vault
import os

/// WRLD for the app: the vault, the ssh_config it compiles to, the askpass broker, and the
/// pool of masters the panes run their sessions through.
///
/// Nothing ssh-related starts until the first connection: the broker, your login shell's
/// PATH and agent, the pool. Before that, WRLD costs a parse of two files.
@MainActor
final class WRLDService: HostConnecting {
    let paths: WRLDPaths
    private let store: VaultStore
    private let home: String
    private let environment: [String: String]
    /// `deathrace-askpass`, next to the app's executable.
    private let helper: String
    private let secrets: any SecretStore
    private let presence: any UserPresence
    private let presenter: any PromptPresenter
    private let log = Logger(subsystem: "local.deathraceforcode.DeathRace", category: "WRLD")

    private(set) var vault = Vault()
    /// Concrete names in ~/.ssh/config, for the palette and their control blocks.
    private(set) var discovered: [SSHConfigDiscovery.Alias] = []
    private(set) var generated: GeneratedConfig
    /// Why the vault couldn't be read, if it couldn't: WRLD runs empty meanwhile.
    private(set) var loadProblem: VaultStore.Failure?

    private var broker: AskpassBroker?
    private var pool: MasterPool?
    private var board: TunnelBoard?
    /// New Secure Enclave keys waiting to go onto their hosts, over the first connection.
    private var pendingKeys: [HostID: KeyID] = [:]
    private var login: [String: String]?
    private var starting: Task<MasterPool?, Never>?

    init(
        home: String, environment: [String: String] = ShellLaunch.processEnvironment(), helper: String,
        secrets: any SecretStore, presence: any UserPresence, presenter: any PromptPresenter
    ) {
        self.home = home
        self.environment = environment
        self.helper = helper
        self.secrets = secrets
        self.presence = presence
        self.presenter = presenter
        paths = WRLDPaths.standard(home: home)
        store = VaultStore(path: VaultLocation.path(environment: environment, home: home))
        generated = GeneratedConfig(vault: Vault(), paths: paths)
        reload()
    }

    /// `deathrace-askpass` beside the running executable: Contents/MacOS in the app, the
    /// build folder in a debug run.
    static var bundledHelper: String {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.deletingLastPathComponent().appendingPathComponent("deathrace-askpass").path
    }

    // MARK: - The vault and the config

    /// Reads wrld.json and ~/.ssh/config again and rewrites the generated config.
    func reload() {
        do {
            vault = try store.load()
            loadProblem = nil
        } catch {
            loadProblem = error
            log.error("WRLD couldn't read its vault: \(String(describing: error), privacy: .public)")
        }
        discovered = SSHConfigDiscovery.aliases(inFileAt: home + "/.ssh/config", home: home)
        generated = GeneratedConfig(vault: vault, paths: paths, aliases: discovered.map(\.name))
        do {
            try AtomicFile.write(Array(generated.text.utf8), to: paths.generatedConfig)
        } catch {
            log.error("WRLD couldn't write its ssh config: \(String(describing: error), privacy: .public)")
        }
    }

    /// How the pool sees `host`; nil when the generated config left it out.
    func target(for host: HostRef) -> ConnectionTarget? {
        switch host {
        case .vault(let id):
            guard let saved = vault.host(id), let alias = generated.aliases[id],
                let controlPath = generated.controlPaths[id]
            else { return nil }
            return ConnectionTarget(
                key: GeneratedConfig.controlKey(for: saved), alias: alias, controlPath: controlPath, name: saved.name,
                address: saved.connection?.address)
        case .sshConfig(let alias):
            if let saved = vault.hosts.first(where: { $0.source == .sshConfig(alias: alias) }) {
                return target(for: .vault(saved.id))
            }
            guard let controlPath = generated.aliasControlPaths[alias] else { return nil }
            return ConnectionTarget(
                key: GeneratedConfig.controlKey(forAlias: alias), alias: alias, controlPath: controlPath, name: alias,
                address: discovered.first { $0.name == alias }?.hostName)
        }
    }

    /// The passwords WRLD may hold, by the alias ssh knows each host by.
    var savedSecrets: [String: SavedSecret] {
        var secrets: [String: SavedSecret] = [:]
        for alias in discovered.map(\.name) {
            secrets[alias] = SavedSecret(
                ref: SecretRef(.hostPassword, GeneratedConfig.controlKey(forAlias: alias)), name: alias)
        }
        for host in vault.hosts {
            guard let alias = generated.aliases[host.id] else { continue }
            secrets[alias] = SavedSecret(
                ref: SecretRef(.hostPassword, GeneratedConfig.controlKey(for: host)), name: host.name)
        }
        return secrets
    }

    // MARK: - HostConnecting

    func name(of host: HostRef) -> String {
        switch host {
        case .vault(let id): vault.host(id)?.name ?? "the host"
        case .sshConfig(let alias): alias
        }
    }

    func address(of host: HostRef) -> String? { target(for: host)?.address }

    func connect(_ host: HostRef, for pane: PaneID) async -> ConnectResult {
        guard let target = target(for: host) else {
            let why = generated.problems.first { problem in
                if case .vault(let id) = host { return problem.host == id }
                return false
            }
            return .failed(.other(why?.message ?? "WRLD can't connect to \(name(of: host))."))
        }
        guard let pool = await startPool() else {
            return .failed(.other("Death Race couldn't start what answers ssh's questions."))
        }
        switch await pool.connect(target, for: Self.user(pane), secrets: savedSecrets) {
        case .ready:
            if case .vault(let id) = host, let key = pendingKeys[id] {
                Task { await install(key, on: id, alias: target.alias) }
            }
            if case .vault(let id) = host, let tunnels = vault.host(id)?.tunnels,
                tunnels.contains(where: \.opensWithConnection), let board
            {
                Task {
                    await board.openWithConnection(tunnels, on: target)
                    Self.tunnelsChanged()
                }
            }
            let arguments = SSHCommand.session(alias: target.alias, config: paths.generatedConfig)
            return .ready(
                ShellLaunchPlan.ssh(
                    arguments: arguments, login: login ?? [:], environment: environment,
                    appVersion: DeathRaceApplication.version))
        case .failed(let failure):
            return .failed(failure)
        }
    }

    func plainLaunch(_ host: HostRef) async -> ShellLaunch? {
        guard let target = target(for: host) else { return nil }
        let login = await loginEnvironment()
        return ShellLaunchPlan.ssh(
            arguments: SSHCommand.plainSession(alias: target.alias, config: paths.generatedConfig), login: login,
            environment: environment, appVersion: DeathRaceApplication.version)
    }

    func release(_ pane: PaneID) {
        pool?.release(Self.user(pane))
    }

    func cancel(_ host: HostRef) {
        guard let key = target(for: host)?.key else { return }
        pool?.cancel(key)
    }

    func paletteHosts() -> [PaletteItem] {
        PaletteSearch.hosts(vault: vault, aliases: discovered.map(\.name))
    }

    var openConnections: [String] {
        guard let pool else { return [] }
        return pool.connected.map { key in
            vault.hosts.first { GeneratedConfig.controlKey(for: $0) == key }?.name
                ?? (key.hasPrefix("alias:") ? String(key.dropFirst(6)) : key)
        }
    }

    private static func user(_ pane: PaneID) -> String { "pane:\(pane.rawValue)" }

    // MARK: - Come & Go

    /// Status bars count again, on the main thread.
    nonisolated static func tunnelsChanged() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .tunnelsChanged, object: nil) }
    }

    var openTunnelCount: Int { board?.openCount ?? 0 }

    func paletteTunnels() -> [PaletteItem] {
        PaletteSearch.tunnels(vault: vault, open: Set(board?.all.filter(\.isOpen).map(\.id) ?? []))
    }

    /// Come & Go's rows: every tunnel WRLD holds, with what the board knows of it.
    var tunnelRows: [TunnelBoard.Row] {
        vault.hosts.flatMap { host in
            host.tunnels.map { tunnel in
                board?.row(tunnel.id)
                    ?? TunnelBoard.Row(
                        tunnel: tunnel, hostKey: GeneratedConfig.controlKey(for: host), hostName: host.name,
                        state: .closed)
            }
        }
    }

    func toggleTunnel(_ id: TunnelID) async {
        guard let host = vault.hosts.first(where: { $0.tunnels.contains { $0.id == id } }),
            let tunnel = host.tunnels.first(where: { $0.id == id })
        else { return }
        if let board, board.row(id)?.isOpen == true {
            await board.close(id)
        } else {
            guard let target = target(for: .vault(host.id)), await startPool() != nil, let board else { return }
            Self.tunnelsChanged()
            await board.open(tunnel, on: target, secrets: savedSecrets)
        }
        Self.tunnelsChanged()
    }

    // MARK: - Adding hosts and keys

    enum AddFailure: Error, Equatable {
        case draft(HostDraft.Problem)
        case key(SecureEnclaveKeys.Failure)
        case notSaved(VaultStore.Failure)

        var sentence: String {
            switch self {
            case .draft(let problem): problem.sentence
            case .key(.notCreated(let line)): "macOS didn’t make the key: \(line)"
            case .key(.notDownloaded(let line)): "The key was made, but ssh couldn’t read it back: \(line)"
            case .key(.notFound): "The key was made, but ssh couldn’t tell which key it is."
            case .key(.notSaved(let line)): "The key couldn’t be kept: \(line)"
            case .notSaved: "WRLD couldn’t save the host."
            }
        }
    }

    /// Saves the host the sheet describes, making its Secure Enclave key first when it asks
    /// for one (Touch ID asks then). Returns the new host's id.
    func add(_ draft: HostDraft) async throws(AddFailure) -> HostID {
        let host: WRLDHost
        do {
            host = try draft.host()
        } catch {
            throw .draft(error)
        }
        var newKey: Key?
        if draft.signIn == .newSecureEnclaveKey {
            let id = KeyID.make()
            let keys = SecureEnclaveKeys(
                runner: SystemProcessRunner(),
                environment: LoginEnvironment.merging(await loginEnvironment(), into: environment),
                keysFolder: paths.keysFolder)
            do {
                let created = try await keys.create(label: "Death Race", fileName: id.rawValue)
                newKey = Key(
                    id: id, kind: .secureEnclave, label: "Death Race", handle: created.handle,
                    publicKey: created.publicKey)
            } catch {
                throw .key(error)
            }
        }
        var updated = vault
        updated.hosts.append(host)
        if let newKey { updated.keys.append(newKey) }
        do {
            try store.save(updated)
        } catch {
            throw .notSaved(error)
        }
        reload()
        if let newKey { pendingKeys[host.id] = newKey.id }
        return host.id
    }

    /// Puts `key` on the host through its master, then has the host sign in with it.
    private func install(_ key: KeyID, on hostID: HostID, alias: String) async {
        guard let publicKey = vault.keys.first(where: { $0.id == key })?.publicKey else { return }
        do {
            try await AuthorizedKeys.install(
                publicKey, alias: alias, config: paths.generatedConfig, runner: SystemProcessRunner(),
                environment: LoginEnvironment.merging(login ?? [:], into: environment))
        } catch {
            log.error("The Secure Enclave key didn't go onto its host: \(String(describing: error), privacy: .public)")
            return
        }
        var updated = vault
        guard let index = updated.hosts.firstIndex(where: { $0.id == hostID }),
            case .wrld(var connection) = updated.hosts[index].source
        else { return }
        connection.identity = .secureEnclave(key)
        updated.hosts[index].source = .wrld(connection)
        do {
            try store.save(updated)
        } catch {
            log.error("WRLD couldn't save the host's new key: \(String(describing: error), privacy: .public)")
            return
        }
        pendingKeys[hostID] = nil
        reload()
    }

    /// The hosts a jump host can be chosen from: WRLD's own.
    var jumpHostChoices: [(id: HostID, name: String)] {
        vault.hosts.compactMap { host in
            if case .wrld = host.source { return (host.id, host.name) }
            return nil
        }
    }

    // MARK: - Starting and stopping

    /// Your login shell's PATH and SSH_AUTH_SOCK, read once.
    private func loginEnvironment() async -> [String: String] {
        if let login { return login }
        let shell = ShellLaunch.userShell(environment: environment)
        let found = await LoginEnvironment.read(shell: shell, environment: environment)
        login = found
        return found
    }

    /// The broker and the pool, made on the first connection.
    private func startPool() async -> MasterPool? {
        if let pool { return pool }
        if let starting { return await starting.value }
        let task = Task { () -> MasterPool? in
            let login = await loginEnvironment()
            let broker = AskpassBroker(
                socketPath: paths.brokerSocket(pid: getpid()), secrets: secrets, presence: presence,
                presenter: presenter)
            do {
                try broker.start()
            } catch {
                log.error("The askpass broker didn't start: \(String(describing: error), privacy: .public)")
                return nil
            }
            self.broker = broker
            let boardBox = Locked<TunnelBoard?>(nil)
            let merged = LoginEnvironment.merging(login, into: environment)
            let pool = MasterPool(
                broker: broker,
                settings: MasterPool.Settings(config: paths.generatedConfig, helper: helper, environment: merged),
                onEnd: { key, _ in
                    // A master that ends takes its tunnels with it.
                    boardBox.withLock { $0 }?.hostEnded(key)
                    Self.tunnelsChanged()
                })
            let board = TunnelBoard(
                pool: pool, controller: TunnelController(runner: SystemProcessRunner(), environment: merged))
            boardBox.withLock { $0 = board }
            self.pool = pool
            self.board = board
            return pool
        }
        starting = task
        let pool = await task.value
        starting = nil
        return pool
    }

    /// Masters a crash left running end, before any new one starts.
    func cleanUpLeftovers() async {
        let folder = paths.controlFolder
        let environment = ["PATH": "/usr/bin:/bin"]
        let ended = await MasterSupervisor.cleanUpLeftovers(
            in: folder, runner: SystemProcessRunner(), environment: environment)
        if ended > 0 { log.notice("Ended \(ended) ssh masters left from before") }
    }

    /// Quitting: every master ends, and the broker stops.
    func shutDown() async {
        await pool?.endAll()
        broker?.stop()
    }
}
