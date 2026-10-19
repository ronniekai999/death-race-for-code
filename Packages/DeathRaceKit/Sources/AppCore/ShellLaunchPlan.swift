import ConfigKit
import Foundation
import PTYKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// What a new pane runs and where.
public enum ShellLaunchPlan {
    /// `command` from the settings, or the user's login shell, in `directory` (the current
    /// pane's, with `working-directory = inherit`) or the configured one.
    public static func launch(
        config: Config, directory: String?, environment: [String: String] = ShellLaunch.processEnvironment(),
        appVersion: String, isExecutable: (String) -> Bool = { access($0, X_OK) == 0 },
        integration: URL? = ShellIntegration.directory()
    ) -> ShellLaunch {
        let home = environment["HOME"] ?? "/"
        var launch = ShellLaunch.loginShell(inheriting: environment, appVersion: appVersion)
        if let words = config.commandArguments,
            let program = resolve(words[0], path: environment["PATH"], home: home, isExecutable: isExecutable)
        {
            launch.executable = program
            // As a shell would start it: `~` already your home folder.
            launch.arguments = [expandingTilde(words[0], home: home)] + words.dropFirst()
        }
        switch config.workingDirectory {
        case .inherit: launch.workingDirectory = directory ?? home
        case .home: launch.workingDirectory = home
        case .path(let path): launch.workingDirectory = expandingTilde(path, home: home)
        }
        // Here, because this is the one place the app decides what a pane runs — and because
        // a `ShellLaunch` is what crosses to `legendsd`, so a session the daemon holds gets
        // the integration for free rather than needing a second path through the wire.
        // Keyed on the executable that will actually run, which `command` may have replaced.
        if config.shellIntegration {
            launch.environment = ShellIntegration.adding(
                to: launch.environment, shell: ShellIntegration.shell(ofExecutable: launch.executable),
                directory: integration)
        }
        return launch
    }

    /// ssh in a pane: `arguments` as SSHKit writes them (`/usr/bin/ssh` first, so ProxyJump
    /// hops run the same ssh), with the terminal's environment and your login shell's PATH
    /// and SSH_AUTH_SOCK on top, in your home folder.
    public static func ssh(
        arguments: [String], login: [String: String],
        environment: [String: String] = ShellLaunch.processEnvironment(), appVersion: String
    ) -> ShellLaunch {
        var terminal = ShellLaunch.terminalEnvironment(inheriting: environment, appVersion: appVersion)
        terminal.merge(login) { _, login in login }
        return ShellLaunch(
            executable: arguments.first ?? "/usr/bin/ssh", arguments: arguments, environment: terminal,
            workingDirectory: environment["HOME"])
    }

    /// Why a new pane doesn't run what the `command` setting says, in a sentence: nothing by
    /// that name could be found, so it runs your login shell. Nil when it runs it, or there's
    /// no setting.
    public static func commandProblem(
        config: Config, environment: [String: String] = ShellLaunch.processEnvironment(),
        isExecutable: (String) -> Bool = { access($0, X_OK) == 0 }
    ) -> String? {
        guard let program = config.commandArguments?.first,
            resolve(program, path: environment["PATH"], home: environment["HOME"] ?? "/", isExecutable: isExecutable)
                == nil
        else { return nil }
        return "Death Race couldn’t find “\(program)”, the program Run names in Settings, so this is your login shell."
    }

    /// The program's path: as given when it has a slash (with `~` for `home`), else the first
    /// on PATH, then where programs are usually installed.
    public static func resolve(
        _ program: String, path: String?, home: String = "/",
        isExecutable: (String) -> Bool = { access($0, X_OK) == 0 }
    ) -> String? {
        if program.contains("/") {
            let path = expandingTilde(program, home: home)
            return isExecutable(path) ? path : nil
        }
        let directories = (path ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for directory in directories + usualPlaces(home: home) {
            let candidate = "\(directory)/\(program)"
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// Where programs are installed that an app's PATH doesn't reach: opened from the Finder,
    /// it's only `/usr/bin:/bin:/usr/sbin:/sbin`. Homebrew, MacPorts, Nix, and your own.
    static func usualPlaces(home: String) -> [String] {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        return [
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", home + "/.nix-profile/bin",
            "/run/current-system/sw/bin", "/nix/var/nix/profiles/default/bin", home + "/.local/bin",
            home + "/.cargo/bin",
        ]
    }

    static func expandingTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return (home.hasSuffix("/") ? String(home.dropLast()) : home) + path.dropFirst() }
        return path
    }
}
