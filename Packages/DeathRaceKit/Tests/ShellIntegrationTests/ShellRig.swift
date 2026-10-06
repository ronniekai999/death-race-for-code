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
/// `DEATHRACE_REQUIRE_SHELLS` is the other half: with it set, a *missing* shell fails instead
/// of quietly skipping, the way `DEATHRACE_REQUIRE_SSH` does for ssh.
enum TestShells {
    static let environment = ProcessInfo.processInfo.environment
    static let isWanted = !(environment["DEATHRACE_SHELLS"] ?? "").isEmpty
    static let isRequired = environment["DEATHRACE_REQUIRE_SHELLS"] == "1"
    static var shouldRun: Bool { isWanted || isRequired }

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

    /// Deliberately not a login shell and with no `-i`: a login shell would read /etc files
    /// this test knows nothing about, and `-i` with `-c` runs no prompt loop at all, so none
    /// of the hooks would ever fire. The pseudo-terminal is what makes it interactive.
    init(shell: ShellIntegration.Shell, executable: String, rc: String, columns: Int = 80, rows: Int = 24) throws {
        home = NSTemporaryDirectory() + "shl-" + String(UInt32.random(in: .min ... .max), radix: 16)
        let manager = FileManager.default
        try manager.createDirectory(atPath: home, withIntermediateDirectories: true)

        switch shell {
        case .zsh:
            try rc.write(toFile: home + "/.zshrc", atomically: true, encoding: .utf8)
        case .bash:
            try rc.write(toFile: home + "/.bashrc", atomically: true, encoding: .utf8)
        case .fish:
            try manager.createDirectory(atPath: home + "/.config/fish", withIntermediateDirectories: true)
            try rc.write(toFile: home + "/.config/fish/config.fish", atomically: true, encoding: .utf8)
        }

        var environment = [
            "HOME": home, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "SHELL": executable,
        ]
        environment = ShellIntegration.adding(
            to: environment, shell: shell, directory: ShellIntegration.directory(environment: environment))

        let name = executable.split(separator: "/").last.map(String.init) ?? "sh"
        let launch = ShellLaunch(executable: executable, arguments: [name], environment: environment)
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
        return SmokeTest.readUntil(
            terminal, contains: Array(marker.utf8), into: &transcript, timeoutMilliseconds: limit)
    }

    /// Waits for the shell to be ready: the first prompt's own `OSC 133;A`. Without this a
    /// command typed into a shell that has not finished sourcing is simply lost.
    func waitForFirstPrompt(withinMilliseconds limit: Int = 5_000) -> Bool {
        SmokeTest.readUntil(
            terminal, contains: Array("\u{1B}]133;A".utf8), into: &transcript, timeoutMilliseconds: limit)
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
