import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// What to run in a new terminal and with which environment.
public struct ShellLaunch: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String? = nil)
    {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    /// The user's login shell, started as a login shell ("-zsh"), in their home directory.
    public static func loginShell(
        inheriting base: [String: String] = ShellLaunch.processEnvironment(),
        appVersion: String = "0.1.0"
    ) -> ShellLaunch {
        let shell = userShell(environment: base)
        let name = shell.split(separator: "/").last.map(String.init) ?? "sh"
        return ShellLaunch(
            executable: shell,
            arguments: ["-" + name],
            environment: terminalEnvironment(inheriting: base, appVersion: appVersion),
            workingDirectory: base["HOME"]
        )
    }

    /// The environment a program sees inside Death Race.
    ///
    /// TERM stays `xterm-256color`: a custom TERM breaks every SSH host without its terminfo.
    /// Capabilities beyond xterm are advertised the modern way: COLORTERM for truecolor and
    /// replies to XTGETTCAP / XTVERSION queries.
    public static func terminalEnvironment(inheriting base: [String: String], appVersion: String) -> [String: String] {
        var env = base
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "DeathRace"
        env["TERM_PROGRAM_VERSION"] = appVersion
        if env["LANG"] == nil && env["LC_ALL"] == nil && env["LC_CTYPE"] == nil {
            env["LANG"] = "en_US.UTF-8"
        }
        // Variables that only make sense for the parent process.
        for key in ["TERM_SESSION_ID", "ITERM_SESSION_ID", "GHOSTTY_RESOURCES_DIR", "XPC_SERVICE_NAME"] {
            env.removeValue(forKey: key)
        }
        return env
    }

    /// $SHELL if it names an executable, else the password database, else /bin/zsh
    /// (macOS) or /bin/sh.
    public static func userShell(environment: [String: String]) -> String {
        if let shell = environment["SHELL"], !shell.isEmpty, access(shell, X_OK) == 0 {
            return shell
        }
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let shell = String(cString: raw)
            if !shell.isEmpty, access(shell, X_OK) == 0 { return shell }
        }
        #if os(macOS)
            return "/bin/zsh"
        #else
            return "/bin/sh"
        #endif
    }

    public static func processEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment
    }
}

extension PseudoTerminal {
    public static func spawn(_ launch: ShellLaunch, size: TerminalSize) throws -> PseudoTerminal {
        try spawn(
            executable: launch.executable,
            arguments: launch.arguments,
            environment: launch.environment,
            workingDirectory: launch.workingDirectory,
            size: size
        )
    }
}
