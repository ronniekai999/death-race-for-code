import IPCKit
import PTYKit
import ScreenProtocol
import SessionKit
import VTCore

/// Every session the daemon holds, and who may take one up.
///
/// A session outlives the client that started it, so the registry — not a connection — owns
/// it. Attaching needs a token the daemon handed out over the control connection: single use
/// and short-lived, so a session id, which is only a number, is not on its own enough to take
/// someone's shell.
final class SessionRegistry: Sendable {
    struct Entry {
        let id: SessionID
        let session: Session
        let shellExecutable: String
        let startedAtMilliseconds: UInt64
        var columns: Int
        var rows: Int
        var metadata: [UInt8]
        /// The pipe that wakes whoever is watching, or nil when nobody is.
        var watcher: WakePipe?
        var token: [UInt8]?
        var tokenIssuedAt: Int
        /// When its shell ended with nobody watching; nil while it is running or watched.
        var abandonedAt: Int?
        /// Whether the end of this session has been told to the control connections.
        var endAnnounced = false
    }

    private struct State {
        var entries: [SessionID: Entry] = [:]
        var nextID: UInt64 = 1
        /// Ids whose shells are being started: they hold a slot against the limit although
        /// there is no entry for them yet.
        var starting: Set<SessionID> = []
        /// Set by `handOver`: finish what is running and start nothing more.
        var handingOver = false
    }

    private let state = Locked(State())
    let limits: DaemonLimits
    /// Wakes the daemon's own thread: a status to pass on, or a deadline to look at.
    private let daemonWake: WakePipe

    init(limits: DaemonLimits = DaemonLimits(), daemonWake: WakePipe) {
        self.limits = limits
        self.daemonWake = daemonWake
    }

    // MARK: - Starting and finding

    /// Starts a shell, or says why not. The token is for the session's own connection.
    func start(
        _ launch: ShellLaunch, configuration: Terminal.Configuration, metadata: [UInt8]
    ) -> Result<(id: SessionID, token: [UInt8]), Refusal> {
        guard metadata.count <= SessionWire.largestMetadata else { return .failure(.malformed) }
        // The slot is taken under the same lock as the count, not just the id. Shells are
        // started outside the lock — a fork is not something to hold a lock across — so with
        // only the id reserved, two control connections at the ceiling would both read a count
        // with room in it and both insert, and one could land after `handOver` had promised
        // that nothing more would start.
        let reserved = state.withLock { state -> SessionID? in
            if state.handingOver { return nil }
            guard state.entries.count + state.starting.count < limits.sessions else { return nil }
            let id = SessionID(state.nextID)
            state.nextID += 1
            state.starting.insert(id)
            return id
        }
        guard let id = reserved else {
            return .failure(state.withLock { $0.handingOver } ? .handingOver : .atCapacity)
        }

        let session: Session
        do {
            session = try Session(launch: launch, configuration: configuration) { [weak self] in
                self?.sessionDidUpdate(id)
            }
        } catch {
            state.withLock { _ = $0.starting.remove(id) }
            return .failure(.shellWouldNotStart)
        }

        let token = randomBytes(SessionWire.tokenSize)
        state.withLock { state in
            state.starting.remove(id)
            state.entries[id] = Entry(
                id: id, session: session, shellExecutable: launch.executable,
                startedAtMilliseconds: UInt64(UnixSocket.monotonicMilliseconds()),
                columns: configuration.columns, rows: configuration.rows, metadata: metadata, watcher: nil,
                token: token, tokenIssuedAt: UnixSocket.monotonicMilliseconds(), abandonedAt: nil)
        }
        return .success((id, token))
    }

    /// A token for taking up a session nobody is watching.
    func issueToken(for id: SessionID) -> Result<[UInt8], Refusal> {
        state.withLock { state in
            guard var entry = state.entries[id] else { return .failure(.unknownSession) }
            guard entry.watcher == nil else { return .failure(.alreadyAttached) }
            let token = randomBytes(SessionWire.tokenSize)
            entry.token = token
            entry.tokenIssuedAt = UnixSocket.monotonicMilliseconds()
            state.entries[id] = entry
            return .success(token)
        }
    }

    /// Takes up a session: the token must be the one handed out, unused and not stale.
    ///
    /// The token is spent whether or not it matched, so a wrong guess cannot be followed by a
    /// right one on the same token, and `sameBytes` is used so the time taken says nothing
    /// about how much of it was right.
    func claim(_ id: SessionID, token: [UInt8], watcher: WakePipe) -> Result<Session, Refusal> {
        state.withLock { state in
            guard var entry = state.entries[id] else { return .failure(.unknownSession) }
            guard entry.watcher == nil else { return .failure(.alreadyAttached) }
            guard let expected = entry.token else { return .failure(.unknownSession) }
            entry.token = nil
            let fresh = UnixSocket.monotonicMilliseconds() - entry.tokenIssuedAt <= limits.tokenLifetimeMilliseconds
            guard sameBytes(expected, token), fresh else {
                state.entries[id] = entry
                return .failure(.unknownSession)
            }
            entry.watcher = watcher
            entry.abandonedAt = nil
            state.entries[id] = entry
            return .success(entry.session)
        }
    }

