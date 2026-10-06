import AppCore
import ConfigKit
import Foundation
import PTYKit
import Testing
import VTCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The shells this machine has, and whether the suite is wanted at all.
///
/// Presence of `DEATHRACE_SHELLS`, not presence of the shells — and that distinction is the
/// point. The Thread Sanitizer re-run in `linux.yml` passes no environment, but by then CI has
/// installed zsh and fish, so a gate of "run whenever the shell exists" would put real shells
/// in pseudo-terminals into the sanitizer pass: slow, prone to timing out on four cores, and
/// telling us nothing, since the shells are separate processes TSan cannot see into.
///
/// There is no second `DEATHRACE_REQUIRE_SHELLS` switch to go with it, as there is for ssh:
/// once the suite is asked for, each test `#require`s its shell's path, and a failed `#require`
/// *fails* the test rather than skipping it. A missing shell on a run that asked for shells is
/// already an error, so a switch to say so again would only look like it did something.
enum TestShells {
    static let environment = ProcessInfo.processInfo.environment
    static var shouldRun: Bool { !(environment["DEATHRACE_SHELLS"] ?? "").isEmpty }

    static let searchPath = ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"]

    static func path(_ name: String) -> String? {
        searchPath.map { $0 + "/" + name }.first { access($0, X_OK) == 0 }
    }

    static func missing(_ name: String) -> Comment {
        "no \(name) on this machine; looked in \(searchPath.joined(separator: ", "))"
    }
}

/// One shell, running under our integration in a pseudo-terminal, with everything it printed
/// fed through the engine.
///
/// Each rig gets a HOME of its own holding the rc files the test wants, so nothing real is
/// read or written and the zsh hand-off can be checked against a known starting point. Built
/// at runtime rather than as a SwiftPM resource: no test target in this package declares
/// `resources:`, and a temporary HOME is what makes the hand-off observable anyway.
/// Not actor-isolated: it holds a `PseudoTerminal`, which is not `Sendable`, so the rig cannot
/// cross isolation in any case — and an isolated class has a nonisolated `deinit`, which then
/// could not hang the terminal up.
final class ShellRig {
    let home: String
    private let terminal: PseudoTerminal
    private let engine: Terminal
    private var transcript: [UInt8] = []
    /// How much of `transcript` the engine has already seen, so it is never fed twice.
    private var fed = 0

    /// `rc` is the shell's own rc file — `.zshrc`, `.bashrc`, `config.fish` — and `files` is
    /// anything else the test wants in its HOME, keyed by path relative to it.
    ///
    /// `login` is off by default and with no `-i`: a login shell also reads /etc files this
    /// test knows nothing about, and `-i` with `-c` runs no prompt loop at all, so none of the
    /// hooks would ever fire. The pseudo-terminal is what makes it interactive. The app *does*
    /// start a login shell, though, which is a different startup sequence in both zsh and bash
    /// — so the tests that are about that sequence ask for it, and say why.
    init(
        shell: ShellIntegration.Shell, executable: String, rc: String, files: [String: String] = [:],
        login: Bool = false, environment extra: [String: String] = [:], columns: Int = 80, rows: Int = 24
    ) throws {
        home = NSTemporaryDirectory() + "shl-" + String(UInt32.random(in: .min ... .max), radix: 16)
        let manager = FileManager.default
        try manager.createDirectory(atPath: home, withIntermediateDirectories: true)

        var written = files
        switch shell {
        case .zsh: written[".zshrc"] = rc
        case .bash: written[".bashrc"] = rc
        case .fish: written[".config/fish/config.fish"] = rc
        }
        for (relative, contents) in written {
            let path = home + "/" + relative
            try manager.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try contents.write(toFile: path, atomically: true, encoding: .utf8)
        }

        var environment = [
            "HOME": home, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "SHELL": executable,
        ]
        environment.merge(extra) { _, extra in extra }
        environment = ShellIntegration.adding(
            to: environment, shell: shell, directory: ShellIntegration.directory(environment: environment))

        // argv[0] with a leading dash is how every shell is told it is a login shell, and it is
        // what `ShellLaunch.loginShell` does, so this is the app's own launch rather than a
        // test-only approximation of it.
        let name = executable.split(separator: "/").last.map(String.init) ?? "sh"
        let launch = ShellLaunch(
            executable: executable, arguments: [login ? "-" + name : name], environment: environment)
        terminal = try PseudoTerminal.spawn(
            launch, size: TerminalSize(rows: UInt16(rows), columns: UInt16(columns)))
        engine = Terminal(Terminal.Configuration(columns: columns, rows: rows))
    }

