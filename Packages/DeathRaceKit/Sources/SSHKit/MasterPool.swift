import Foundation
import PTYKit

/// A host as the pool connects to it: its name in the generated config, and its socket.
public struct ConnectionTarget: Hashable, Sendable {
    /// One master per key: a WRLD host's id, or "alias:<name>" for one from ~/.ssh/config.
    public var key: String
    /// Its name in the generated config, for `ssh -F … <alias>`.
    public var alias: String
    public var controlPath: String
    /// What sheets and Touch ID call it: "prod-api".
    public var name: String
    /// Where it is, when WRLD knows: for "Allow Local Network access".
    public var address: String?

    public init(key: String, alias: String, controlPath: String, name: String, address: String? = nil) {
        self.key = key
        self.alias = alias
        self.controlPath = controlPath
        self.name = name
        self.address = address
    }
}

/// A password WRLD may have saved, for the host a config alias names.
public struct SavedSecret: Hashable, Sendable {
    public var ref: SecretRef
    /// That host's WRLD name.
    public var name: String

    public init(ref: SecretRef, name: String) {
        self.ref = ref
        self.name = name
    }
}

/// Every master the app runs: one per host, shared by the panes and tunnels using it.
///
/// The first user of a host starts its master; the rest join it, with no new login, even
/// while it's still connecting. When the last one leaves, the master stays `idleClose` in
/// case you come back, then ends. Each master's questions go to the broker, with saved
/// passwords matched to the hops `HostChain` works out.
public final class MasterPool: Sendable {
    public struct Settings: Sendable {
        /// The generated ssh_config.
        public var config: String
        /// `deathrace-askpass`.
        public var helper: String
        /// What every ssh gets before the askpass variables: the app's environment with your
        /// login shell's PATH and SSH_AUTH_SOCK.
        public var environment: [String: String]
        /// How long a master no one uses stays up.
        public var idleClose: Duration

        public init(config: String, helper: String, environment: [String: String], idleClose: Duration = .seconds(600))
        {
            self.config = config
            self.helper = helper
            self.environment = environment
            self.idleClose = idleClose
        }
    }

    public enum Outcome: Equatable, Sendable {
        case ready
        case failed(ConnectionFailure)
    }

    private let broker: AskpassBroker
    private let runner: any ProcessRunner
    private let settings: Settings
    private let onEnd: @Sendable (String, MasterSupervisor.Ending) -> Void
    private let state = Locked(State())

    /// What starting a master came to: the master, or why there is none.
    struct Started: Sendable {
        var master: MasterSupervisor?
        var failure: ConnectionFailure?
    }

    struct Entry {
        var startup: Task<Started, Never>
        var users: Set<String>
        var idle: Task<Void, Never>?
        var master: MasterSupervisor?
    }

    struct State {
        var entries: [String: Entry] = [:]
    }

    /// `onEnd` hears of every master that ends, with the host's key: closed, cancelled,
    /// or lost.
    public init(
        broker: AskpassBroker, runner: any ProcessRunner = SystemProcessRunner(), settings: Settings,
        onEnd: @escaping @Sendable (String, MasterSupervisor.Ending) -> Void = { _, _ in }
    ) {
        self.broker = broker
        self.runner = runner
        self.settings = settings
        self.onEnd = onEnd
    }

    /// The hosts with a connected master.
    public var connected: [String] {
        state.withLock { state in
            state.entries.compactMap { key, entry in entry.master?.state == .ready ? key : nil }.sorted()
        }
    }

    /// A host's master, if it has one.
    public func master(for key: String) -> MasterSupervisor? {
        state.withLock { $0.entries[key]?.master }
    }

    // MARK: - Connecting

    /// Connects to `target` for `user` (a pane, a tunnel), or joins the master it has.
    /// `secrets` gives, for each alias in the generated config, the password WRLD may have
    /// saved for that host.
    public func connect(
        _ target: ConnectionTarget, for user: String, secrets: [String: SavedSecret] = [:], mayAsk: Bool = true
    ) async -> Outcome {
        let startup = state.withLock { state -> Task<Started, Never> in
            if var entry = state.entries[target.key] {
                entry.users.insert(user)
                entry.idle?.cancel()
                entry.idle = nil
                state.entries[target.key] = entry
                return entry.startup
            }
            let task = Task { await self.start(target, secrets: secrets, mayAsk: mayAsk) }
            state.entries[target.key] = Entry(startup: task, users: [user])
            return task
        }
        let started = await startup.value
        guard let master = started.master else {
            forget(target.key, if: startup)
            return .failed(started.failure ?? .other("ssh couldn't be started."))
        }
        switch await master.settled() {
        case .ready:
            return .ready
        case .ended(.failed(let failure)):
            return .failed(failure)
        case .ended(.closed), .connecting:
            return .failed(.cancelled)
        }
    }

