import Foundation
import IPCKit
import PTYKit
import ScreenProtocol
import SessionIPC
import SessionKit
import Testing
import VTCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Session ids out of what the stand-in client printed.
private func ids(in lines: [String]) -> [UInt64] {
    lines.compactMap { line in
        guard let field = line.split(separator: " ").first(where: { $0.hasPrefix("session=") }) else { return nil }
        return UInt64(field.dropFirst("session=".count))
    }
}

/// Applies deltas until `condition` holds, or the time runs out.
@discardableResult
private func wait(
    on session: any ShellSession, _ mirror: inout MirrorGrid, milliseconds: Int = 10_000,
    until condition: (MirrorGrid) -> Bool
) -> Bool {
    let until = UnixSocket.monotonicMilliseconds() + milliseconds
    while true {
        while let delta = session.takeDelta() {
            do {
                try mirror.apply(delta)
            } catch {
                session.requestSnapshot()
            }
        }
        if condition(mirror) { return true }
        if UnixSocket.monotonicMilliseconds() >= until { return false }
        usleep(10_000)
    }
}

private func text(_ mirror: MirrorGrid) -> String {
    mirror.lines.map { line in
        var out = ""
        for column in line.cells.indices where line.cells[column].width != .spacerTail {
            let scalars = line.scalars(at: column)
            if scalars.isEmpty {
                out += " "
            } else {
                for scalar in scalars { out.unicodeScalars.append(Unicode.Scalar(scalar)!) }
            }
        }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }.joined(separator: " ")
}

@Suite("legendsd, as a second process", .serialized, .timeLimit(.minutes(1)))
struct DaemonTests {
    /// Phase 7's exit criterion, and the reason the stand-in client exists: a test cannot
    /// kill itself, so something else has to play the app.
    ///
    /// What it proves is not that a screen was replayed. After reattaching it **types**, and
    /// what comes back is the shell's own echo — so the pseudo-terminal, the engine and the
    /// shell are all still there and still joined up.
    @Test("every session reattaches after the app is killed")
    func reattachAfterKill() throws {
        let rig = try DaemonRig()
        defer { rig.finish() }

        let started = try rig.startProbe(["--spawn", "3", "--marker", "LEGEND"])
        let sessions = ids(in: started.lines)
        #expect(sessions.count == 3, "the client said: \(started.lines)")
        #expect(started.lines.allSatisfy { !$0.contains("marker=false") }, "\(started.lines)")

        started.child.signal(SIGKILL)
        _ = started.child.waitForExit(timeoutMilliseconds: 2_000)

        #expect(rig.daemonIsRunning, "the daemon went with its client; log: \(rig.log)")

        let listed = try rig.probe(["--list"])
        #expect(ids(in: listed).sorted() == sessions.sorted(), "\(listed)")
        #expect(listed.allSatisfy { !$0.contains("running=false") }, "a shell died with the app: \(listed)")
        // The note of where each session belonged survived too, which is what puts them back
        // in the windows they came from.
        #expect(listed.contains { $0.contains("metadata=pane=0") }, "\(listed)")

        let back = try rig.probe(["--reattach", "--expect", "LEGEND", "--type", "echo alive"])
        #expect(back.filter { $0.hasPrefix("screen=") }.count == 3, "\(back)")
        #expect(back.allSatisfy { !$0.contains("expected=false") }, "a screen was lost: \(back)")
        #expect(back.allSatisfy { !$0.contains("echoed=false") }, "a shell was no longer live: \(back)")
    }

    /// Letting go has two meanings and they must not be confused: a pane closing ends the
    /// shell, the app quitting leaves it running.
    @Test("detaching leaves the shell and closing ends it")
    func detachAndClose() throws {
        let rig = try DaemonRig()
        defer { rig.finish() }

        let started = try rig.startProbe(["--spawn", "1"])
        #expect(ids(in: started.lines).count == 1)
        started.child.signal(SIGKILL)
        _ = started.child.waitForExit(timeoutMilliseconds: 2_000)

        let afterDetach = try rig.probe(["--detach"])
        #expect(afterDetach.contains { $0.hasPrefix("detached=") }, "\(afterDetach)")
        #expect(ids(in: try rig.probe(["--list"])).count == 1, "detaching ended the session")

        _ = try rig.probe(["--end-all"])
        #expect(ids(in: try rig.probe(["--list"])).isEmpty, "closing left the session running")
    }

