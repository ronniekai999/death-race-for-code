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
        /// How the pool reached this host, so a later connection that jumps through it can
        /// be matched to this entry by alias.
        var target: ConnectionTarget
    }

    /// The synthetic user a master holds on each jump host it reaches through, so the jump
    /// host's master can't idle out from under it (its ProxyJump hop reuses that master).
    private static func viaUser(_ key: String) -> String { "via:" + key }

    struct State {
        var entries: [String: Entry] = [:]
        /// Masters that have been taken out of `entries` and told to end, by host key. A
        /// fresh connect for that host starts a new entry at once, but its `start()` waits
        /// for the retiring master's socket to go before spawning, so the two never collide.
        var retiring: [String: MasterSupervisor] = [:]
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

    /// Whether any master exists at all, connected, still connecting, or on its way out:
    /// quitting must clean these up, even a master that only a tunnel started.
    public var hasEntries: Bool { state.withLock { !$0.entries.isEmpty || !$0.retiring.isEmpty } }

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
            state.entries[target.key] = Entry(startup: task, users: [user], target: target)
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
        // A previous master for this host may still be tearing down; wait for its control
        // socket to go, or our `ssh -M` would refuse with "already running".
        if let retiring = state.withLock({ $0.retiring[target.key] }) {
            _ = await retiring.ending()
        }
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
            holdJumpHosts(chain, for: target)
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
    /// place, and whoever listens hears why. When it goes, the hold it kept on the jump
    /// hosts it reached through is released, so they can idle out once nothing else needs
    /// them. (A newer master kept the entry, so it keeps the holds too.)
    private func ended(_ key: String, _ master: MasterSupervisor?, _ ending: MasterSupervisor.Ending) {
        let known = state.withLock { state -> Bool in
            // A master taken out of `entries` to retire: just forget it.
            if state.retiring[key] === master {
                state.retiring[key] = nil
                return true
            }
            guard let entry = state.entries[key], entry.master === master else { return false }
            entry.idle?.cancel()
            state.entries[key] = nil
            return true
        }
        // Whether it was live or retiring, a master that ends releases the hold it kept on
        // the jump hosts it reached through (a newer master for the host re-adds its own,
        // after waiting for this one's socket to go). A stale callback for a master already
        // replaced does nothing.
        if known { release(Self.viaUser(key)) }
        onEnd(key, ending)
    }

    /// Holds the ready master of each jump host `target` reaches through, so it can't idle
    /// out while this master lives: the ProxyJump hop (`ssh -W`) reuses that master's socket,
    /// so ending it would drop every host behind it. The hold is released in `ended`.
    private func holdJumpHosts(_ chain: HostChain, for target: ConnectionTarget) {
        let jumpAliases = Set(chain.hops.dropLast().map(\.alias))
        guard !jumpAliases.isEmpty else { return }
        state.withLock { state in
            for (key, var entry) in state.entries
            where key != target.key && jumpAliases.contains(entry.target.alias) && entry.master?.state == .ready {
                entry.idle?.cancel()
                entry.idle = nil
                entry.users.insert(Self.viaUser(target.key))
                state.entries[key] = entry
            }
        }
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
                        state.entries[key] = entry
                    } else {
                        // Still connecting and now unwanted: retire it and take the entry out,
                        // so a fresh connect starts clean rather than joining this dying one.
                        if let master = entry.master { state.retiring[key] = master }
                        state.entries[key] = nil
                        abandoned.append(entry)
                    }
                } else {
                    state.entries[key] = entry
                }
            }
            return abandoned
        }
        for entry in abandoned {
            entry.startup.cancel()
            entry.master?.end(.failed(.cancelled))
        }
    }

    private func closeIfUnused(_ key: String) {
        // Take the entry out under the lock as we decide to end it, so a connect that arrives
        // in the window either added a user (and we see it's no longer unused) or finds no
        // entry and starts fresh — it can't join a master that's on its way out.
        let master = state.withLock { state -> MasterSupervisor? in
            guard let entry = state.entries[key], entry.users.isEmpty, let master = entry.master else { return nil }
            state.retiring[key] = master
            state.entries[key] = nil
            return master
        }
        master?.end(.closed)
    }

    /// Stops connecting to `key`: the sheet's Cancel, or the pane's.
    public func cancel(_ key: String) {
        let entry = state.withLock { state -> Entry? in
            guard let entry = state.entries[key] else { return nil }
            if let master = entry.master { state.retiring[key] = master }
            state.entries[key] = nil
            return entry
        }
        entry?.startup.cancel()
        entry?.master?.end(.failed(.cancelled))
    }

    /// Ends `key`'s master now, whoever uses it.
    public func end(_ key: String) {
        let master = state.withLock { state -> MasterSupervisor? in
            guard let master = state.entries[key]?.master else { return nil }
            state.retiring[key] = master
            state.entries[key] = nil
            return master
        }
        master?.end(.closed)
    }

    /// Ends every master and waits for them: quitting.
    public func endAll() async {
        let (entries, retiring) = state.withLock { state in (Array(state.entries.values), Array(state.retiring.values))
        }
        for entry in entries {
            entry.idle?.cancel()
            entry.startup.cancel()
        }
        // The live masters, plus any already on their way out, so quit waits for them all.
        let masters = entries.compactMap(\.master) + retiring
        for master in masters { master.end(.closed) }
        for master in masters { _ = await master.ending() }
    }
}

/// The supervisor a broker registration ends on Cancel, known only once it exists. It holds
/// the master *weakly*: the master's own state callback captures this, so a strong hold would
/// be a cycle that leaks every master. The pool's `State` keeps the master alive while its
/// entry lives, and once the entry goes the master should be freed.
private final class LateSupervisor: Sendable {
    private final class Box { weak var master: MasterSupervisor? }
    private let box = Locked(Box())

    func set(_ value: MasterSupervisor) { box.withLock { $0.master = value } }
    var value: MasterSupervisor? { box.withLock { $0.master } }
    func end(_ ending: MasterSupervisor.Ending) { value?.end(ending) }
}
