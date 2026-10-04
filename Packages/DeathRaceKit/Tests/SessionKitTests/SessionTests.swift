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