    /// `UnixSocket.listen` replaces whatever is at its path, so without the lock two daemons
    /// starting together would both bind and the second would leave the first listening on a
    /// socket nothing points at — holding sessions nobody could reach again.
    @Test("a second daemon at one socket exits rather than stealing it")
    func oneDaemonASocket() throws {
        let rig = try DaemonRig()
        defer { rig.finish() }

        let started = try rig.startProbe(["--spawn", "1"])
        let sessions = ids(in: started.lines)
        #expect(sessions.count == 1)

        let executable = try #require(BuiltBinary.path("legendsd"), BuiltBinary.missing("legendsd"))
        let second = try ChildProcess.run(
            executable: executable,
            arguments: ["legendsd", "--socket", rig.socket, "--lock", rig.lock, "--stay"],
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/", timeoutMilliseconds: 10_000)
        #expect(second.status == .exited(code: 0), "the second daemon did not stand down: \(second.status as Any)")
        #expect(rig.daemonIsRunning, "the first daemon went")
        #expect(ids(in: try rig.probe(["--list"])).sorted() == sessions.sorted(), "the first daemon lost its hold")
    }

    /// A client that reads its socket but never takes a screen gets no more of them — the
    /// session coalesces into its own mailbox instead, as it does in process. Its shell keeps
    /// running, and nothing else slows down.
    @Test("a client that acknowledges nothing is not a client that breaks anything")
    func aClientThatNeverAcknowledges() throws {
        let rig = try DaemonRig()
        defer { rig.finish() }

        let started = try rig.startProbe(["--spawn", "2"])
        #expect(ids(in: started.lines).count == 2)
        started.child.signal(SIGKILL)
        _ = started.child.waitForExit(timeoutMilliseconds: 2_000)

        let wedged = try rig.startProbe(["--wedge"])
        #expect(wedged.lines.contains { $0.hasPrefix("wedged=") }, "\(wedged.lines)")

        // The other session answers while the first is being ignored.
        let host = try rig.host()
        let listed = try host.existing()
        let other = try #require(listed.first { !wedged.lines.contains("wedged=\($0.id.value)") })
        let session = try rig.adoptWhenFree(host, other.id)
        var mirror = MirrorGrid()
        #expect(wait(on: session, &mirror) { $0.generation != nil }, "a wedged session held up another")
        session.send(Array("echo other\n".utf8))
        #expect(wait(on: session, &mirror) { text($0).contains("other") })
        session.detach()

        #expect(ids(in: try rig.probe(["--list"])).count == 2, "a session was ended for its client's sake")
    }

    /// A client that stops reading its socket altogether — frozen, or stopped in a debugger —
    /// must not hold a session for ever. It is dropped and the session goes back to being one
    /// nobody is watching, which can be taken up again.
    @Test("a client that stops reading is dropped, and its session is not")
    func aClientThatStopsReading() throws {
        let rig = try DaemonRig(writeStallMilliseconds: 1_000)
        defer { rig.finish() }

        let host = try rig.host()
        let session = try host.start(
            testShell(), configuration: Terminal.Configuration(columns: 40, rows: 8), metadata: [],
            onUpdate: {})
        var mirror = MirrorGrid()
        #expect(wait(on: session, &mirror) { $0.generation != nil })
        let id = session.id

        // A connection of our own that attaches and then never reads a byte, while the shell
        // keeps printing. The daemon's writer fills, makes no progress, and gives up on it.
        session.send(Array("yes legends | head -c 400000\n".utf8))
        usleep(300_000)
        session.detach()

        let silent = try #require(UnixSocket.connect(to: rig.socket))
        defer { closeDescriptor(silent) }
        #expect(
            UnixSocket.writeAll(
                silent, Frames.framed(Preamble.hello(speaks: SessionWire.versions, role: .session).encode())))
        _ = UnixSocket.readFrame(silent, limit: 1 << 20, timeoutMilliseconds: 2_000)

        // Taking it up needs a token, which only the control connection hands out.
        let adopted = try rig.adoptWhenFree(host, id)
        #expect(adopted.id == id)
        adopted.detach()

        // After the stall the daemon has let go of whatever was watching, and it can be taken
        // up once more — which is the thing that must still be true.
        usleep(1_500_000)
        let again = try rig.adoptWhenFree(host, id)
        #expect(again.id == id, "the session could not be taken up again")
        again.close()
    }

