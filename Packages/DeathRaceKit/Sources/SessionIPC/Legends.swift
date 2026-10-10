import IPCKit
import PTYKit
import ScreenProtocol
import SessionKit
import VTCore

/// Membership and order, plus a versioned workspace tree, focus and window geometry.
/// Shape 1 remains readable; sessions with unknown metadata still open safely.
public struct SessionPlacement: Sendable, Equatable {
    /// Which window, counted in the order they were opened.
    public var window: Int
    /// Which tab in that window.
    public var tab: Int
    /// Where in that tab's panes, in reading order.
    public var slot: Int
    /// What to put on the tab before the session has drawn anything.
    public var title: String
    public var workspace: SavedWorkspace?

    public init(window: Int, tab: Int, slot: Int, title: String, workspace: SavedWorkspace? = nil) {
        self.window = window
        self.tab = tab
        self.slot = slot
        self.title = title
        self.workspace = workspace
    }

    public func encode() -> [UInt8] {
        var w = ByteWriter()
        let saved = workspace.flatMap { $0.isValid ? $0 : nil }
        w.u8(saved == nil ? 1 : 2)
        w.u32(UInt32(clamping: window))
        w.u32(UInt32(clamping: tab))
        w.u32(UInt32(clamping: slot))
        w.string(String(title.prefix(200)))
        if let saved { w.savedWorkspace(saved) }
        return w.bytes
    }

    /// Nil for bytes this build does not understand — a daemon an older or newer app left
    /// running. Its sessions are still perfectly usable; they just start in a new window.
    public static func decode(_ bytes: [UInt8]) -> SessionPlacement? {
        var r = ByteReader(bytes: bytes)
        guard let shape = try? r.u8(), (shape == 1 || shape == 2),
            let window = try? r.u32(), let tab = try? r.u32(), let slot = try? r.u32(),
            let title = try? r.string()
        else { return nil }
        let workspace: SavedWorkspace?
        if shape == 2 {
            guard let saved = try? r.savedWorkspace() else { return nil }
            workspace = saved
        } else {
            workspace = nil
        }
        guard r.isAtEnd, window < 1_000, tab < 1_000, slot < 1_000 else { return nil }
        return SessionPlacement(
            window: Int(window), tab: Int(tab), slot: Int(slot), title: title, workspace: workspace)
    }
}

/// Which host the app should run its sessions on, and what to say about it.
public enum Legends {
    /// What was decided, and why.
    public enum Choice {
        case daemon(DaemonHost)
        /// Sessions run in this process. `because` is nil when that is simply the setting.
        case inProcess(because: String?)
    }

    /// Tries the daemon when it is wanted, and falls back rather than failing.
    ///
    /// A terminal that will not open because a daemon would not start is a worse terminal
    /// than one whose sessions do not outlive it, so every way this can go wrong ends in a
    /// session in this process and a sentence saying so.
    /// With `wanted` false the daemon is not started, but one already listening is still
    /// talked to: the sessions it is holding were kept by an earlier run with the setting on,
    /// they are still the user's, and an app that refused to look at them would leave shells
    /// running that nothing can reach and nobody can see.
    public static func choose(
        wanted: Bool, paths: DaemonHost.Paths, launcher: any DaemonLauncher, trusting: PeerPolicy = .sameUser,
        deadlineMilliseconds: Int = 2_000
    ) -> Choice {
        guard wanted else {
            guard
                let host = try? DaemonHost(
                    paths: paths, launcher: NoLauncher(), trusting: trusting,
                    deadlineMilliseconds: deadlineMilliseconds)
            else { return .inProcess(because: nil) }
            return .daemon(host)
        }
        do {
            return .daemon(
                try DaemonHost(
                    paths: paths, launcher: launcher, trusting: trusting,
                    deadlineMilliseconds: deadlineMilliseconds))
        } catch {
            return .inProcess(because: sentence(for: error))
        }
    }

    /// Why the daemon is not being used, in words for the settings line.
    public static func sentence(for error: SessionHostError) -> String {
        switch error {
        case .unreachable:
            "Sessions will not outlive this app: the session daemon could not be started."
        case .incompatible:
            "An older session daemon is still running. New sessions start in this app and will not"
                + " outlive it."
        case .refused(let why):
            "Sessions will not outlive this app: \(why)."
        case .atCapacity(let limit):
            "Sessions will not outlive this app: the session daemon is already holding \(limit)."
        case .start(let why):
            "Sessions will not outlive this app: \(why)."
        case .unknownSession, .alreadyAttached:
            "Sessions will not outlive this app: the session daemon answered unexpectedly."
        }
    }

    /// Sessions sorted and grouped by where they said they belonged: a window each, a tab
    /// each within it, and the panes of a tab in the order they sat in.
    ///
    /// A session whose bytes this build cannot read (a daemon an older or newer app left
    /// running) has no placement, so it comes back last, in a window of its own.
    public static func group(_ sessions: [SessionDescription]) -> [[[SessionDescription]]] {
        var placed: [(place: SessionPlacement, session: SessionDescription)] = []
        var unplaced: [SessionDescription] = []
        for session in sessions {
            if let place = SessionPlacement.decode(session.metadata) {
                placed.append((place, session))
            } else {
                unplaced.append(session)
            }
        }
        placed.sort {
            ($0.place.window, $0.place.tab, $0.place.slot, $0.session.id.value)
                < ($1.place.window, $1.place.tab, $1.place.slot, $1.session.id.value)
        }
        var windows: [[[SessionDescription]]] = []
        var lastWindow: Int?
        var lastTab: Int?
        for (place, session) in placed {
            if place.window != lastWindow {
                windows.append([[session]])
                lastWindow = place.window
                lastTab = place.tab
                continue
            }
            if place.tab != lastTab {
                windows[windows.count - 1].append([session])
                lastTab = place.tab
                continue
            }
            let tabs = windows[windows.count - 1].count
            windows[windows.count - 1][tabs - 1].append(session)
        }
        if !unplaced.isEmpty {
            unplaced.sort { $0.id.value < $1.id.value }
            windows.append(unplaced.map { [$0] })
        }
        return windows
    }

    /// What was found waiting, for the line a relaunched app shows. The wording is the one
    /// `docs/NAMING.md` settled on.
    public static func sentence(kept: Int) -> String {
        switch kept {
        case 0: ""
        case 1: "1 session kept running while the app was closed."
        default: "\(kept) sessions kept running while the app was closed."
        }
    }

}
