import Foundation
import PTYKit
import Vault

/// Come & Go: the tunnels the app has open, each through its host's master. OpenSSH can't
/// list what a master forwards, so this is the record.
///
/// A tunnel uses its host's master as a pane does: turning one on joins the master (or
/// starts one, with no pane) and asks it to forward; turning it off asks it to stop and
/// lets the master go. A master that ends takes its tunnels with it.
public final class TunnelBoard: Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public enum State: Equatable, Sendable {
            case opening
            case open(since: Date)
            /// Why it isn't open, as a sentence.
            case failed(String)
            case closed
        }

        public var tunnel: Tunnel
        /// The host's master, by `ConnectionTarget.key`.
        public var hostKey: String
        public var hostName: String
        public var state: State

        public var id: TunnelID { tunnel.id }

        public var isOpen: Bool {
            if case .open = state { return true }
            return false
        }

        /// "5432 → db:5432 · Local · through prod-api · open since 10:42", or why it isn't
        /// open. `time` writes the time of day.
        public func text(time: (Date) -> String) -> String {
            let summary = tunnel.spec.summary(host: hostName)
            switch state {
            case .opening: return summary + " · opening…"
            case .open(let since): return summary + " · open since " + time(since)
            case .failed(let why): return summary + " · " + why
            case .closed: return summary
            }
        }
    }

    private let pool: MasterPool
    private let controller: TunnelController
    private let now: @Sendable () -> Date
    /// In the order they were first turned on.
    private let rows = Locked<[Row]>([])

    public init(pool: MasterPool, controller: TunnelController, now: @escaping @Sendable () -> Date = { Date() }) {
        self.pool = pool
        self.controller = controller
        self.now = now
    }

    /// Every tunnel the board knows, in the order they were first turned on.
    public var all: [Row] { rows.withLock { $0 } }

    public func row(_ id: TunnelID) -> Row? { rows.withLock { $0.first { $0.id == id } } }

    /// How many are open: the status bar's "⇄ 2 tunnels".
    public var openCount: Int { rows.withLock { $0.filter(\.isOpen).count } }

    private static func user(_ id: TunnelID) -> String { "tunnel:\(id.rawValue)" }

    /// Turns `tunnel` on through `target`'s master, starting one if the host has none.
    @discardableResult
    public func open(_ tunnel: Tunnel, on target: ConnectionTarget, secrets: [String: SavedSecret] = [:]) async
        -> Row.State
    {
        let started = rows.withLock { rows -> Bool in
            let row = Row(tunnel: tunnel, hostKey: target.key, hostName: target.name, state: .opening)
            guard let index = rows.firstIndex(where: { $0.id == tunnel.id }) else {
                rows.append(row)
                return true
            }
            if rows[index].state == .opening || rows[index].isOpen { return false }
            rows[index] = row
            return true
        }
        guard started else { return row(tunnel.id)?.state ?? .closed }
        let state: Row.State
        switch await pool.connect(target, for: Self.user(tunnel.id), secrets: secrets) {
        case .failed(let failure):
            pool.release(Self.user(tunnel.id))
            state = .failed(failure.sentence(host: target.name))
        case .ready:
            do {
                try await controller.open(tunnel.spec, socket: target.controlPath)
                state = .open(since: now())
            } catch {
                pool.release(Self.user(tunnel.id))
                state = .failed(error.sentence)
            }
        }
        let stillWanted = rows.withLock { rows -> Bool in
            guard let index = rows.firstIndex(where: { $0.id == tunnel.id }), rows[index].state == .opening else {
                return false
            }
            rows[index].state = state
            return true
        }
        // Turned off while it was opening: it stays off.
        if !stillWanted, case .open = state {
            try? await controller.close(tunnel.spec, socket: target.controlPath)
            pool.release(Self.user(tunnel.id))
        }
        return row(tunnel.id)?.state ?? .closed
    }

    /// Turns it off: new connections are refused, ones already through run on; its host's
    /// master is let go.
    public func close(_ id: TunnelID) async {
        let row = rows.withLock { rows -> Row? in
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
            defer { rows[index].state = .closed }
            return rows[index]
        }
        guard let row else { return }
        if row.isOpen, let master = pool.master(for: row.hostKey) {
            try? await controller.close(row.tunnel.spec, socket: master.controlPath)
        }
        if row.state != .opening { pool.release(Self.user(id)) }
    }

    /// Opens `tunnels` that open with the connection and aren't open yet: a pane on their
    /// host has just connected.
    public func openWithConnection(_ tunnels: [Tunnel], on target: ConnectionTarget) async {
        for tunnel in tunnels where tunnel.opensWithConnection {
            if let row = row(tunnel.id), row.state == .opening || row.isOpen { continue }
            await open(tunnel, on: target)
        }
    }

    /// The host's master ended, and its tunnels with it.
    public func hostEnded(_ key: String) {
        rows.withLock { rows in
            for index in rows.indices where rows[index].hostKey == key && rows[index].isOpen {
                rows[index].state = .failed("closed when the connection to \(rows[index].hostName) ended")
            }
        }
    }
}