    deinit { terminal.hangUp() }

    /// The real end-of-command mark, with its escape byte.
    ///
    /// Tests wait for this rather than the text `133;D`, because a shell echoes what you type:
    /// waiting for the plain text matched the echo of the command itself and returned before
    /// the command had run — and for a command that deliberately prints something mark-shaped,
    /// it matched that too.
    static let commandEnd = "\u{1B}]133;D"
    static let promptStart = "\u{1B}]133;A"

    /// Types `line` and waits for `marker` to come back, so each step is bounded and the test
    /// never races the shell's own startup.
    @discardableResult
    func run(_ line: String, awaiting marker: String, withinMilliseconds limit: Int = 5_000) -> Bool {
        terminal.writeAll(line + "\n")
        return read(until: marker, withinMilliseconds: limit)
    }

    /// Types a line and then reads for a fixed while, for the cases where the point is that
    /// *nothing* should come back — an empty line must produce no record at all, and waiting
    /// for a mark that should never arrive is the only way to find out that it did not.
    func typeAndSettle(_ line: String, milliseconds: Int = 500) {
        terminal.writeAll(line + "\n")
        _ = read(until: "\u{0}deathrace-never", withinMilliseconds: milliseconds)
    }

    /// Waits for the shell to be ready: the first prompt's own `OSC 133;A`. Without this a
    /// command typed into a shell that has not finished sourcing is simply lost.
    func waitForFirstPrompt(withinMilliseconds limit: Int = 5_000) -> Bool {
        read(until: ShellRig.promptStart, withinMilliseconds: limit)
    }

    /// Reads into a buffer of its own and appends that afterwards, so each wait sees only what
    /// arrived *during* it.
    ///
    /// Reading straight into the transcript would mean every wait searched the whole session
    /// so far, and a second `run` waiting for the end-of-command mark would return at once on
    /// the *first* command's — before the second had printed anything. Every test here that
    /// types more than one line depends on this.
    private func read(until marker: String, withinMilliseconds limit: Int) -> Bool {
        var fresh: [UInt8] = []
        let found = SmokeTest.readUntil(
            terminal, contains: Array(marker.utf8), into: &fresh, timeoutMilliseconds: limit)
        transcript.append(contentsOf: fresh)
        return found
    }

    /// Everything the shell printed, run through the engine. The whole point of the pairing:
    /// the bytes alone would pass even if the script and the parser disagreed on escaping.
    ///
    /// Only the bytes not fed yet, so this can be called as often as a test likes. Feeding the
    /// whole transcript each time replayed the session on top of itself and moved every mark,
    /// which is how a real screen behaves and not what any assertion here means.
    func screen() -> Terminal {
        if fed < transcript.count {
            engine.feed(Array(transcript[fed...]))
            fed = transcript.count
        }
        return engine
    }

    /// The command records the engine built, in the order their rows appear — the scrollback
    /// first, since a short screen pushes earlier commands off it.
    func commands() -> [CommandRecord] {
        let terminal = screen()
        var found: [CommandRecord] = []
        for index in 0..<terminal.scrollbackCount {
            if let command = terminal.scrollbackRow(index).command { found.append(command) }
        }
        for index in 0..<terminal.rows {
            if let command = terminal.row(index).command { found.append(command) }
        }
        return found
    }

    /// The raw bytes, for the few assertions that are about the wire rather than the engine.
    var raw: String { String(decoding: transcript, as: UTF8.self) }
}
