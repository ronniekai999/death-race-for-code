import Dispatch
import PTYKit
import ScreenProtocol
import Testing
import VTCore

@testable import SessionKit

/// A session and an app-side mirror, updated the way the app updates them.
private final class Harness {
    let session: Session
    var mirror = MirrorGrid()
    var events: [TerminalEvent] = []
    private let updates = DispatchSemaphore(value: 0)

    init(columns: Int = 40, rows: Int = 8, arguments: [String] = ["sh"]) throws {
        let launch = ShellLaunch(
            executable: "/bin/sh", arguments: arguments,
            environment: ShellLaunch.terminalEnvironment(
                inheriting: ["PATH": "/usr/bin:/bin", "PS1": "$ "], appVersion: "test"))
        let semaphore = updates
        session = try Session(
            launch: launch, configuration: Terminal.Configuration(columns: columns, rows: rows),
            onUpdate: { semaphore.signal() })
    }

    deinit { session.close() }

    var text: String {
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
        }.joined(separator: "\n")
    }

    /// Applies deltas as they arrive until `condition` holds or `timeout` passes.
    @discardableResult
    func waitUntil(timeout milliseconds: Int = 5_000, _ condition: (Harness) -> Bool) -> Bool {
        let deadline = PseudoTerminal.monotonicMilliseconds() + milliseconds
        while true {
            while let delta = session.takeDelta() {
                do {
                    try mirror.apply(delta)
                } catch {
                    session.requestSnapshot()
                }
                events += delta.events
            }
            if condition(self) { return true }
            let remaining = deadline - PseudoTerminal.monotonicMilliseconds()
            if remaining <= 0 { return false }
            _ = updates.wait(timeout: .now() + .milliseconds(min(remaining, 100)))
        }
    }

    func type(_ text: String) {
        session.send(Array(text.utf8))
    }

    /// Takes deltas and throws them away, as an app whose mirror refused them would, until
    /// one satisfies `condition`.
    func dropDeltas(timeout milliseconds: Int = 5_000, until condition: (ScreenDelta) -> Bool) -> Bool {
        let deadline = PseudoTerminal.monotonicMilliseconds() + milliseconds
        while true {
            while let delta = session.takeDelta() {
                if condition(delta) { return true }
            }
            let remaining = deadline - PseudoTerminal.monotonicMilliseconds()
            if remaining <= 0 { return false }
            _ = updates.wait(timeout: .now() + .milliseconds(min(remaining, 100)))
        }
    }

    /// Whether a delta arrives within `milliseconds`, for checking that none does.
    func deltaArrives(within milliseconds: Int) -> Bool {
        let deadline = PseudoTerminal.monotonicMilliseconds() + milliseconds
        while PseudoTerminal.monotonicMilliseconds() < deadline {
            if session.takeDelta() != nil { return true }
            _ = updates.wait(timeout: .now() + .milliseconds(25))
        }
        return false
    }

    /// Takes deltas and throws them away until none has come for `quiet` milliseconds.
    func dropDeltas(quietFor quiet: Int) {
        var last = PseudoTerminal.monotonicMilliseconds()
        while PseudoTerminal.monotonicMilliseconds() - last < quiet {
            while session.takeDelta() != nil { last = PseudoTerminal.monotonicMilliseconds() }
            _ = updates.wait(timeout: .now() + .milliseconds(50))
        }
    }
}

private func contains(_ delta: ScreenDelta, _ text: String) -> Bool {
    delta.changedRows.contains { row in
        String(decoding: row.cells.map { UInt8(truncatingIfNeeded: $0.scalar) }, as: UTF8.self).contains(text)
    }
}

@Suite("Session", .timeLimit(.minutes(1)))
struct SessionTests {
    @Test("a shell runs what is typed and the app sees the output")
    func runsCommands() throws {
        let h = try Harness()
        #expect(h.waitUntil { $0.mirror.generation != nil })
        h.type("echo $((900+99))\n")
        #expect(h.waitUntil { $0.text.contains("999") })
    }

    @Test("text comes from the session, history included, for the generation it was asked for")
    func textFromTheSession() async throws {
        let h = try Harness(columns: 40, rows: 4)
        h.type("for i in 1 2 3 4 5 6 7 8; do echo line$i; done\n")
        #expect(h.waitUntil { $0.text.contains("line8") })
        let generation = try #require(h.mirror.generation)
        let everything = TextRegion(
            TextPoint(line: 0, column: 0), TextPoint(line: h.mirror.viewportTopLine + 3, column: 39))
        let text = await h.session.text(in: everything, generation: generation)
        #expect(text?.contains("line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8") == true)
        #expect(h.mirror.text(in: everything) == nil)
        #expect(await h.session.text(in: everything, generation: generation &+ 1) == nil)
    }

