import Foundation
import IPCKit
import SSHKit
import SessionIPC
import SessionKit
import os

/// Legends Never Die, as the app sees it: where a pane's session comes from, which sessions
/// were found still running, and where each one belonged.
///
/// The daemon is never required. A missing binary, a folder it cannot have, a handshake it
/// cannot finish or a version it does not share all end the same way: sessions run in this
/// process, as they did in every phase before this one, and the status bar says so. A
/// terminal that will not open because a daemon would not start is a worse terminal than one
/// whose sessions do not outlive it.
@MainActor
final class LegendsService {
    private let log = Logger(subsystem: "local.deathraceforcode.DeathRace", category: "legends")
    private let paths: WRLDPaths
    /// Overridden in tests, which must never spawn a daemon or touch `~/.deathrace`.
    private let makeHost: @MainActor (Bool) -> Legends.Choice

    /// The daemon, while there is a usable one. It is kept even when the setting is turned
    /// off, because the sessions it is already holding are still its, and still have to be
    /// told where they sit.
    private var host: (any SessionHost)?
    /// Whether the setting asks for it. Turning it off sends new sessions to this process
    /// and leaves everything already running exactly where it is.
    private var wanted = true

    /// Where a new session should go: nil means this process.
    var daemon: (any SessionHost)? { wanted ? host : nil }
    /// Why sessions will not outlive this app, when they will not and that is not simply the
    /// setting. Kept for the log and for Settings; the status bar shows a short form.
    private(set) var note: String?
    /// Sessions found still running, grouped as they were: windows, then tabs, then the panes
    /// of a tab in reading order.
    private(set) var kept: [[[SessionDescription]]] = []
    /// What the next pane to be made should take up, in the order the windows rebuild them.
    /// Emptied by `doneReattaching()`, so a tab opened later always starts a shell of its own
    /// rather than quietly taking up a session nobody put back.
    private var waiting: [SessionID] = []
    /// Set while the windows are being rebuilt. Nothing is written about where a session sits
    /// until they are all there, because a half-built set of windows is not where anything
    /// belongs.
    private var reattaching = false
    /// Where each session was last told it is, as window, tab and slot, so an unchanged
    /// layout writes nothing.
    ///
    /// The title is deliberately not part of this. It rides along with whatever write a move
    /// makes, but it never causes one: a program that keeps rewriting its title (a build with
    /// a count in it) would otherwise mean a socket write a second for a label that is
    /// replaced by the session's first delta anyway.
    private var placements: [SessionID: [Int]] = [:]

    init(paths: WRLDPaths, makeHost: (@MainActor (Bool) -> Legends.Choice)? = nil) {
        self.paths = paths
        self.makeHost = makeHost ?? { wanted in LegendsService.chooseDaemon(paths: paths, wanted: wanted) }
    }

    /// `legendsd` beside the running executable: Contents/MacOS in the app, the build folder
    /// in a debug run — the same place `deathrace-askpass` is found.
    static var bundledDaemon: String {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.deletingLastPathComponent().appendingPathComponent("legendsd").path
    }

