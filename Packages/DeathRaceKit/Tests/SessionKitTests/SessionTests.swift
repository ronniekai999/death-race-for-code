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
        let everything = TextRange(
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
        let range = TextRange(TextPoint(line: 0, column: 0), TextPoint(line: 0, column: 9))
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
