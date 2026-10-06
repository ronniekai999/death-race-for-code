import Foundation
import IPCKit
import PTYKit
import ScreenProtocol
import SessionIPC
import Testing
import VTCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// What happens when an updated app meets a daemon an older build left running.
///
/// There are two shapes and they are not the same. If the *preamble* cannot be agreed, the
/// handshake itself has failed and there is no connection left to ask over, so the daemon has
/// to stand down by its own decision — `DaemonTests.anIncompatibleClient` covers that. If the
/// preamble agrees and only the *screen format* differs, the connection works, and the app
/// sends the one message worth sending: finish what you hold, start nothing more.
///
/// That second path had no test. Phase 8 is what makes it live — `DeltaCodec.formatVersion`
/// goes to 4 to carry a command's text, duration and exit code on the row — so an app with
/// this change in it, meeting a Phase 7 daemon still holding shells, takes exactly this route.
/// Either way the sessions are never killed: they are what the whole feature exists to keep.
@Suite(.serialized) struct HandOverTests {

    /// A daemon that agrees on the preamble and then names a screen format we do not speak.
    /// It records whatever the app says next.
    private final class OlderDaemon {
        let path: String
        private let listener: Int32
        private let said = Locked<[UInt8]?>(nil)
        private var thread: Thread?

        init(formatVersion: UInt8) throws {
            path = NSTemporaryDirectory() + "ho-" + String(UInt32.random(in: .min ... .max), radix: 16) + ".sock"
            listener = try UnixSocket.listen(at: path)
            let box = said
            let accepting = listener
            let thread = Thread {
                var address = sockaddr()
                var length = socklen_t(MemoryLayout<sockaddr>.size)
                let client = accept(accepting, &address, &length)
                guard client >= 0 else { return }
                defer { close(client) }
                // Read the app's hello, then answer with a welcome naming a format it cannot
                // speak. The versions themselves agree, so the preamble succeeds.
                guard
                    UnixSocket.readFrame(client, limit: SessionWire.largestControlFrame, timeoutMilliseconds: 5_000)
                        != nil
                else { return }
                let facts = DaemonFacts(
                    startedAtMilliseconds: 1, pid: getpid(), deltaFormat: formatVersion, build: "older")
                _ = UnixSocket.writeAll(
                    client,
                    Frames.framed(
                        Preamble.welcome(
                            chosen: SessionWire.versions.lowerBound, speaks: SessionWire.versions, daemon: facts
                        )
                        .encode()))
                // Whatever it says next is the thing under test.
                let next = UnixSocket.readFrame(
                    client, limit: SessionWire.largestControlFrame, timeoutMilliseconds: 5_000)
                box.withLock { $0 = next }
            }
            thread.start()
            self.thread = thread
        }

        /// The frame the app sent after the welcome, waited for rather than guessed at.
        func whatTheAppSaid(withinMilliseconds limit: Int) -> [UInt8]? {
            let deadline = Date().addingTimeInterval(Double(limit) / 1000)
            while Date() < deadline {
                if let frame = said.withLock({ $0 }) { return frame }
                usleep(5_000)
            }
            return said.withLock { $0 }
        }

        func finish() {
            close(listener)
            unlink(path)
        }
    }

    /// The app asks the old daemon to hand over, and falls back to a session in this process
    /// rather than refusing to open a terminal.
    @Test func anOlderScreenFormatIsAskedToHandOver() throws {
        let daemon = try OlderDaemon(formatVersion: DeltaCodec.formatVersion &+ 1)
        defer { daemon.finish() }

        let choice = Legends.choose(
            wanted: true, paths: DaemonHost.Paths(socket: daemon.path, lock: daemon.path + ".lock"),
            launcher: NoLauncher(), deadlineMilliseconds: 3_000)

        // Sessions still open, in this process, and the status bar is given a reason.
        guard case .inProcess(let because) = choice else {
            Issue.record("the app used a daemon whose screen format it cannot read")
            return
        }
        #expect(because != nil)

        // And the old daemon was told to finish what it holds rather than to end anything.
        let frame = try #require(
            daemon.whatTheAppSaid(withinMilliseconds: 3_000), "the app said nothing to a daemon it cannot read")
        #expect(try ControlRequest.decode(frame) == ControlRequest.handOver)
    }

    /// The same screen format is no reason to say anything, and no reason to fall back.
    @Test func amatchingScreenFormatIsNotAskedToHandOver() throws {
        let daemon = try OlderDaemon(formatVersion: DeltaCodec.formatVersion)
        defer { daemon.finish() }

        let choice = Legends.choose(
            wanted: true, paths: DaemonHost.Paths(socket: daemon.path, lock: daemon.path + ".lock"),
            launcher: NoLauncher(), deadlineMilliseconds: 3_000)
        guard case .daemon = choice else {
            Issue.record("the app refused a daemon it agrees with")
            return
        }
        // Nothing is sent on a handshake that worked: the next thing on this socket is
        // whatever the app actually wants to ask.
        let frame = daemon.whatTheAppSaid(withinMilliseconds: 300)
        if let frame { #expect(try ControlRequest.decode(frame) != ControlRequest.handOver) }
    }
}
