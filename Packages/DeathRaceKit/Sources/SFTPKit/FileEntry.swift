/// One row in a Maze pane — a file, directory or symlink on either side (the local Mac or the
/// remote host). Pure and portable, so the listing and sorting are tested on Linux.
public struct FileEntry: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case file
        case directory
        case symlink
    }

    public var name: String
    public var kind: Kind
    public var size: UInt64
    /// Last-modified time, Unix seconds, when known.
    public var modified: UInt32?

    public init(name: String, kind: Kind, size: UInt64 = 0, modified: UInt32? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
    }

    public var id: String { name }
    public var isDirectory: Bool { kind == .directory }
}

/// Turning raw directory contents into the sorted rows a pane shows.
public enum Listing {
    /// A file's kind from its attributes: a symlink first (it may point at a directory), then a
    /// directory, else a plain file.
    public static func kind(of attributes: SFTPAttributes) -> FileEntry.Kind {
        if attributes.isSymlink { return .symlink }
        if attributes.isDirectory { return .directory }
        return .file
    }

    /// The longest name a real filesystem will give us (`NAME_MAX`). Anything longer is a
    /// server making something up.
    public static let longestName = 255

    /// Whether a name a server sent may be used as a file on this Mac. **A server chooses
    /// every byte of this**, and Maze joins it with a local folder and writes there, so it is
    /// only ever a name — never a path:
    ///
    /// - A name holding `/` is refused. `Listing.join` would otherwise take
    ///   `Library/LaunchAgents/x.plist` straight out of the folder on screen, and the write
    ///   goes through `AtomicFile`, which creates the folders on the way. From the default
    ///   Downloads folder that reaches a launch agent, `~/.zshrc` or `~/.ssh/config` — content
    ///   and path both chosen by a host you merely browsed.
    /// - `.`, `..` and the empty name are refused, so a name can't climb either.
    /// - A name holding a control character is refused: it would lie on screen.
    /// - A name that didn't survive its UTF-8 decode (so it holds U+FFFD) is refused, because
    ///   the path we would send back in `OPEN` is no longer the bytes the server listed, and
    ///   two different files can collapse into one row.
    ///
    /// This is the same stance OpenSSH's own sftp and scp took after CVE-2019-6111: the local
    /// path comes from what we asked for, never from what the server answered.
    public static func isUsableName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= longestName else { return false }
        return !name.unicodeScalars.contains {
            $0 == "/" || $0 == "\u{FFFD}" || $0.properties.generalCategory == .control
        }
    }

    /// Display rows for a remote directory, from the server's raw `NAME` entries: drop
    /// anything that isn't a usable name (see `isUsableName`), classify each, and sort.
    /// Duplicates are dropped too — `FileEntry`'s identity is its name, and `ForEach` must
    /// not see the same id twice.
    public static func remote(_ names: [SFTPName]) -> [FileEntry] {
        var seen: Set<String> = []
        let entries =
            names
            .filter { isUsableName($0.filename) && seen.insert($0.filename).inserted }
            .map {
                FileEntry(
                    name: $0.filename, kind: kind(of: $0.attributes),
                    size: $0.attributes.size ?? 0, modified: $0.attributes.modified)
            }
        return sorted(entries)
    }

    /// Directories first, then by name without regard to case — the order both panes show.
    public static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.lowercased() < rhs.name.lowercased()
        }
    }

    /// The parent of an absolute POSIX path, for stepping up a directory. `/` is its own parent.
    public static func parent(of path: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard trimmed != "/", let slash = trimmed.lastIndex(of: "/") else { return "/" }
        let head = String(trimmed[..<slash])
        return head.isEmpty ? "/" : head
    }

    /// The last component of a path — a dropped file's name, for the row it becomes. `/` is
    /// its own name, as it is its own parent.
    public static func name(of path: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard trimmed != "/", let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    /// Join a directory and a child name into an absolute POSIX path.
    public static func join(_ directory: String, _ name: String) -> String {
        if directory == "/" { return "/" + name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// A file's size with its unit, for a pane's trailing column. Every number gets a unit, as
    /// NAMING asks; a directory shows nothing.
    public static func sizeText(_ bytes: UInt64) -> String {
        if bytes < 1_024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes) / 1_024
        var unit = 0
        while value >= 1_024, unit + 1 < units.count {
            value /= 1_024
            unit += 1
        }
        // One decimal below 10 (4.2 MB), none above (42 MB).
        let rounded = value < 10 ? (value * 10).rounded() / 10 : value.rounded()
        let text = value < 10 ? String(format: "%.1f", rounded) : String(format: "%.0f", rounded)
        return text + " " + units[unit]
    }
}
