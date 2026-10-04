import ConfigKit
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
        appVersion: String, isExecutable: (String) -> Bool = { access($0, X_OK) == 0 }
    ) -> ShellLaunch {
        let home = environment["HOME"] ?? "/"
        var launch = ShellLaunch.loginShell(inheriting: environment, appVersion: appVersion)
        if let words = config.commandArguments,
            let program = resolve(words[0], path: environment["PATH"], isExecutable: isExecutable)
        {
            launch.executable = program
            launch.arguments = words
        }
        switch config.workingDirectory {
        case .inherit: launch.workingDirectory = directory ?? home
        case .home: launch.workingDirectory = home
        case .path(let path): launch.workingDirectory = expandingTilde(path, home: home)
        }
        return launch
    }

    /// The program's path: as given when it has a slash, else the first on PATH.
    public static func resolve(
        _ program: String, path: String?, isExecutable: (String) -> Bool = { access($0, X_OK) == 0 }
    ) -> String? {
        if program.contains("/") { return isExecutable(program) ? program : nil }
        let directories = (path ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin").split(separator: ":")
        for directory in directories {
            let candidate = "\(directory)/\(program)"
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    static func expandingTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return (home.hasSuffix("/") ? String(home.dropLast()) : home) + path.dropFirst() }
        return path
    }
}
