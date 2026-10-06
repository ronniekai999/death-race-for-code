import Foundation
import IPCKit
import PTYKit
import ScreenProtocol
import SessionKit
import VTCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// How many sessions the daemon will hold, and how long it keeps what nobody has claimed.
public struct DaemonLimits: Sendable {
    /// At the default scrollback budget this is a hard ceiling of a few gigabytes.
    public var sessions = 64
    public var tokenLifetimeMilliseconds = 10_000
    /// How long a shell that ended with nobody watching is kept, so an app starting up can
    /// still say how it went.
    public var abandonedGraceMilliseconds = 300_000
    /// How long a client may make no progress reading before it is dropped. Its session is
    /// never ended for it: it goes back to being one nobody is watching.
    public var writeStallMilliseconds = 30_000

    public init() {}
}

/// Where a signal handler writes, since all it may safely do is `write`.
private nonisolated(unsafe) var shutdownWrite: Int32 = -1
/// 1 for "leave the shells running" (SIGTERM), 2 for "end them" (SIGINT).
private func noteSignal(_ which: Int32) {
    var byte: UInt8 = which == SIGINT ? 2 : 1
    if shutdownWrite >= 0 { _ = write(shutdownWrite, &byte, 1) }
}

/// `legendsd`: it holds the pseudo-terminals and the engines, so sessions outlive the app.
///
/// At rest every thread is parked in `poll` with no timeout — this one on the listener, one
/// for each connection, one for each session's own loop, one for each session being watched.
/// There are no timers and nothing periodic, so a daemon with sessions nobody is watching
/// costs nothing beyond what their programs print.
public final class Daemon: Sendable {
    public struct Options: Sendable {
        public var socketPath: String
        public var lockPath: String
        public var limits = DaemonLimits()
        /// How long it waits, with no sessions and nobody connected, before it exits. An app
        /// that is uninstalled leaves nothing behind.
        public var idleExitMilliseconds = 10_000
        /// Checked at the same moments as everything else, for tests that must not wait.
        public var stopWhenIdle = true
        /// Who may speak to it. The default is the weakest check, which is all a machine
        /// without code signing can make; `legendsd` asks for the strongest it can get.
        public var peerPolicy = PeerPolicy.sameUser

        public init(socketPath: String, lockPath: String) {
            self.socketPath = socketPath
            self.lockPath = lockPath
        }
    }

    /// What the process exits with. Nothing ordinary is a failure: a daemon that finds
    /// another already holding the lock has simply lost a race, and says so with a zero.
    public enum Ending {
        public static let done: Int32 = 0
        public static let cannotSecureFolder: Int32 = 70
        public static let cannotListen: Int32 = 71
    }

    private let options: Options
    private let wake: WakePipe
    private let registry: SessionRegistry
    private let connections = Locked<[ControlConnection]>([])
    /// Connections whose greeting is still in flight: accepted, but not yet a control
    /// connection or a session bridge the counts above would see.
    private let greeting = Locked(0)
    private let facts: DaemonFacts

    public init(_ options: Options) throws(PTYError) {
        self.options = options
        wake = try WakePipe()
        registry = SessionRegistry(limits: options.limits, daemonWake: wake)
        facts = DaemonFacts(
            startedAtMilliseconds: UInt64(UnixSocket.monotonicMilliseconds()), pid: getpid(),
            deltaFormat: DeltaCodec.formatVersion, build: DeltaCodec.formatVersion.description)
    }

    /// Runs until there is nothing left to do, or a signal says to stop. Returns what the
    /// process should exit with.
    public func run() -> Int32 {
        signal(SIGPIPE, SIG_IGN)

        let folder = (options.socketPath as NSString).deletingLastPathComponent
        do {
            try secureFolder(folder, what: "the session daemon's folder")
        } catch {
            return Ending.cannotSecureFolder
        }

        // Before the socket, always. `UnixSocket.listen` replaces whatever is at its path, so
        // two daemons starting together would both bind and the second would leave the first
        // listening on a socket nothing points at — with live sessions nobody could reach.
        guard let lock = ProcessLock.take(at: options.lockPath) else {
            return Ending.done
        }
        defer { lock.release() }

        guard let shutdown = try? WakePipe() else { return Ending.cannotListen }
        shutdownWrite = shutdown.writeFD
        signal(SIGTERM, noteSignal)
        signal(SIGINT, noteSignal)

        guard let listener = try? UnixSocket.listen(at: options.socketPath) else {
            return Ending.cannotListen
        }
        defer {
            close(listener)
            unlink(options.socketPath)
        }

        serve(listener, shutdown: shutdown)
        return Ending.done
    }