    @Test("at its prompt the shell is the foreground process")
    func foregroundIsTheShell() async throws {
        let h = try Harness()
        #expect(h.waitUntil { $0.mirror.generation != nil })
        let process = await h.session.foregroundProcess()
        #expect(process?.isShell == true)
        #expect(process?.name.isEmpty == false)
    }

    @Test("questions to a session that has ended are answered at once, with nil")
    func questionsAfterTheEnd() async throws {
        let h = try Harness()
        h.type("exit\n")
        #expect(
            h.waitUntil { harness in
                if case .exited = harness.session.status { return true }
                return false
            })
        #expect(await h.session.foregroundProcess() == nil)
        let range = TextRegion(TextPoint(line: 0, column: 0), TextPoint(line: 0, column: 9))
        #expect(await h.session.text(in: range, generation: h.mirror.generation ?? 0) == nil)
    }

    @Test("a new base palette reaches the mirror")
    func basePalette() throws {
        let h = try Harness()
        #expect(h.waitUntil { $0.mirror.generation != nil })
        h.session.setBasePalette(.xterm)
        #expect(h.waitUntil { $0.mirror.palette == .xterm })
    }

    @Test("a resize reaches the engine, the mirror and the program")
    func resizes() throws {
        let h = try Harness()
        h.session.resize(columns: 50, rows: 10)
        #expect(h.waitUntil { $0.mirror.columns == 50 && $0.mirror.rows == 10 })
        h.type("stty size\n")
        #expect(h.waitUntil { $0.text.contains("10 50") })
    }

    @Test("the shell's exit status is reported")
    func reportsExit() throws {
        let h = try Harness()
        h.type("exit 7\n")
        #expect(h.waitUntil { $0.session.status != .running })
        #expect(h.session.status == .exited(.exited(code: 7)))
        // Nobody is left to read input, so it is refused.
        #expect(!h.session.send([0x0A]))
    }

    @Test("closing hangs up on the shell")
    func closes() throws {
        let h = try Harness()
        #expect(h.waitUntil { $0.mirror.generation != nil })
        h.session.close()
        #expect(h.waitUntil { $0.session.status != .running })
    }

    @Test("an exit is noticed even while a background job holds the terminal")
    func exitWithBackgroundJob() throws {
        let h = try Harness(arguments: ["sh", "-c", "sleep 30 & exit 3"])
        #expect(h.waitUntil(timeout: 10_000) { $0.session.status != .running })
        #expect(h.session.status == .exited(.exited(code: 3)))
    }

    @Test("a snapshot request recovers a mirror that missed deltas")
    func snapshotAfterDroppedDeltas() throws {
        let h = try Harness()
        #expect(h.waitUntil { $0.text.contains("$") })
        h.type("echo MARKER-ONE\n")
        #expect(h.dropDeltas { contains($0, "MARKER-ONE") })
        // The last delta dropped is the last one taken: the session has nothing newer.
        h.dropDeltas(quietFor: 300)
        // The mirror never saw the marker; only a real snapshot can bring it back.
        h.session.requestSnapshot()
        #expect(h.waitUntil { $0.text.contains("MARKER-ONE") })
    }

    @Test("a mirror that missed a delta refuses the next one, and recovers")
    func refusedDeltaRecovers() throws {
        let h = try Harness()
        #expect(h.waitUntil { $0.text.contains("$") })
        h.type("echo MARKER-TWO\n")
        #expect(h.dropDeltas { contains($0, "MARKER-TWO") })
        // The next delta builds on the dropped one: the harness's mirror refuses it and asks for
        // a snapshot, as the app does.
        h.type("echo next\n")
        #expect(h.waitUntil { $0.text.contains("MARKER-TWO") && $0.text.contains("next") })
    }

    @Test("a job that outlives the shell and floods the terminal does not keep the session alive")
    func floodAfterExit() throws {
        let h = try Harness(arguments: ["sh", "-c", "trap '' HUP; yes flood & sleep 0.3; exit 3"])
        #expect(h.waitUntil(timeout: 10_000) { $0.session.status != .running })
        #expect(h.session.status == .exited(.exited(code: 3)))
    }

    @Test("a password prompt reaches the app, and ends")
    func passwordPrompt() throws {
        let h = try Harness()
        #expect(h.waitUntil { $0.text.contains("$") })
        #expect(!h.mirror.readingPassword)
        // Like getpass and readpassphrase: echo off, then the prompt, then a line. The session
        // checks the terminal's mode when output arrives, so the prompt is what reveals it.
        h.type("stty -echo; printf 'Password: '; read secret; stty echo\n")
        #expect(h.waitUntil { $0.mirror.readingPassword })
        h.type("hunter2\n")
        #expect(h.waitUntil { !$0.mirror.readingPassword })
        #expect(!h.text.contains("hunter2"))
    }

    @Test("typing returns a scrolled-back view to the bottom")
    func typingScrollsToBottom() throws {
        let h = try Harness(rows: 4)
        h.type("i=0; while [ $i -lt 20 ]; do echo line$i; i=$((i+1)); done\n")
        #expect(h.waitUntil { $0.text.contains("line19") && $0.mirror.scrollbackCount > 10 })
        h.session.scroll(by: 5)
        #expect(h.waitUntil { $0.mirror.viewportOffset == 5 })
        h.type(" ")
        #expect(h.waitUntil { $0.mirror.viewportOffset == 0 })
    }

    @Test("reports leave a scrolled-back view where it is")
    func reportsDoNotScroll() throws {
        let h = try Harness(rows: 4)
        h.type("i=0; while [ $i -lt 20 ]; do echo line$i; i=$((i+1)); done\n")
        #expect(h.waitUntil { $0.text.contains("line19") && $0.mirror.scrollbackCount > 10 })
        h.session.scroll(by: 5)
        #expect(h.waitUntil { $0.mirror.viewportOffset == 5 })
        // A focus report (mode 1004), as switching apps sends it; then a scroll, which the
        // session handles after the report, proves the report was taken.
        #expect(h.session.sendReport(Array("\u{1B}[O".utf8)))
        h.session.scroll(by: 1)
        #expect(h.waitUntil { $0.mirror.viewportOffset == 6 })
    }

    @Test("synchronized output holds the frame, but not forever")
    func synchronizedOutput() throws {
        let h = try Harness()
        #expect(h.waitUntil { $0.text.contains("$") })
        // The echoed command contains "HELD" too; the program's output is a line of its own.
        let printed: (Harness) -> Bool = { $0.text.split(separator: "\n").contains("HELD") }
        h.type("printf '\\033[?2026hHELD'; sleep 3\n")
        // The program turned synchronized output on and never off: its frame is held...
        #expect(!h.waitUntil(timeout: 400, printed))
        // ...until the one-second watchdog lets it through.
        #expect(h.waitUntil(timeout: 3_000, printed))
    }

    @Test("input past the limit is refused instead of queued")
    func inputLimit() throws {
        let h = try Harness()
        #expect(!h.session.send([UInt8](repeating: 0x61, count: SessionChannel.inputLimit + 1)))
        #expect(h.session.send([0x0A]))
    }

    @Test("many sessions run side by side")
    func manySessions() throws {
        let harnesses = try (0..<6).map { _ in try Harness() }
        for (i, h) in harnesses.enumerated() { h.type("echo session$((\(i)*111))\n") }
        for (i, h) in harnesses.enumerated() {
            #expect(h.waitUntil { $0.text.contains("session\(i * 111)") })
        }
    }

    @Test("bell, title and other events reach the app")
    func events() throws {
        let h = try Harness()
        h.type("printf '\\033]2;Legends\\007\\007'\n")
        #expect(h.waitUntil { $0.mirror.title == "Legends" && $0.events.contains(.bell) })
    }
}