    /// Stops watching, leaving the shell running. The session stops building screens for a
    /// client that is not there.
    ///
    /// `watcher` says who is letting go, and it is released only if it is still the one
    /// watching. An app that was killed and one that has just taken its sessions up overlap:
    /// the dead one's threads notice the end of their sockets at their own pace, and one of
    /// them can get here *after* the new client has claimed the session. Releasing blindly
    /// would then clear the watch that had just been installed and turn publishing off under
    /// it — a reattached pane that stays blank for ever, now and then, for no visible reason.
    func release(_ id: SessionID, watcher: WakePipe) {
        let session = state.withLock { state -> Session? in
            guard var entry = state.entries[id], entry.watcher === watcher else { return nil }
            entry.watcher = nil
            if entry.session.status != .running, entry.abandonedAt == nil {
                entry.abandonedAt = UnixSocket.monotonicMilliseconds()
            }
            state.entries[id] = entry
            return entry.session
        }
        guard let session else { return }
        session.setPublishing(false)
        daemonWake.signal()
    }

    /// Ends a session's shell and forgets it.
    func end(_ id: SessionID) {
        let session = state.withLock { state in state.entries.removeValue(forKey: id)?.session }
        session?.close()
        daemonWake.signal()
    }

    func endEverything() {
        let sessions = state.withLock { state -> [Session] in
            let all = state.entries.values.map(\.session)
            state.entries = [:]
            return all
        }
        for session in sessions { session.close() }
    }

    func setMetadata(_ metadata: [UInt8], for id: SessionID) {
        guard metadata.count <= SessionWire.largestMetadata else { return }
        state.withLock { state in
            guard var entry = state.entries[id] else { return }
            entry.metadata = metadata
            state.entries[id] = entry
        }
    }

    /// What a client is told a session's size is now, which a resize changes.
    func noteSize(_ id: SessionID, columns: Int, rows: Int) {
        state.withLock { state in
            guard var entry = state.entries[id] else { return }
            entry.columns = columns
            entry.rows = rows
            state.entries[id] = entry
        }
    }

    func descriptions() -> [SessionDescription] {
        state.withLock { state in
            state.entries.values
                .sorted { $0.id.value < $1.id.value }
                .map { entry in
                    SessionDescription(
                        id: entry.id, status: entry.session.status, columns: entry.columns, rows: entry.rows,
                        shellExecutable: entry.shellExecutable,
                        startedAtMilliseconds: entry.startedAtMilliseconds, metadata: entry.metadata)
                }
        }
    }

    var count: Int { state.withLock { $0.entries.count } }
    /// Whether the daemon is holding nothing at all — a shell still being started counts, so
    /// it cannot idle out from under one.
    var isEmpty: Bool { state.withLock { $0.entries.isEmpty && $0.starting.isEmpty } }

    func handOver() {
        state.withLock { $0.handingOver = true }
        daemonWake.signal()
    }

    var isHandingOver: Bool { state.withLock { $0.handingOver } }

    // MARK: - Time passing

    /// A session's thread says something changed: wake whoever is watching, and the daemon,
    /// which may have a status to pass on. Called on the session's own thread, so it does
    /// nothing but write to two pipes.
    private func sessionDidUpdate(_ id: SessionID) {
        let watcher = state.withLock { $0.entries[id]?.watcher }
        watcher?.signal()
        daemonWake.signal()
    }

    /// Sessions whose shells have ended and whose end has not been announced yet. Marks them
    /// announced, so each is reported once.
    func endingsToAnnounce() -> [(id: SessionID, status: Session.Status)] {
        state.withLock { state in
            var out: [(id: SessionID, status: Session.Status)] = []
            for (id, var entry) in state.entries {
                let status = entry.session.status
                guard status != .running, !entry.endAnnounced else { continue }
                entry.endAnnounced = true
                if entry.watcher == nil, entry.abandonedAt == nil {
                    entry.abandonedAt = UnixSocket.monotonicMilliseconds()
                }
                state.entries[id] = entry
                out.append((id, status))
            }
            return out
        }
    }

    /// Forgets sessions whose shells ended long enough ago that nobody is coming for them.
    /// Returns how many went.
    @discardableResult
    func dropAbandoned() -> Int {
        state.withLock { state in
            let now = UnixSocket.monotonicMilliseconds()
            let gone = state.entries.filter { _, entry in
                guard let abandonedAt = entry.abandonedAt, entry.watcher == nil else { return false }
                return now - abandonedAt >= limits.abandonedGraceMilliseconds
            }
            for id in gone.keys { state.entries.removeValue(forKey: id) }
            return gone.count
        }
    }

    /// Milliseconds until the soonest thing the daemon has to do, or nil when it has none.
    func nextDeadline() -> Int? {
        state.withLock { state in
            let now = UnixSocket.monotonicMilliseconds()
            return state.entries.values.compactMap { entry -> Int? in
                guard let abandonedAt = entry.abandonedAt, entry.watcher == nil else { return nil }
                return max(abandonedAt + limits.abandonedGraceMilliseconds - now, 0)
            }.min()
        }
    }
}