    private func serve(_ listener: Int32, shutdown: WakePipe) {
        var idleSince: Int? = UnixSocket.monotonicMilliseconds()
        while true {
            var watched = [
                pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wake.readFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: shutdown.readFD, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&watched, 3, timeout(idleSince: idleSince))
            if ready < 0, errno == EINTR { continue }

            if watched[2].revents & Int16(POLLIN) != 0 {
                var byte: UInt8 = 0
                _ = read(shutdown.readFD, &byte, 1)
                // A daemon cannot outlive itself: it holds every session's pseudo-terminal, so
                // whatever it does on the way out, the masters close and the shells are hung
                // up. So both signals end the sessions, and they end them properly — hung up
                // and then killed if they linger — rather than letting descriptors close under
                // programs that were given no notice. This is why the daemon only ever exits
                // on its own when it holds nothing.
                registry.endEverything()
                return
            }

            if watched[0].revents & Int16(POLLIN) != 0 { accept(on: listener) }
            wake.drain()
            passOnEndings()
            registry.dropAbandoned()
            prune()

            let busy =
                !registry.isEmpty || !connections.withLock({ $0 }).isEmpty || greeting.withLock({ $0 }) > 0
            if busy {
                idleSince = nil
            } else if idleSince == nil {
                idleSince = UnixSocket.monotonicMilliseconds()
            } else if let since = idleSince, options.stopWhenIdle,
                UnixSocket.monotonicMilliseconds() - since >= options.idleExitMilliseconds
            {
                return
            }
        }
    }

    /// How long to wait in `poll`: until the soonest thing there is to do, or for ever.
    private func timeout(idleSince: Int?) -> Int32 {
        var soonest = registry.nextDeadline()
        if let since = idleSince, options.stopWhenIdle {
            let left = max(options.idleExitMilliseconds - (UnixSocket.monotonicMilliseconds() - since), 0)
            soonest = min(soonest ?? left, left)
        }
        guard let soonest else { return -1 }
        return Int32(clamping: soonest)
    }

    /// A session's shell ended: everyone connected is told, once.
    private func passOnEndings() {
        let endings = registry.endingsToAnnounce()
        guard !endings.isEmpty else { return }
        for connection in connections.withLock({ $0 }) {
            for ending in endings {
                connection.announce(.sessionEnded(id: ending.id, status: ending.status))
            }
        }
    }

    private func prune() {
        connections.withLock { $0.removeAll { $0.isFinished } }
    }

    private func accept(on listener: Int32) {
        let client = acceptConnection(listener)
        guard client >= 0 else { return }
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        // Nothing else on this machine may speak to the daemon.
        guard options.peerPolicy.accepts(client) else {
            close(client)
            return
        }
        // Counted before the thread starts and only put down once the greeting is over, so a
        // client that connects on the very pass the idle deadline falls is not left holding a
        // socket whose path has been unlinked underneath it.
        greeting.withLock { $0 += 1 }
        let thread = Thread { [self] in greet(client) }
        thread.name = "legendsd connection"
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Reads the preamble, settles on a version, and hands the connection to whichever kind
    /// of thing it said it was for.
    private func greet(_ client: Int32) {
        // Whatever this turns into, and whether it works, the daemon stops counting the
        // greeting itself — and is woken, so a daemon that was only waiting for this can get
        // on with idling out.
        defer {
            greeting.withLock { $0 -= 1 }
            wake.signal()
        }
        // One reader for the connection's whole life, handed to whatever takes it over. A
        // reader made and dropped per call would throw away anything that arrived with the
        // frame it was waiting for — and a screen can arrive with the reply that precedes it.
        var reader = FrameReader(limit: SessionWire.largestSessionFrame)
        guard
            let payload = UnixSocket.readFrame(
                client, timeoutMilliseconds: ControlConnection.requestTimeout, into: &reader),
            let preamble = try? Preamble.decode(payload),
            case .hello(let theirs, let role) = preamble
        else {
            close(client)
            return
        }
        guard let chosen = Preamble.agree(SessionWire.versions, theirs) else {
            // Say what we speak and leave its sessions alone. A client that cannot talk to
            // this daemon must never be a reason to end what the daemon is holding.
            _ = UnixSocket.writeAll(
                client,
                Frames.framed(Preamble.incompatible(speaks: SessionWire.versions, build: facts.build).encode()))
            close(client)
            // And then stand down. Only a build of this app gets as far as being greeted, so
            // a hello in a version this daemon does not speak means the app has been updated
            // past it: start nothing more and finish when the last session does. It has to be
            // decided here, because there is no connection left to be asked over — the
            // handshake is the thing that failed.
            registry.handOver()
            return
        }
        guard
            UnixSocket.writeAll(
                client,
                Frames.framed(
                    Preamble.welcome(chosen: chosen, speaks: SessionWire.versions, daemon: facts).encode()))
        else {
            close(client)
            return
        }

        switch role {
        case .control:
            let connection = ControlConnection(socket: client, registry: registry, reader: reader)
            connections.withLock { $0.append(connection) }
            wake.signal()
            connection.run()
        case .session:
            guard let pipe = try? WakePipe() else {
                close(client)
                return
            }
            SessionBridge(socket: client, registry: registry, wake: pipe, reader: reader).run()
        }
        wake.signal()
    }

    // MARK: - For the tests

    /// What the daemon holds, for a test that drives it in process.
    public var sessionCount: Int { registry.count }
}

/// The system's `accept`, wrapped: inside the class, the bare call would mean
/// `Daemon.accept(on:)`.
private func acceptConnection(_ listener: Int32) -> Int32 {
    accept(listener, nil, nil)
}