    /// An app that cannot talk to the daemon an older one left running must never be a reason
    /// to end what it is holding. It is told what the daemon speaks, and nothing else happens.
    @Test("a client it cannot talk to is refused, and no session is ended")
    func anIncompatibleClient() throws {
        let rig = try DaemonRig()
        defer { rig.finish() }

        let started = try rig.startProbe(["--spawn", "1"])
        let sessions = ids(in: started.lines)
        #expect(sessions.count == 1)

        let socket = try #require(UnixSocket.connect(to: rig.socket))
        defer { closeDescriptor(socket) }
        #expect(UnixSocket.writeAll(socket, Frames.framed(Preamble.hello(speaks: 999...999, role: .control).encode())))
        let payload = try #require(
            UnixSocket.readFrame(socket, limit: SessionWire.largestControlFrame, timeoutMilliseconds: 5_000))
        guard case .incompatible(let speaks, _) = try Preamble.decode(payload) else {
            Issue.record("the daemon did not say it could not talk to us")
            return
        }
        #expect(speaks == SessionWire.versions)
        #expect(rig.daemonIsRunning, "it took itself down over a client")
        #expect(ids(in: try rig.probe(["--list"])).sorted() == sessions.sorted(), "it ended a session")

        // And it stands down: the only thing that gets as far as being greeted is a build of
        // this app, so a version it cannot speak means the app has moved past it. It finishes
        // what it holds and starts nothing more — the handshake is what failed, so there is no
        // connection left to be asked over, and it has to decide this itself.
        let host = try rig.host()
        var refused = false
        do {
            _ = try host.start(
                testShell(), configuration: Terminal.Configuration(columns: 80, rows: 24), metadata: [],
                onUpdate: {})
        } catch {
            refused = true
        }
        #expect(refused, "it started a session after promising to hand over")
        #expect(ids(in: try rig.probe(["--list"])).sorted() == sessions.sorted(), "it ended a session")
    }

    @Test("a connection that says nothing a daemon understands is dropped")
    func nonsenseIsDropped() throws {
        let rig = try DaemonRig()
        defer { rig.finish() }
        let socket = try #require(UnixSocket.connect(to: rig.socket))
        defer { closeDescriptor(socket) }
        #expect(UnixSocket.writeAll(socket, Frames.framed(Array("GET / HTTP/1.1".utf8))))
        // Nothing comes back, and the daemon is still there for a client that makes sense.
        #expect(UnixSocket.readFrame(socket, limit: 4_096, timeoutMilliseconds: 1_000) == nil)
        #expect(rig.daemonIsRunning)
        #expect(try rig.host().existing().isEmpty)
    }

    /// Found by a review and reproduced before it was fixed: the bridge held bytes the
    /// session would not take, and a session whose shell has ended never takes any. It would
    /// then stop reading its socket for good — so the client's own `close` never arrived, the
    /// session stayed in the registry with a watcher that could not finish, and the thread
    /// spun on a socket nobody would drain.
    @Test("typing into a shell that has ended does not wedge its bridge")
    func typingAtADeadShell() throws {
        let rig = try DaemonRig(idleExitMilliseconds: patience(1_000))
        defer { rig.finish() }
        let host = try rig.host()

        var launch = testShell()
        launch.arguments = ["sh", "-c", "exit 7"]
        let session = try host.start(
            launch, configuration: Terminal.Configuration(columns: 80, rows: 24), metadata: [], onUpdate: {})

        // Wait for the shell to go, which is what makes the session refuse everything.
        let until = UnixSocket.monotonicMilliseconds() + patience(5_000)
        while session.status == .running, UnixSocket.monotonicMilliseconds() < until { usleep(20_000) }
        #expect(session.status != .running, "the shell should have exited")

        // Type at it, let that reach the daemon, and only then close it. The wait matters:
        // `close` goes in the control lane and input in the bulk one, so asking for both at
        // once would have the close overtake the input and the wedge would never happen.
        for _ in 0..<4 { _ = session.send(Array("echo hello\r".utf8)) }
        usleep(UInt32(patience(200) * 1_000))
        session.close()

        let gone = UnixSocket.monotonicMilliseconds() + patience(5_000)
        var left = 1
        while UnixSocket.monotonicMilliseconds() < gone {
            left = (try? host.existing().count) ?? left
            if left == 0 { break }
            usleep(50_000)
        }
        #expect(left == 0, "the session was still held after close")
    }

    /// Also from the review, also reproduced: the remote session counted input on the way in
    /// and never counted it off again, so a pane stopped taking keystrokes for good once
    /// sixteen megabytes had passed through it over its whole life.
    @Test("input is bounded by what is waiting, not by everything ever sent")
    func inputIsNotCumulative() throws {
        let rig = try DaemonRig()
        defer { rig.finish() }
        let host = try rig.host()

        var launch = testShell()
        launch.arguments = ["sh", "-c", "cat > /dev/null"]
        let session = try host.start(
            launch, configuration: Terminal.Configuration(columns: 80, rows: 24), metadata: [], onUpdate: {})
        defer { session.close() }

        // Twice the limit, a megabyte at a time, with time to drain between.
        let megabyte = [UInt8](repeating: 0x61, count: 1 << 20)
        var refused = 0
        for _ in 0..<32 {
            if !session.send(megabyte) { refused += 1 }
            usleep(2_000)
        }
        #expect(refused == 0, "\(refused) of 32 megabytes were refused")
        #expect(session.send(Array("x".utf8)), "a single byte was refused after the run")
    }

    /// A security review's finding, against the real binary. The daemon reopens its own
    /// output onto a log before anything else, and the folder that log sits in keeps other
    /// users out while doing nothing about another process of this one. Following a symlink
    /// there — and then pruning the file it pointed at — would hand a process with no privacy
    /// grants of its own a way to destroy a file macOS was keeping it out of, because this
    /// daemon is the app's own child and carries the app's attribution.
    @Test("a symlink planted at the log's path is not followed or truncated")
    func aPlantedLogIsRefused() throws {
        let folder = NSTemporaryDirectory() + "lgdlog-" + String(UInt32.random(in: .min ... .max), radix: 16)
        try FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: folder) }

        // Something the daemon must not touch, over a megabyte so the pruning would fire.
        let victim = folder + "/precious"
        let contents = Data([UInt8](repeating: 0x2e, count: (1 << 20) + 16))
        try contents.write(to: URL(fileURLWithPath: victim))
        #expect(symlink(victim, folder + "/d.log") == 0)

        let executable = try #require(BuiltBinary.path("legendsd"), BuiltBinary.missing("legendsd"))
        let daemon = try ChildProcess.spawn(
            executable: executable,
            arguments: [
                "legendsd", "--socket", folder + "/s.sock", "--lock", folder + "/s.lock", "--log",
                folder + "/d.log", "--idle-exit", String(patience(500)),
            ],
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/", newSession: true)
        defer {
            daemon.signal(SIGKILL)
            _ = daemon.waitForExit(timeoutMilliseconds: 2_000)
        }
        _ = daemon.waitForExit(timeoutMilliseconds: patience(5_000))

        let after = try #require(FileManager.default.attributesOfItem(atPath: victim)[.size] as? Int)
        #expect(after == contents.count, "the file the link pointed at was changed: \(after) bytes")
    }

    @Test("it holds no more sessions than it was told to")
    func itsLimit() throws {
        let rig = try DaemonRig(sessions: 2)
        defer { rig.finish() }
        let host = try rig.host()
        var kept: [any ShellSession] = []
        for _ in 0..<2 {
            kept.append(
                try host.start(
                    testShell(), configuration: Terminal.Configuration(), metadata: [], onUpdate: {}))
        }
        #expect(throws: SessionHostError.self) {
            _ = try host.start(testShell(), configuration: Terminal.Configuration(), metadata: [], onUpdate: {})
        }
        for session in kept { session.close() }
    }

    /// Nobody connected and nothing held: the daemon tidies itself away, so an app that is
    /// uninstalled leaves nothing running and no socket behind.
    @Test("with nothing to hold it exits on its own")
    func idleExit() throws {
        let rig = try DaemonRig(idleExitMilliseconds: 300)
        defer { rig.finish() }
        #expect(rig.waitUntilGone(10_000), "it stayed with nothing to do; log: \(rig.log)")
        #expect(!FileManager.default.fileExists(atPath: rig.socket), "it left its socket behind")
    }

    /// Idle means idle. Every thread is parked in `poll` with no timeout, so a daemon holding
    /// sessions nobody is watching costs nothing at all.
    @Test("holding sessions nobody is watching costs nothing")
    func idleCostsNothing() throws {
        let rig = try DaemonRig()
        defer { rig.finish() }
        let started = try rig.startProbe(["--spawn", "4"])
        #expect(ids(in: started.lines).count == 4)
        started.child.signal(SIGKILL)
        _ = started.child.waitForExit(timeoutMilliseconds: 2_000)

        let pid = try #require(rig.daemonPID)
        guard let before = processorMilliseconds(pid) else { return }  // only /proc can say
        usleep(2_000_000)
        let after = try #require(processorMilliseconds(pid))
        // The Thread Sanitizer makes every instruction cost more, so the budget is about the
        // shape — nothing periodic, nothing polling — rather than an absolute.
        let budget = underThreadSanitizer ? 400 : 40
        #expect(after - before <= budget, "four idle sessions cost \(after - before) ms over two seconds")
    }

}