@Suite("A session nobody is watching", .timeLimit(.minutes(1)))
struct DetachedSessionTests {
    /// The point of turning publishing off: the program runs on, and its output is still read
    /// and fed to the engine, but no screen is built for a client that is not there.
    @Test("publishing off stops the deltas and not the shell")
    func publishingOff() throws {
        let h = try Harness()
        h.type("echo one\n")
        #expect(h.waitUntil { $0.text.contains("one") })

        h.session.setPublishing(false)
        h.dropDeltas(quietFor: 200)
        h.type("echo two\n")
        #expect(!h.deltaArrives(within: 500), "a delta was built for nobody")

        h.session.setPublishing(true)
        #expect(h.waitUntil { $0.text.contains("two") }, "what it printed while away was kept")
    }

    /// What the daemon does when someone takes a session up: publishing back on, and a
    /// whole screen asked for, because the client holding the last one is gone. The snapshot
    /// has to carry what was printed while nobody was watching.
    @Test("a client taking the session up gets a whole screen, with what it missed on it")
    func takingItUp() throws {
        let h = try Harness()
        #expect(h.waitUntil { $0.mirror.generation != nil })
        h.session.setPublishing(false)
        h.dropDeltas(quietFor: 200)
        h.type("echo three\n")

        h.session.setPublishing(true)
        h.session.requestSnapshot()
        h.mirror = MirrorGrid()
        #expect(h.waitUntil { $0.text.contains("three") })
    }