    /// Works out the hops, registers with the broker, and starts the master.
    private func start(_ target: ConnectionTarget, secrets: [String: SavedSecret], mayAsk: Bool) async -> Started {
        let chain: HostChain
        do {
            chain = try await HostChain.resolve(
                alias: target.alias, config: settings.config, runner: runner, environment: settings.environment)
        } catch .unreadable(let line) {
            return Started(failure: .other(line))
        } catch {
            return Started(failure: .other("Its jump hosts lead back to it."))
        }
        guard !Task.isCancelled else { return Started(failure: .cancelled) }
        let context = chain.askpassContext(hostName: target.name, mayAsk: mayAsk) { alias in
            secrets[alias].map { ($0.ref, $0.name) }
        }
        let late = LateSupervisor()
        let token = broker.register(context) { late.end(.failed(.cancelled)) }
        let environment = AskpassEnvironment.adding(
            helper: settings.helper, socket: broker.socketPath, token: token, to: settings.environment)
        let master = MasterSupervisor(
            alias: target.alias, config: settings.config, controlPath: target.controlPath, environment: environment
        ) { [weak self, broker] state in
            switch state {
            case .connecting: break
            case .ready: broker.connected(token: token)
            case .ended(let ending):
                broker.unregister(token: token)
                self?.ended(target.key, late.value, ending)
            }
        }
        late.set(master)
        state.withLock { $0.entries[target.key]?.master = master }
        // A Cancel that came while the master was being made.
        guard !Task.isCancelled else {
            broker.unregister(token: token)
            return Started(failure: .cancelled)
        }
        do {
            let pid = try master.start()
            broker.attach(token: token, rootPID: pid)
            return Started(master: master)
        } catch .alreadyRunning {
            broker.unregister(token: token)
            return Started(failure: .other("Another ssh is already using \(target.name)'s connection."))
        } catch {
            broker.unregister(token: token)
            return Started(failure: .other("ssh couldn't be started."))
        }
    }

    /// A master ended: its entry goes, unless a newer master for the host has taken its
    /// place, and whoever listens hears why.
    private func ended(_ key: String, _ master: MasterSupervisor?, _ ending: MasterSupervisor.Ending) {
        state.withLock { state in
            guard let entry = state.entries[key], entry.master === master else { return }
            entry.idle?.cancel()
            state.entries[key] = nil
        }
        onEnd(key, ending)
    }

    /// Removes `key`'s entry if it's still the one `startup` began.
    private func forget(_ key: String, if startup: Task<Started, Never>) {
        state.withLock { state in
            if state.entries[key]?.startup == startup { state.entries[key] = nil }
        }
    }

    // MARK: - Leaving and ending

    /// `user` is done with whatever host it used. The last one out starts the idle clock;
    /// if the master is still connecting, nobody is waiting for it, so it stops at once.
    public func release(_ user: String) {
        let idle = settings.idleClose
        let abandoned = state.withLock { state -> [Entry] in
            var abandoned: [Entry] = []
            for (key, var entry) in state.entries where entry.users.contains(user) {
                entry.users.remove(user)
                if entry.users.isEmpty {
                    entry.idle?.cancel()
                    entry.idle = nil
                    if entry.master?.state == .ready {
                        entry.idle = Task { [weak self] in
                            try? await Task.sleep(for: idle)
                            guard !Task.isCancelled else { return }
                            self?.closeIfUnused(key)
                        }
                    } else {
                        abandoned.append(entry)
                    }
                }
                state.entries[key] = entry
            }
            return abandoned
        }
        for entry in abandoned {
            entry.startup.cancel()
            entry.master?.end(.failed(.cancelled))
        }
    }

    private func closeIfUnused(_ key: String) {
        let master = state.withLock { state -> MasterSupervisor? in
            guard let entry = state.entries[key], entry.users.isEmpty else { return nil }
            return entry.master
        }
        master?.end(.closed)
    }

    /// Stops connecting to `key`: the sheet's Cancel, or the pane's.
    public func cancel(_ key: String) {
        let entry = state.withLock { $0.entries[key] }
        entry?.startup.cancel()
        entry?.master?.end(.failed(.cancelled))
    }

    /// Ends `key`'s master now, whoever uses it.
    public func end(_ key: String) {
        state.withLock { $0.entries[key]?.master }?.end(.closed)
    }

    /// Ends every master and waits for them: quitting.
    public func endAll() async {
        let entries = state.withLock { state in Array(state.entries.values) }
        for entry in entries {
            entry.idle?.cancel()
            entry.startup.cancel()
        }
        let masters = entries.compactMap(\.master)
        for master in masters { master.end(.closed) }
        for master in masters { _ = await master.ending() }
    }
}

/// The supervisor a broker registration ends on Cancel, known only once it exists.
private final class LateSupervisor: Sendable {
    private let master = Locked<MasterSupervisor?>(nil)

    func set(_ value: MasterSupervisor) { master.withLock { $0 = value } }
    var value: MasterSupervisor? { master.withLock { $0 } }
    func end(_ ending: MasterSupervisor.Ending) { value?.end(ending) }
}