    /// The real daemon: started by us, in a session of its own, pinned to our signature.
    ///
    /// It is our own child rather than a LaunchAgent because privacy permission (TCC) passes
    /// down through fork and exec and is reassigned only where launchd or LaunchServices
    /// starts something — so a daemon the app spawned, and the shells it runs, should stay
    /// attributed to Death Race. `docs/SPIKE.md` is what measures that; until its verdict is
    /// recorded this is the arrangement the design review favoured, and the launcher is a
    /// seam precisely so the answer can change it.
    private static func chooseDaemon(paths: WRLDPaths, wanted: Bool) -> Legends.Choice {
        let places = DaemonHost.Paths(socket: paths.daemonSocket, lock: paths.daemonLock)
        let trusting = PeerPolicy.strongest(for: "local.deathraceforcode.legendsd")
        // Nothing is to be started, but one already listening is still worth talking to.
        guard wanted else {
            return Legends.choose(wanted: false, paths: places, launcher: NoLauncher(), trusting: trusting)
        }
        // The daemon checks this folder and will not create it: it has to exist, 0700 and
        // ours, before anything is spawned.
        do {
            try FileManager.default.createDirectory(
                atPath: paths.runFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try secureFolder(paths.runFolder, what: "the session daemon's folder")
        } catch {
            return .inProcess(
                because: "Sessions will not outlive this app: \(paths.runFolder) could not be used (\(error)).")
        }
        return Legends.choose(
            wanted: true, paths: places,
            launcher: SpawnLauncher(executable: bundledDaemon, logPath: paths.daemonLog), trusting: trusting)
    }

    /// Chooses the host and asks it what is already running. Called once, before the first
    /// window: a window built before this would have made its sessions in process.
    func start(wanted: Bool) {
        self.wanted = wanted
        choose()
        // Through `host`, not `daemon`: with the setting off there is nothing to start and
        // nothing new to keep, but a daemon that is already there is holding shells from a run
        // when the setting was on. Those are still the user's, and leaving them unlisted would
        // leave them running where nothing can reach them and nobody can see them.
        guard let host else { return }
        do {
            kept = Legends.group(try host.existing())
            waiting = kept.flatMap { $0.flatMap { $0.map(\.id) } }
            for (window, tabs) in kept.enumerated() {
                for (tab, panes) in tabs.enumerated() {
                    for (slot, session) in panes.enumerated() { placements[session.id] = [window, tab, slot] }
                }
            }
            if !waiting.isEmpty {
                reattaching = true
                log.info("\(Legends.sentence(kept: self.waiting.count), privacy: .public)")
            }
        } catch {
            // Sessions may well be there; we just cannot be told about them. New ones still
            // go to the daemon, so they outlive this app even if these are left behind.
            log.error("The session daemon would not list its sessions: \(String(describing: error), privacy: .public)")
        }
    }

    private func choose() {
        switch makeHost(wanted) {
        case .daemon(let daemon):
            host = daemon
            note = nil
            log.info("Legends Never Die: sessions are held by the session daemon")
        case .inProcess(let because):
            host = nil
            note = because
            if let because { log.error("\(because, privacy: .public)") }
        }
    }

    /// The setting changed while the app was running.
    ///
    /// Neither direction moves a session: a shell running in this app cannot be handed to a
    /// daemon, and one the daemon holds is not dragged back. What changes is where the next
    /// session goes. Turning it off is not a reason to say anything in the status bar —
    /// nobody is being surprised.
    func setWanted(_ wanted: Bool) {
        guard wanted != self.wanted else { return }
        self.wanted = wanted
        if wanted, host == nil {
            choose()
        } else if !wanted {
            note = nil
        }
    }

    /// Nothing is waiting to come back, so the app opens a window the ordinary way.
    var hasNothingToReattach: Bool { waiting.isEmpty }

    /// The windows are built. Anything still waiting is a session no pane took up — it keeps
    /// running and comes back next time, which is better than ending someone's shell to tidy
    /// up, but it must not be handed to the next tab somebody opens.
    func doneReattaching() {
        reattaching = false
        if !waiting.isEmpty {
            log.error("\(self.waiting.count) kept sessions were not put back; they are still running")
            waiting = []
        }
    }

    /// Whether the status bar should say sessions go when the app does: the daemon was wanted
    /// and could not be had. With the setting off, nobody expected otherwise.
    var sessionsEndWithTheApp: Bool { note != nil }

    // MARK: - Making a pane's session

    /// What `PaneController` calls. It takes the next session waiting to come back, if the
    /// window is rebuilding one; otherwise it starts a new one wherever sessions live.
    var maker: SessionMaker {
        { [weak self] launch, configuration, mayOutliveTheApp, onUpdate in
            guard let self, mayOutliveTheApp, let daemon = self.daemon else {
                return try PaneController.realSession(launch, configuration, mayOutliveTheApp, onUpdate)
            }
            if let id = self.waiting.first {
                self.waiting.removeFirst()
                do {
                    return try daemon.adopt(id, onUpdate: onUpdate)
                } catch {
                    // It ended, or something else took it: the pane still gets a shell.
                    self.log.error(
                        "Session \(id.value) could not be taken up: \(String(describing: error), privacy: .public)")
                }
            }
            if let session = self.startOnDaemon(daemon, launch, configuration, onUpdate) { return session }
            return try PaneController.realSession(launch, configuration, mayOutliveTheApp, onUpdate)
        }
    }

    /// A method rather than the body of the closure above, and it has to be: `SessionHost.start`
    /// is `throws(SessionHostError)`, and `catch` infers that typed error inside a function but
    /// not inside a multi-statement closure, where it widens to `any Error` — which is what
    /// `fellBack` cannot take. Inlining this again brings back a macOS-only build failure.
    ///
    /// nil means the daemon would not start it and the pane should have a shell in this process.
    private func startOnDaemon(
        _ daemon: any SessionHost, _ launch: ShellLaunch, _ configuration: Terminal.Configuration,
        _ onUpdate: @escaping @Sendable () -> Void
    ) -> (any PaneSession)? {
        do {
            return try daemon.start(launch, configuration: configuration, metadata: [], onUpdate: onUpdate)
        } catch {
            fellBack(error)
            return nil
        }
    }

    /// A session the daemon would not start. When the daemon itself is the problem, stop
    /// using it: every later pane goes straight to a session in this process rather than
    /// waiting out the same deadline again.
    private func fellBack(_ error: SessionHostError) {
        let sentence = Legends.sentence(for: error)
        note = sentence
        log.error("\(sentence, privacy: .public)")
        switch error {
        case .unreachable, .incompatible, .refused: host = nil
        case .atCapacity, .start, .unknownSession, .alreadyAttached: break
        }
    }

    // MARK: - Where each session belongs

    /// Records where every session is now, so the sessions that outlive this app can be put
    /// back. Called when the windows change, which is a thing someone did, so there is
    /// nothing periodic here and nothing happens at rest.
    ///
    /// `layout` is the windows in the order they were opened, each a list of tabs, each a
    /// list of its panes' sessions and titles in reading order.
    func noteLayout(_ layout: [[[(id: SessionID, title: String)]]]) {
        // `host`, for the reason it is kept when the setting goes off: the sessions it is
        // already holding will come back, so where they sit still has to be written down.
        guard !reattaching, let host else { return }
        var seen: Set<SessionID> = []
        for (window, tabs) in layout.enumerated() {
            for (tab, panes) in tabs.enumerated() {
                for (slot, pane) in panes.enumerated() {
                    seen.insert(pane.id)
                    let at = [window, tab, slot]
                    guard placements[pane.id] != at else { continue }
                    placements[pane.id] = at
                    host.setMetadata(
                        SessionPlacement(window: window, tab: tab, slot: slot, title: pane.title).encode(),
                        for: pane.id)
                }
            }
        }
        // A session no window holds any more is one this app has let go of; forgetting it
        // keeps the table the size of what is on screen.
        placements = placements.filter { seen.contains($0.key) }
    }
}