    /// Publishing back on for the *same* client needs no snapshot: it still holds what it
    /// last took, so a delta built on that is right, and cheaper than a screen.
    @Test("coming back to the same client builds on what it already has")
    func sameClient() throws {
        let h = try Harness()
        h.type("echo five\n")
        #expect(h.waitUntil { $0.text.contains("five") })
        h.session.setPublishing(false)
        h.dropDeltas(quietFor: 200)
        h.type("echo six\n")
        h.session.setPublishing(true)
        // The mirror is kept, and must accept what comes without ever asking for a snapshot.
        #expect(h.waitUntil { $0.text.contains("five") && $0.text.contains("six") })
    }

    /// However long nobody was watching, how the shell ended still has to reach whoever
    /// takes the session up next — that is what lets a relaunched app say so.
    @Test("the last screen and the exit arrive even with publishing off")
    func theEndAlwaysArrives() throws {
        let h = try Harness()
        #expect(h.waitUntil { $0.mirror.generation != nil })
        h.session.setPublishing(false)
        h.dropDeltas(quietFor: 200)
        h.type("exit 3\n")
        #expect(h.waitUntil { $0.session.status != .running })
        #expect(h.session.status == .exited(.exited(code: 3)))
    }

    @Test("turning it off twice, or on when it already is, changes nothing")
    func idempotent() throws {
        let h = try Harness()
        #expect(h.waitUntil { $0.mirror.generation != nil })
        h.session.setPublishing(true)
        h.session.setPublishing(false)
        h.session.setPublishing(false)
        h.dropDeltas(quietFor: 200)
        h.type("echo four\n")
        #expect(!h.deltaArrives(within: 400))
        h.session.setPublishing(true)
        #expect(h.waitUntil { $0.text.contains("four") })
    }
}

@Suite("Sessions in this process", .timeLimit(.minutes(1)))
struct InProcessHostTests {
    private func shell() -> ShellLaunch {
        ShellLaunch(
            executable: "/bin/sh", arguments: ["sh"],
            environment: ShellLaunch.terminalEnvironment(
                inheriting: ["PATH": "/usr/bin:/bin"], appVersion: "test"))
    }

    @Test("it says plainly that its sessions do not outlive the process")
    func itDoesNotSurvive() {
        #expect(!InProcessHost().sessionsSurviveQuit)
    }

    @Test("there is never anything from before, and nothing to take up")
    func nothingToFind() throws {
        let host = InProcessHost()
        #expect(try host.existing().isEmpty)
        #expect(throws: SessionHostError.unknownSession(SessionID(7))) {
            _ = try host.adopt(SessionID(7), onUpdate: {})
        }
    }

    @Test("it starts a shell, and each one has its own id")
    func itStartsShells() throws {
        let host = InProcessHost()
        let first = try host.start(shell(), configuration: Terminal.Configuration(), metadata: [], onUpdate: {})
        let second = try host.start(shell(), configuration: Terminal.Configuration(), metadata: [], onUpdate: {})
        #expect(first.id != second.id)
        first.close()
        second.close()
    }

    /// There is nowhere in this process to leave a shell running, so `detach` ends it. The
    /// method exists so the app has to choose, not because the choice matters here.
    @Test("detaching ends a session that has nowhere to be left")
    func detachEndsIt() throws {
        let host = InProcessHost()
        let session = try host.start(shell(), configuration: Terminal.Configuration(), metadata: [], onUpdate: {})
        session.detach()
        let deadline = PseudoTerminal.monotonicMilliseconds() + 5_000
        while session.status == .running, PseudoTerminal.monotonicMilliseconds() < deadline {
            _ = session.takeDelta()
        }
        #expect(session.status != .running)
    }

    /// A note of where a session belonged is only worth keeping if the session will outlive
    /// the window; here neither does, so both calls are nothing, and must not fail.
    @Test("remembering where a session belonged, and ending one, are no-ops")
    func theNoOps() {
        let host = InProcessHost()
        host.setMetadata(Array("anything".utf8), for: SessionID(1))
        host.end(SessionID(1))
    }

    /// A shell that is not there is not a failure to start: the fork succeeds and `execve`
    /// fails in the child, which exits 127 the way a shell says "command not found". So this
    /// arrives as a session that ends, not as a throw — which is how the app reports it, and
    /// what a daemon will have to report too.
    @Test("a shell that is not there becomes a session that exits 127")
    func aShellThatIsNotThere() throws {
        let host = InProcessHost()
        let missing = ShellLaunch(executable: "/nonexistent/shell", arguments: ["shell"], environment: [:])
        let session = try host.start(
            missing, configuration: Terminal.Configuration(), metadata: [], onUpdate: {})
        let deadline = PseudoTerminal.monotonicMilliseconds() + 5_000
        while session.status == .running, PseudoTerminal.monotonicMilliseconds() < deadline {
            _ = session.takeDelta()
        }
        #expect(session.status == .exited(.exited(code: 127)))
    }
}
