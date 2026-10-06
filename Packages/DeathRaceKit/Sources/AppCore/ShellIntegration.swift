import Foundation

/// Where the shell integration scripts are, and what a session's environment needs so a shell
/// loads them.
///
/// The scripts report what the terminal cannot know: where a prompt starts and ends, the text
/// of the command, how long it ran and how it ended. Two of the three shells are reached
/// without writing to any file of yours; bash is asked, because the ways to reach it without
/// asking both change what its startup means.
///
/// Nothing here runs a shell or reads a script. It shapes an environment, which is why it is
/// portable and testable, and why it lives beside `ShellLaunchPlan` rather than in PTYKit —
/// which has no business knowing where an app keeps its resources.
public enum ShellIntegration {

    /// The shells we have a script for. Anything else gets a session with no integration and
    /// no complaint: marks are a convenience, not a condition of opening a terminal.
    public enum Shell: String, CaseIterable, Sendable {
        case zsh
        case bash
        case fish
    }

    /// Which shell an executable is, by the name it actually runs under.
    ///
    /// The resolved path, never `$SHELL`: `ShellLaunchPlan.launch` replaces argv wholesale
    /// when `command` is set, so a configured `/opt/homebrew/bin/fish` has to be recognised
    /// while `$SHELL` still says zsh. A version suffix is allowed for the same reason —
    /// `bash-5.2` is bash.
    public static func shell(ofExecutable path: String) -> Shell? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let base = name.split(separator: "-").first.map(String.init) ?? name
        return Shell(rawValue: base)
    }

    /// Where the scripts are: `Contents/Resources/shell-integration` in the app, or
    /// `App/shell-integration` for a run from the repository.
    /// `DEATHRACE_SHELL_INTEGRATION` overrides both.
    ///
    /// The three tiers and their order are `FontRegistry.directory`'s, deliberately: a missing
    /// folder is nil and a session simply opens without marks, exactly as a missing font file
    /// is not an error.
    public static func directory(
        bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        if let path = environment["DEATHRACE_SHELL_INTEGRATION"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if let resources = bundle.resourceURL?.appendingPathComponent("shell-integration", isDirectory: true),
            fileExists(resources.path)
        {
            return resources
        }
        // Sources/AppCore/ShellIntegration.swift in Packages/DeathRaceKit: five levels up is
        // the repository, the same walk FontRegistry makes from the same depth. (In the body,
        // #filePath is this file; as a default argument it would be the caller's.)
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let committed = repository.appendingPathComponent("App/shell-integration", isDirectory: true)
        return fileExists(committed.path) ? committed : nil
    }

    /// What `XDG_DATA_DIRS` means when nobody has set it, from the XDG base directory spec.
    /// Prepending ours to an empty value would otherwise *replace* the default and hide
    /// fish's own vendor files, which is a worse bug than having no integration.
    static let defaultDataDirectories = "/usr/local/share:/usr/share"

    /// The environment a session needs for `shell` to load its script, on top of what it
    /// already has. `AskpassEnvironment.adding`'s shape: take a dictionary, return it with
    /// what is needed added.
    ///
    /// bash is absent on purpose — it is reached by a line in your own `~/.bashrc`, so there
    /// is nothing to put in the environment for it.
    public static func adding(
        to environment: [String: String], shell: Shell?, directory: URL?
    ) -> [String: String] {
        guard let shell, let directory else { return environment }
        var environment = environment
        switch shell {
        case .zsh:
            // Our folder becomes ZDOTDIR so our .zshrc runs; the old value rides along so our
            // .zshrc can put it back before anything else, which is what stops a zsh started
            // from this one reading our files instead of yours.
            environment["DEATHRACE_USER_ZDOTDIR"] = environment["ZDOTDIR"] ?? environment["HOME"] ?? ""
            environment["ZDOTDIR"] = directory.appendingPathComponent("zsh", isDirectory: true).path
        case .fish:
            // fish reads vendor_conf.d from each entry of XDG_DATA_DIRS.
            let ours = directory.appendingPathComponent("fish", isDirectory: true).path
            let existing = environment["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultDataDirectories
            environment["XDG_DATA_DIRS"] =
                existing.split(separator: ":").contains(Substring(ours))
                ? existing : ours + ":" + existing
        case .bash:
            break
        }
        return environment
    }

    /// The one line bash needs in `~/.bashrc`, shown to you before anything is written.
    public static func bashLine(directory: URL) -> String {
        let path = directory.appendingPathComponent("bash/deathrace.bash").path
        return "[ -r \"\(path)\" ] && . \"\(path)\"   # Death Race for Code"
    }

    /// Whether a `~/.bashrc` already loads our script, so the offer is not made twice and the
    /// line is never added again. Matched on the script's path rather than the whole line, so
    /// a hand-edited or reformatted version still counts as installed.
    public static func isInstalled(inBashrc contents: String, directory: URL) -> Bool {
        let path = directory.appendingPathComponent("bash/deathrace.bash").path
        return contents.split(whereSeparator: \.isNewline)
            .contains { line in
                let trimmed = line.drop { $0 == " " || $0 == "\t" }
                return !trimmed.hasPrefix("#") && trimmed.contains(path)
            }
    }
}
