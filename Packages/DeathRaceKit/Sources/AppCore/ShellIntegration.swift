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
    /// bash is absent on purpose — it is reached by a line in your own startup file
    /// (`bashFileNeedingLine`), so there is nothing to put in the environment for it.
    public static func adding(
        to environment: [String: String], shell: Shell?, directory: URL?
    ) -> [String: String] {
        guard let shell, let directory else { return environment }
        var environment = environment
        switch shell {
        case .zsh:
            // Our folder becomes ZDOTDIR so our files run; the old value rides along so each of
            // them can put it back before sourcing yours, which is what stops a zsh started from
            // this one reading our files instead of yours.
            //
            // Assigning nil *removes* the key, and that is the point: a shell with no ZDOTDIR is
            // not the same as one pointing at $HOME, even though zsh reads the same files for
            // both. The scripts restore the absence, so nothing of ours is left in a nested
            // shell's environment — including a stale value a parent app run left behind.
            environment["DEATHRACE_USER_ZDOTDIR"] = environment["ZDOTDIR"]
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

    /// The startup file a bash this app starts will actually read, which is where the offer to
    /// add our line has to point.
    ///
    /// A pane runs a *login* shell — `ShellLaunch.loginShell` passes `-bash` as argv[0] — and a
    /// login bash reads the first of `~/.bash_profile`, `~/.bash_login` and `~/.profile` that
    /// exists, and never `~/.bashrc`. So a line written to `~/.bashrc`, which is what this
    /// offered at first, is read by nothing we start. That is not a corner case on a Mac:
    /// Terminal.app and iTerm2 start login shells too, which is exactly why a Mac bash user's
    /// settings are in `.bash_profile` to begin with.
    ///
    /// When the file that does run already pulls in `~/.bashrc` — the usual convention, and
    /// what most Linux distributions ship — the line goes in `~/.bashrc` after all, so that it
    /// also reaches the non-login interactive shells other things start. When none of the three
    /// exists, bash reads none of them, so the first is named and creating it loses nothing.
    public static func bashProfile(
        home: String,
        contentsOfFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> String {
        let candidates = [home + "/.bash_profile", home + "/.bash_login", home + "/.profile"]
        for path in candidates {
            guard let contents = contentsOfFile(path) else { continue }
            return sourcesBashrc(contents) ? home + "/.bashrc" : path
        }
        return candidates[0]
    }

    /// Whether a startup file already pulls in `~/.bashrc`, in any of the spellings people use
    /// for it (`. ~/.bashrc`, `source "$HOME/.bashrc"`, inside an `if [ -f … ]`).
    static func sourcesBashrc(_ contents: String) -> Bool {
        contents.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            return !trimmed.hasPrefix("#") && trimmed.contains(".bashrc")
        }
    }

    /// The one line bash needs in that file, shown to you before anything is written.
    ///
    /// Single-quoted, not double: inside double quotes a `$`, a backtick or a `\` in the path
    /// would be expanded by the very shell that is meant to read the path literally. A quote in
    /// the path itself is spelled the only way a single-quoted string can spell one.
    public static func bashLine(directory: URL) -> String {
        let quoted = singleQuoted(directory.appendingPathComponent("bash/deathrace.bash").path)
        return "[ -r \(quoted) ] && . \(quoted)   # Death Race for Code"
    }

    static func singleQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether a startup file already loads our script, so the offer is not made twice and the
    /// line is never added again. Matched on the script's path rather than on the whole line,
    /// so a hand-edited or reformatted version still counts as installed — with the one
    /// spelling single quoting forces, `'\''`, read back as the quote it stands for.
    public static func isInstalled(in contents: String, directory: URL) -> Bool {
        let path = directory.appendingPathComponent("bash/deathrace.bash").path
        return contents.split(whereSeparator: \.isNewline)
            .contains { line in
                let trimmed = line.drop { $0 == " " || $0 == "\t" }
                return !trimmed.hasPrefix("#")
                    && trimmed.replacingOccurrences(of: "'\\''", with: "'").contains(path)
            }
    }

    /// The file to offer our line for, when `executable` is bash and none of the files a bash
    /// reads at startup loads our script yet; nil for another shell, or one already set up.
    ///
    /// Every one of them is looked in, not only the file the offer would name: a line you put
    /// in `~/.bash_profile` yourself still counts once that file pulls in `~/.bashrc`, which is
    /// when the offer would have pointed at `~/.bashrc` instead.
    public static func bashFileNeedingLine(
        executable: String, home: String, directory: URL,
        contentsOfFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> String? {
        guard shell(ofExecutable: executable) == .bash else { return nil }
        let startupFiles = [".bash_profile", ".bash_login", ".profile", ".bashrc"].map { home + "/" + $0 }
        let installed = startupFiles.contains { path in
            contentsOfFile(path).map { isInstalled(in: $0, directory: directory) } ?? false
        }
        return installed ? nil : bashProfile(home: home, contentsOfFile: contentsOfFile)
    }

    /// Adds `bashLine` to the end of `path`, after a line break if the file doesn't end in one,
    /// creating the file when there is none.
    ///
    /// Appended through the file rather than written out anew: a startup file kept in a dotfiles
    /// repository is often a symlink, and replacing it would cut the link, and with it the
    /// file's permissions and owner.
    public static func addBashLine(to path: String, directory: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: path) {
            guard manager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644]) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path])
            }
        }
        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var text = ""
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data("\n".utf8) { text += "\n" }
            try handle.seekToEnd()
        }
        text += bashLine(directory: directory) + "\n"
        try handle.write(contentsOf: Data(text.utf8))
    }
}
