import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Finding the hosts named in `~/.ssh/config`, for WRLD's "Found 12 hosts" and Hear Me
/// Calling, without running anything.
///
/// The lines are read the way ssh reads them (`Keyword value`, `Keyword=value`, double
/// quotes, a `#` that starts a word ends the line), following `Include` the way ssh does.
/// Only concrete names count as hosts: no wildcards, no negations. What a name resolves to
/// in full is ssh's job (`ssh -G`, `EffectiveConfig`); the details here are what the name's
/// own `Host` blocks say, for display.
public enum SSHConfigDiscovery {
    public struct Alias: Equatable, Sendable {
        public var name: String
        public var hostName: String?
        public var user: String?
        public var port: Int?
        public var proxyJump: String?
        /// The file and line of the first `Host` line naming it.
        public var file: String
        public var line: Int

        public init(
            name: String, hostName: String? = nil, user: String? = nil, port: Int? = nil, proxyJump: String? = nil,
            file: String, line: Int
        ) {
            self.name = name
            self.hostName = hostName
            self.user = user
            self.port = port
            self.proxyJump = proxyJump
            self.file = file
            self.line = line
        }
    }

    /// Reading files and expanding `Include`'s patterns; replaced in tests.
    public struct FileSystem: Sendable {
        public var contents: @Sendable (String) -> String?
        public var glob: @Sendable (String) -> [String]

        public init(contents: @escaping @Sendable (String) -> String?, glob: @escaping @Sendable (String) -> [String]) {
            self.contents = contents
            self.glob = glob
        }

        public static let local = FileSystem(
            contents: { path in
                guard let data = FileManager.default.contents(atPath: path) else { return nil }
                return String(decoding: data, as: UTF8.self)
            },
            glob: { pattern in globPaths(pattern) })
    }

    /// ssh stops following `Include` this deep (`READCONF_MAX_DEPTH`).
    static let deepestInclude = 16

    /// Every concrete host name in the file at `path` and what it includes, in the order ssh
    /// would meet them; a name repeated later adds details it hadn't had.
    public static func aliases(inFileAt path: String, home: String, fileSystem: FileSystem = .local) -> [Alias] {
        var found: [Alias] = []
        var index: [String: Int] = [:]
        read(path, home: home, fileSystem: fileSystem, depth: 0, found: &found, index: &index)
        return found
    }

    private static func read(
        _ path: String, home: String, fileSystem: FileSystem, depth: Int, found: inout [Alias],
        index: inout [String: Int]
    ) {
        guard depth <= deepestInclude, let text = fileSystem.contents(path) else { return }
        // The names the current block's details belong to: a `Host` line's concrete names,
        // or none inside `Match` and wildcard-only blocks.
        var current: [String] = []
        // A file saved with \r\n line ends reads the same: ssh strips the \r too.
        for (number, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let words = tokenize(line)
            guard let keyword = words.first?.lowercased() else { continue }
            let arguments = Array(words.dropFirst())
            switch keyword {
            case "host":
                current = arguments.filter(isConcrete)
                for name in current where index[name] == nil {
                    index[name] = found.count
                    found.append(Alias(name: name, file: path, line: number + 1))
                }
            case "match":
                current = []
            case "include":
                for pattern in arguments {
                    let expanded = expand(pattern, home: home)
                    for file in fileSystem.glob(expanded).sorted() {
                        read(file, home: home, fileSystem: fileSystem, depth: depth + 1, found: &found, index: &index)
                    }
                }
            default:
                guard let value = arguments.first else { continue }
                for name in current {
                    guard let position = index[name] else { continue }
                    // First value wins, as in ssh.
                    switch keyword {
                    case "hostname" where found[position].hostName == nil: found[position].hostName = value
                    case "user" where found[position].user == nil: found[position].user = value
                    case "port" where found[position].port == nil: found[position].port = Int(value)
                    case "proxyjump" where found[position].proxyJump == nil: found[position].proxyJump = value
                    default: break
                    }
                }
            }
        }
    }

    /// A name that stands for one host: no `*` or `?` patterns, no `!` negation.
    static func isConcrete(_ pattern: String) -> Bool {
        !pattern.isEmpty && !pattern.contains(where: { $0 == "*" || $0 == "?" || $0 == "!" })
    }

    /// `Include`'s paths: `~` is the home folder, and a relative path is under `~/.ssh`.
    static func expand(_ pattern: String, home: String) -> String {
        if pattern == "~" { return home }
        if pattern.hasPrefix("~/") { return home + pattern.dropFirst() }
        if pattern.hasPrefix("/") { return pattern }
        return home + "/.ssh/" + pattern
    }

    /// A config line as ssh splits it (`argv_split`): the keyword, which one `=` may separate
    /// from its arguments, and the arguments, with single or double quotes grouping words
    /// and a backslash keeping the quote, backslash or space after it. A word that starts
    /// with `#` ends the line.
    public static func tokenize<S: StringProtocol>(_ line: S) -> [String] {
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        var equalsAllowed = true
        func finish() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        for character in line {
            if escaped {
                escaped = false
                // Only quotes, backslashes and (unquoted) spaces are escapes; before anything
                // else the backslash stays.
                let special =
                    character == "'" || character == "\"" || character == "\\" || (quote == nil && character == " ")
                if !special { word.append("\\") }
                word.append(character)
                inWord = true
                continue
            }
            if character == "\\" {
                escaped = true
                inWord = true
                continue
            }
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    word.append(character)
                }
                continue
            }
            switch character {
            case " ", "\t", "\r":
                finish()
            case "=" where equalsAllowed && (words.isEmpty ? inWord : words.count == 1 && !inWord):
                finish()
                equalsAllowed = false
            case "\"", "'":
                inWord = true
                quote = character
            case "#" where !inWord:
                finish()
                return words
            default:
                word.append(character)
                inWord = true
            }
            if words.count >= 2 { equalsAllowed = false }
        }
        if escaped { word.append("\\") }
        finish()
        return words
    }
}

/// The paths a shell pattern matches, sorted; the pattern itself if it has no wildcard.
func globPaths(_ pattern: String) -> [String] {
    var result = glob_t()
    defer { globfree(&result) }
    guard glob(pattern, 0, nil, &result) == 0 else { return [] }
    var paths: [String] = []
    for index in 0..<Int(result.gl_pathc) {
        if let path = result.gl_pathv[index] { paths.append(String(cString: path)) }
    }
    return paths
}
