import IPCKit
import PTYKit
import ScreenProtocol
import SessionKit
import VTCore

/// Where a session belonged, so it can be put back.
///
/// The daemon stores these bytes against a session and never looks inside them; this is the
/// app's own shape for them. What it restores is **membership and order** — which window,
/// which tab, and where in the row of panes — not the exact proportions of a split. Panes
/// come back where they were, side by side in the order they were in; a divider someone had
/// dragged is not remembered. Saying so is better than implying more.
public struct SessionPlacement: Sendable, Equatable {
    /// Which window, counted in the order they were opened.
    public var window: Int
    /// Which tab in that window.
    public var tab: Int
    /// Where in that tab's panes, in reading order.
    public var slot: Int
    /// What to put on the tab before the session has drawn anything.
    public var title: String

    public init(window: Int, tab: Int, slot: Int, title: String) {
        self.window = window
        self.tab = tab
        self.slot = slot
        self.title = title
    }

    public func encode() -> [UInt8] {
        var w = ByteWriter()
        w.u8(1)  // what shape this is, so an older app can tell it does not know
        w.u32(UInt32(clamping: window))
        w.u32(UInt32(clamping: tab))
        w.u32(UInt32(clamping: slot))
        w.string(String(title.prefix(200)))
        return w.bytes
    }

    /// Nil for bytes this build does not understand — a daemon an older or newer app left
    /// running. Its sessions are still perfectly usable; they just start in a new window.
    public static func decode(_ bytes: [UInt8]) -> SessionPlacement? {
        var r = ByteReader(bytes: bytes)
        guard let shape = try? r.u8(), shape == 1,
            let window = try? r.u32(), let tab = try? r.u32(), let slot = try? r.u32(),
            let title = try? r.string(), r.isAtEnd
        else { return nil }
        guard window < 1_000, tab < 1_000, slot < 1_000 else { return nil }
        return SessionPlacement(
            window: Int(window), tab: Int(tab), slot: Int(slot), title: title)
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
    public static func choose(
        wanted: Bool, paths: DaemonHost.Paths, launcher: any DaemonLauncher, deadlineMilliseconds: Int = 2_000
    ) -> Choice {
        guard wanted else { return .inProcess(because: nil) }
        do {
            return .daemon(
                try DaemonHost(paths: paths, launcher: launcher, deadlineMilliseconds: deadlineMilliseconds))
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

    /// What was found waiting, for the line a relaunched app shows. The wording is the one
    /// `docs/NAMING.md` settled on.
    public static func sentence(kept: Int) -> String {
        switch kept {
        case 0: ""
        case 1: "1 session kept running while the app was closed."
        default: "\(kept) sessions kept running while the app was closed."
        }
    }

    /// What quitting is about to do, for the question it asks. Sessions that will be kept are
    /// not worth asking about; anything else still is.
    public static func quitting(keeping kept: Int, ending: [String]) -> String? {
        guard !ending.isEmpty else { return nil }
        let listed = list(ending)
        let about = ending.count == 1 ? "\(listed) is still running" : "\(listed) are still running"
        guard kept > 0 else { return "\(about). Quit anyway?" }
        let held = kept == 1 ? "1 session will keep running" : "\(kept) sessions will keep running"
        return "\(about), and \(held). Quit anyway?"
    }

    /// "vim", "vim and make", "vim, make and htop".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}