@Suite("The app's end of the daemon", .serialized, .timeLimit(.minutes(1)))
struct DaemonHostTests {
    @Test("it says plainly that its sessions outlive this process")
    func itSurvives() throws {
        let rig = try DaemonRig()
        defer { rig.finish() }
        #expect(try rig.host().sessionsSurviveQuit)
    }

    @Test("a session started through the daemon behaves like one in this process")
    func likeAnyOther() throws {
        let rig = try DaemonRig()
        defer { rig.finish() }
        let host = try rig.host()
        let session = try host.start(
            testShell(), configuration: Terminal.Configuration(columns: 40, rows: 8), metadata: [], onUpdate: {})
        var mirror = MirrorGrid()
        #expect(wait(on: session, &mirror) { $0.generation != nil })
        session.send(Array("echo $((900+99))\n".utf8))
        #expect(wait(on: session, &mirror) { text($0).contains("999") })
        session.close()
    }

    @Test("it can be asked what is in the foreground, and for the text on screen")
    func theTwoQuestions() async throws {
        let rig = try DaemonRig()
        defer { rig.finish() }
        let host = try rig.host()
        let session = try host.start(
            testShell(), configuration: Terminal.Configuration(columns: 40, rows: 8), metadata: [], onUpdate: {})
        var mirror = MirrorGrid()
        session.send(Array("echo 999\n".utf8))
        #expect(wait(on: session, &mirror) { text($0).contains("999") })

        let foreground = await session.foregroundProcess()
        #expect(foreground?.isShell == true, "\(foreground as Any)")

        let whole = try #require(mirror.allLines)
        let onScreen = await session.text(in: whole, generation: mirror.generation ?? 0)
        #expect(onScreen?.contains("999") == true, "\(onScreen as Any)")
        session.close()
    }

