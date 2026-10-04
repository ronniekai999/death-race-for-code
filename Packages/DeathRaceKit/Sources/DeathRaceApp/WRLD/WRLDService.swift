import AppCore
import Foundation
import Network
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
    /// What WRLD has learned as it's used: last connected, OS, latency, snippet uses.
    private(set) var state: WRLDState
    private let stateStore: WRLDStateStore
    /// What the settings let WRLD find out by itself (`wrld-check-hosts`, `wrld-host-os`).
    var checksHosts = true
    var readsHostOS = true
    /// Legends being checked now, and ones whose address turned out to be on the local
    /// network before you'd connected (checked again once you have).
    private var checking: Set<HostID> = []
    private var skippedLocal: Set<HostID> = []
    /// What shows WRLD now (the sidebars, the WRLD window), and while anything does, the
    /// five-minute check and the network's changes.
    private var viewers: Set<ObjectIdentifier> = []
    private var checkTimer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var pathSeen = false
    private var networkChangedAt: Date?
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
        stateStore = WRLDStateStore(path: paths.state)
        state = stateStore.load()
        generated = GeneratedConfig(vault: Vault(), paths: paths)
        reload()
    }

    /// wrld.json, wherever it is.
    var vaultPath: String { store.path }

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
            connected(host, alias: target.alias)
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

    // MARK: - Wishing Well

    func paletteSnippets() -> [PaletteItem] { PaletteSearch.snippets(vault: vault) }

    func snippet(_ id: SnippetID) -> Snippet? { vault.snippet(id) }

    func save(_ snippet: Snippet) -> Bool {
        edit { $0.save(snippet) }
    }

    func used(_ snippet: SnippetID) {
        state.used(snippet)
        saveState()
    }

    // MARK: - Changing WRLD

    /// Makes `change` to the vault and saves it, then everything showing WRLD draws again;
    /// false when it couldn't be saved, and nothing changed.
    @discardableResult
    func edit(_ change: (inout Vault) -> Void) -> Bool {
        var updated = vault
        change(&updated)
        guard updated != vault else { return true }
        do {
            try store.save(updated)
        } catch {
            log.error("WRLD couldn't save its vault: \(String(describing: error), privacy: .public)")
            return false
        }
        reload()
        Self.changed()
        return true
    }

    func sidebar(query: String, expanded: Set<GroupID>) -> SidebarModel {
        SidebarModel(
            .init(
                vault: vault, state: state, connected: connectedKeys, openTunnels: openTunnelIDs,
                expandedGroups: expanded, query: query))
    }

    func host(_ id: HostID) -> WRLDHost? { vault.host(id) }

    func setLegend(_ host: HostID, _ isLegend: Bool) {
        edit { $0.setLegend(host, isLegend) }
    }

    /// Takes `host` out of WRLD, closing its open tunnels first.
    func remove(_ host: HostID) async {
        if let board, let tunnels = vault.host(host)?.tunnels {
            for tunnel in tunnels where board.row(tunnel.id)?.isOpen == true { await board.close(tunnel.id) }
            Self.tunnelsChanged()
        }
        edit { $0.removeHost(host) }
    }

    /// Takes a tunnel out of WRLD, closing it first if it's open.
    func removeTunnel(_ id: TunnelID) async {
        if let board, board.row(id)?.isOpen == true {
            await board.close(id)
            Self.tunnelsChanged()
        }
        edit { $0.removeTunnel(id) }
    }

    /// The sidebar and the WRLD window draw again.
    static func changed() {
        NotificationCenter.default.post(name: .wrldChanged, object: nil)
    }

    /// Hosts with a connection open, by `WRLDState.key(for:)`.
    var connectedKeys: Set<String> { Set(pool?.connected ?? []) }

    var openTunnelIDs: Set<TunnelID> { Set(board?.all.filter(\.isOpen).map(\.id) ?? []) }

    /// "Found 12 hosts in ~/.ssh/config": the names WRLD doesn't hold, less those put away.
    var importable: [String] {
        WRLDBoard.importable(aliases: discovered.map(\.name), vault: vault, dismissed: state.dismissedImports)
    }

    /// "Not now": the names offered so far aren't offered again; new ones will be.
    func dismissImports() {
        state.dismissedImports = Array(Set(state.dismissedImports + importable)).sorted()
        saveState()
    }

    // MARK: - What WRLD finds out by itself

    private func record(_ host: HostRef, _ change: (inout WRLDState.HostFacts) -> Void) {
        state.update(host, change)
        saveState()
    }

    private func saveState() {
        do {
            try stateStore.save(state)
        } catch {
            log.error("WRLD couldn't save what it knows: \(String(describing: error), privacy: .public)")
        }
        Self.changed()
    }

    /// A connection to `host` came up: when it was, and, at most weekly, what it runs, read
    /// over that connection.
    private func connected(_ host: HostRef, alias: String) {
        if case .vault(let id) = host { skippedLocal.remove(id) }
        record(host) { $0.lastConnected = Date() }
        guard readsHostOS, HostChecks.osIsDue(facts: state.facts(host), enabled: true, now: Date()) else { return }
        let environment = LoginEnvironment.merging(login ?? [:], into: self.environment)
        let config = paths.generatedConfig
        Task {
            let os = await HostChecks.readOS(
                alias: alias, config: config, runner: SystemProcessRunner(), environment: environment)
            record(host) { facts in
                if let os { facts.os = os }
                facts.osReadAt = Date()
            }
        }
    }

    /// Checks how quickly the Legends that are due answer (`HostChecks.latencyIsDue`): the
    /// sidebar and the WRLD window ask while they show, every five minutes and when the
    /// network changes.
    func checkLatency(networkChangedAt: Date?) {
        guard checksHosts else { return }
        let now = Date()
        var started = 0
        defer {
            // For the energy check in MANUAL-TESTS: none of these while WRLD is off screen.
            if started > 0 { log.debug("Checking how quickly \(started) Legends answer") }
        }
        for host in vault.hosts {
            let facts = state.facts(.vault(host.id))
            guard !checking.contains(host.id), !skippedLocal.contains(host.id), let connection = host.connection,
                HostChecks.latencyIsDue(
                    host, facts: facts, enabled: true, visible: true, networkChangedAt: networkChangedAt, now: now)
            else { continue }
            started += 1
            checking.insert(host.id)
            let allowLocal = facts.lastConnected != nil
            Task {
                let answer = await HostChecks.latency(
                    host: connection.address, port: connection.port ?? 22, allowLocal: allowLocal)
                checking.remove(host.id)
                switch answer {
                case .answered(let milliseconds):
                    record(.vault(host.id)) { facts in
                        facts.latency = milliseconds
                        facts.latencyCheckedAt = Date()
                    }
                case .silent:
                    record(.vault(host.id)) { facts in
                        facts.latency = nil
                        facts.latencyCheckedAt = Date()
                    }
                case .skipped:
                    skippedLocal.insert(host.id)
                }
            }
        }
    }

    // MARK: - Saved passwords

    /// Whether the Keychain holds a password for `host`. Asks nothing.
    func hasSavedPassword(_ host: HostID) -> Bool {
        guard let saved = vault.host(host) else { return false }
        return secrets.contains(SecretRef(.hostPassword, GeneratedConfig.controlKey(for: saved)))
    }

    /// Forgets the password the Keychain holds for `host`: the next login asks again.
    func forgetPassword(_ host: HostID) {
        guard let saved = vault.host(host) else { return }
        do {
            try secrets.delete(SecretRef(.hostPassword, GeneratedConfig.controlKey(for: saved)))
        } catch {
            log.error("WRLD couldn't forget a password: \(String(describing: error), privacy: .public)")
        }
        Self.changed()
    }

    // MARK: - While WRLD shows

    /// The sidebar or the WRLD window came on screen: the Legends that are due are checked
    /// now, then every five minutes and after each network change while anything shows
    /// them. Nothing runs while nothing does.
    func shown(by viewer: AnyObject) {
        let first = viewers.isEmpty
        viewers.insert(ObjectIdentifier(viewer))
        guard first else { return }
        checkLatency(networkChangedAt: networkChangedAt)
        let timer = Timer(timeInterval: HostChecks.latencyInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.checkLatency(networkChangedAt: self.networkChangedAt)
            }
        }
        // Five minutes give or take one, so macOS can fold the wakeup in with others.
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
        let monitor = NWPathMonitor()
        pathSeen = false
        monitor.pathUpdateHandler = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The first update is the network as it is, not a change.
                guard self.pathSeen else {
                    self.pathSeen = true
                    return
                }
                self.networkChangedAt = Date()
                self.checkLatency(networkChangedAt: self.networkChangedAt)
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    func hidden(by viewer: AnyObject) {
        viewers.remove(ObjectIdentifier(viewer))
        guard viewers.isEmpty else { return }
        checkTimer?.invalidate()
        checkTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    // MARK: - Known hosts

    func knownKeys(_ removal: KeyRemoval) async -> [KnownHosts.Entry] {
        await KnownHosts.find(removal.name, path: removal.file, runner: SystemProcessRunner(), environment: environment)
    }

    func forgetKey(_ removal: KeyRemoval) async -> String? {
        do {
            try await KnownHosts.forget(
                removal.name, path: removal.file, runner: SystemProcessRunner(), environment: environment)
            Self.changed()
            return nil
        } catch {
            switch error {
            case .refused(let why): return why
            }
        }
    }

    /// The file ssh trusts host keys from, which plain ssh shares.
    var knownHostsPath: String { home + "/.ssh/known_hosts" }

    func knownHosts() async -> [KnownHosts.Entry] {
        await KnownHosts.list(path: knownHostsPath, runner: SystemProcessRunner(), environment: environment)
    }

    /// Forgets the keys ssh trusts for `name`: after a host's key changed and you've made
    /// sure the new one is right.
    func forgetKnownHost(_ name: String) async throws(KnownHosts.Failure) {
        try await KnownHosts.forget(
            name, path: knownHostsPath, runner: SystemProcessRunner(), environment: environment)
        Self.changed()
    }

    func onConnectCommand(for host: HostRef) -> String? {
        let saved: WRLDHost? =
            switch host {
            case .vault(let id): vault.host(id)
            case .sshConfig(let alias): vault.hosts.first { $0.source == .sshConfig(alias: alias) }
            }
        guard let id = saved?.onConnectSnippetID, let snippet = vault.snippet(id) else { return nil }
        return SnippetFill(snippet.text).command
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
        Self.changed()
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
