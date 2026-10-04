/// Something in the settings file that could not be used. The setting keeps its default.
public struct ConfigDiagnostic: Sendable, Equatable, CustomStringConvertible {
    /// 1-based.
    public var line: Int
    public var message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }

    public var description: String { "Line \(line): \(message)" }
}

/// Reads settings files: `name = value` lines, in the style of Ghostty's.
///
/// - A line whose first non-blank character is `#` is a comment; so is a blank line. A `#`
///   later in a line is part of the value, as colors need.
/// - Spaces around the name and the value are ignored, and a value may be put in double
///   quotes to keep spaces at its ends.
/// - The last line for a setting wins, except for settings that repeat (`palette`).
/// - A line that cannot be used is reported and skipped; it never stops the rest.
public enum ConfigParser {
    public static func parse(_ text: String, into config: inout Config) -> [ConfigDiagnostic] {
        var diagnostics: [ConfigDiagnostic] = []
        // "\r\n" is one Character, so lines split on any newline rather than on "\n".
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let number = index + 1
            let line = rawLine.trimmingSpaces
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equals = line.firstIndex(of: "=") else {
                diagnostics.append(ConfigDiagnostic(line: number, message: "Write settings as name = value."))
                continue
            }
            let name = line[..<equals].trimmingSpaces
            var value = line[line.index(after: equals)...].trimmingSpaces
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = value.dropFirst().dropLast()
            }
            guard let key = ConfigSchema.key(named: name) else {
                var message = "There is no setting called “\(name)”."
                if let suggestion = suggestion(for: name) { message += " Did you mean “\(suggestion)”?" }
                diagnostics.append(ConfigDiagnostic(line: number, message: message))
                continue
            }
            guard !value.isEmpty else {
                diagnostics.append(ConfigDiagnostic(line: number, message: "“\(key.name)” needs a value."))
                continue
            }
            do throws(ConfigValueError) {
                try key.read(value, &config)
            } catch {
                diagnostics.append(
                    ConfigDiagnostic(
                        line: number, message: "“\(value)” does not work for \(key.name). \(error.message)"))
            }
        }
        return diagnostics
    }

    /// The setting `name` was probably meant to be: the closest by edit distance, if close
    /// enough to be a typo.
    static func suggestion(for name: Substring) -> String? {
        let lowered = name.lowercased()
        var best: (name: String, distance: Int)?
        for key in ConfigSchema.keys {
            let distance = editDistance(lowered, key.name)
            if distance < best?.distance ?? Int.max { best = (key.name, distance) }
        }
        guard let best, best.distance <= max(2, best.name.count / 4) else { return nil }
        return best.name
    }

    /// Levenshtein distance over characters.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

/// Where the settings file lives: `$XDG_CONFIG_HOME/deathrace/config`, or
/// `~/.config/deathrace/config` when that variable is unset or not an absolute path.
public enum ConfigLocation {
    public static func path(environment: [String: String], home: String) -> String {
        if let base = environment["XDG_CONFIG_HOME"], base.hasPrefix("/") {
            return trimmingTrailingSlashes(base) + "/deathrace/config"
        }
        return trimmingTrailingSlashes(home) + "/.config/deathrace/config"
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var path = Substring(path)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path == "/" ? "" : String(path)
    }
}

/// Splitting a command line into words the way a shell would, without expanding anything.
public enum ShellWords {
    /// Whitespace separates words; single quotes keep everything literally; double quotes
    /// keep spaces, with `\"` and `\\` inside them; a backslash outside quotes keeps the next
    /// character. An unfinished quote runs to the end.
    public static func split(_ text: String) -> [String] {
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        /// A backslash outside quotes: the next character is literal.
        var escaped = false
        /// A backslash inside double quotes: it escapes only `"` and `\`.
        var quotedBackslash = false
        for character in text {
            if escaped {
                word.append(character)
                escaped = false
                continue
            }
            switch quote {
            case "'":
                if character == "'" { quote = nil } else { word.append(character) }
            case "\"":
                if quotedBackslash {
                    if character != "\"" && character != "\\" { word.append("\\") }
                    word.append(character)
                    quotedBackslash = false
                } else if character == "\"" {
                    quote = nil
                } else if character == "\\" {
                    quotedBackslash = true
                } else {
                    word.append(character)
                }
            default:
                if character == " " || character == "\t" || character == "\n" {
                    if inWord { words.append(word) }
                    word = ""
                    inWord = false
                } else {
                    inWord = true
                    if character == "'" || character == "\"" {
                        quote = character
                    } else if character == "\\" {
                        escaped = true
                    } else {
                        word.append(character)
                    }
                }
            }
        }
        if quotedBackslash || escaped { word.append("\\") }
        if inWord { words.append(word) }
        return words
    }
}