    /// The Phase 6 lesson, across a process boundary this time: a continuation nobody resumes
    /// cannot be cancelled, so a question whose answer can never come has to be answered with
    /// nothing — or the test run never ends.
    @Test("every question is answered when the daemon dies under it")
    func noQuestionIsLeftOwing() async throws {
        let rig = try DaemonRig()
        let host = try rig.host()
        let session = try host.start(
            testShell(), configuration: Terminal.Configuration(columns: 40, rows: 8), metadata: [], onUpdate: {})
        var mirror = MirrorGrid()
        #expect(wait(on: session, &mirror) { $0.generation != nil })

        let region = try #require(mirror.allLines)
        let generation = mirror.generation ?? 0
        rig.finish()

        let answered = await Finished.within(5) {
            _ = await session.text(in: region, generation: generation)
            _ = await session.foregroundProcess()
        }
        #expect(answered, "a question was left waiting on a daemon that had gone")
    }

    /// Nothing listening and no launcher: the app has to be told, so it can run its sessions
    /// in process and say so, rather than hanging on a socket nobody is behind.
    @Test("nothing listening is said at once, not waited on")
    func nothingListening() throws {
        let folder = NSTemporaryDirectory() + "lgd-none-" + String(UInt32.random(in: .min ... .max), radix: 16)
        try FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let started = UnixSocket.monotonicMilliseconds()
        #expect(throws: SessionHostError.self) {
            _ = try DaemonHost(
                paths: DaemonHost.Paths(socket: folder + "/s.sock", lock: folder + "/s.lock"),
                launcher: NothingLauncher(), deadlineMilliseconds: 500)
        }
        #expect(UnixSocket.monotonicMilliseconds() - started < 2_000, "it waited longer than it was given")
    }

    /// The app spawns the daemon itself, which is the hosting the spike is measuring: a child
    /// in a session of its own, so it outlives the app without launchd ever being involved.
    @Test("it starts a daemon when there is none")
    func itStartsOne() throws {
        let folder = NSTemporaryDirectory() + "lgd-spawn-" + String(UInt32.random(in: .min ... .max), radix: 16)
        try FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let executable = try #require(BuiltBinary.path("legendsd"), BuiltBinary.missing("legendsd"))
        let host = try DaemonHost(
            paths: DaemonHost.Paths(socket: folder + "/s.sock", lock: folder + "/s.lock"),
            launcher: SpawnLauncher(executable: executable, logPath: folder + "/d.log", extra: ["--stay"]),
            deadlineMilliseconds: 10_000)
        #expect(host.daemon.pid > 0)
        #expect(host.daemon.deltaFormat == DeltaCodec.formatVersion)
        let session = try host.start(
            testShell(), configuration: Terminal.Configuration(), metadata: [], onUpdate: {})
        session.close()
        #expect(isRunning(host.daemon.pid))
        kill(host.daemon.pid, SIGKILL)
        try? FileManager.default.removeItem(atPath: folder)
    }
}
