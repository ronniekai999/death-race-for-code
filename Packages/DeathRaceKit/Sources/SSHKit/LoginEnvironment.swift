import Foundation

/// Your login shell's `PATH` and `SSH_AUTH_SOCK`, read once for the ssh the app starts.
///
/// An app opened from the Dock gets launchd's environment, not your shell's. Without these,
/// a `ProxyCommand` tool in /opt/homebrew/bin wouldn't be found, and an agent your shell
/// startup files set up (1Password's, say) wouldn't be used: ssh would behave differently
/// than in Terminal.
public enum LoginEnvironment {
    /// What is taken from the shell; nothing else changes.
    public static let keys = ["PATH", "SSH_AUTH_SOCK"]
    /// A shell that takes longer than this to start gets ignored.
    public static let timeout = 5_000

    /// `shell -l -i -c`, printing the environment between two markers. Only external
    /// commands with plain arguments, so zsh, bash, fish and nu all run it as written.
    static func command(shell: String, marker: String) -> [String] {
        let fence = "/usr/bin/printf '\\n%s\\n' \(marker)"
        return [shell, "-l", "-i", "-c", "\(fence); /usr/bin/env; \(fence)"]
    }

    /// The `keys` from `env`'s output between the markers. Startup files can print anything
    /// before or after; values set to nothing don't count.
    static func parse(_ output: String, marker: String) -> [String: String] {
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard let first = lines.firstIndex(of: marker),
            let last = lines.lastIndex(of: marker), last > first
        else { return [:] }
        var found: [String: String] = [:]
        for line in lines[(first + 1)..<last] {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            let value = String(line[line.index(after: equals)...])
            if keys.contains(key), !value.isEmpty { found[key] = value }
        }
        return found
    }

    /// Runs `shell` as a login shell and returns what it sets of `keys`; empty if it fails,
    /// prints nothing usable, or takes too long.
    public static func read(
        shell: String, environment: [String: String], runner: any ProcessRunner = SystemProcessRunner(),
        timeoutMilliseconds: Int = timeout
    ) async -> [String: String] {
        let marker = "deathrace-env-" + String(AskpassWire.makeToken().prefix(16))
        var started = environment
        // Nothing in the startup files should take this for a terminal it can draw on.
        started["TERM"] = "dumb"
        let command = Command(
            command(shell: shell, marker: marker), environment: started,
            workingDirectory: environment["HOME"], timeoutMilliseconds: timeoutMilliseconds)
        guard let result = try? await runner.run(command), !result.timedOut else { return [:] }
        return parse(result.outputText, marker: marker)
    }

    /// `base` with the login shell's values on top.
    public static func merging(_ login: [String: String], into base: [String: String]) -> [String: String] {
        base.merging(login) { _, login in login }
    }
}

/// What every ssh the app starts gets, on top of its environment: `deathrace-askpass`, used
/// even without a display (`force`), and how it reaches the app's broker.
public enum AskpassEnvironment {
    public static func adding(
        helper: String, socket: String, token: String, to environment: [String: String]
    ) -> [String: String] {
        var environment = environment
        environment["SSH_ASKPASS"] = helper
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DEATHRACE_ASKPASS_SOCKET"] = socket
        environment["DEATHRACE_ASKPASS_TOKEN"] = token
        return environment
    }
}
