import Foundation

/// The branch a directory's repository has checked out, for the status bar and pane
/// headers. It reads `.git/HEAD` and runs no `git` process, so it is cheap enough to ask on
/// every directory change.
public enum GitHead {
    /// What the file system holds at a path.
    public enum Entry: Sendable { case directory, file, missing }

    /// How GitHead reads the disk; tests pass their own.
    public struct FileSystem: Sendable {
        public var entry: @Sendable (String) -> Entry
        public var contents: @Sendable (String) -> String?

        public init(entry: @escaping @Sendable (String) -> Entry, contents: @escaping @Sendable (String) -> String?) {
            self.entry = entry
            self.contents = contents
        }

        public static let local = FileSystem(
            entry: { path in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
                return isDirectory.boolValue ? .directory : .file
            },
            contents: { path in
                FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
            })
    }

    /// The branch checked out in the repository holding `directory`, or the first seven
    /// characters of the commit when HEAD is detached; nil outside a repository. A `.git`
    /// file (a worktree or a submodule) is followed to its `gitdir:`.
    public static func branch(at directory: String, in fileSystem: FileSystem = .local) -> String? {
        var current = normalized(directory)
        while true {
            let dotGit = current == "/" ? "/.git" : current + "/.git"
            switch fileSystem.entry(dotGit) {
            case .directory:
                return fileSystem.contents(dotGit + "/HEAD").flatMap(describe)
            case .file:
                guard let gitDirectory = fileSystem.contents(dotGit).flatMap({ gitDir(in: $0, relativeTo: current) })
                else { return nil }
                return fileSystem.contents(gitDirectory + "/HEAD").flatMap(describe)
            case .missing:
                guard current != "/" else { return nil }
                current = parent(of: current)
            }
        }
    }

    /// What a HEAD file names: `ref: refs/heads/feature/x` is `feature/x`; a bare commit
    /// is its first seven characters.
    static func describe(_ head: String) -> String? {
        let text = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("ref:") {
            let ref = text.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            return branch.isEmpty ? nil : branch
        }
        guard text.count >= 7, text.allSatisfy(\.isHexDigit) else { return nil }
        return String(text.prefix(7))
    }

    /// The directory a `.git` file points to: `gitdir: ../.git/worktrees/x`.
    static func gitDir(in file: String, relativeTo directory: String) -> String? {
        guard let line = file.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return normalized(path.hasPrefix("/") ? path : directory + "/" + path)
    }

    /// An absolute path without `.`, `..`, doubled or trailing slashes.
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }
}
