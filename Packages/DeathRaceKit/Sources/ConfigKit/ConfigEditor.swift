/// Changes one setting in a settings file's text, leaving every other line as it was:
/// comments, blank lines, order and line endings. Settings writes through it, so the file
/// stays the one place settings live, and stays the person's own.
public enum ConfigEditor {
    /// `text` with setting `name` set to `value`, or commented out when `value` is nil (so
    /// it goes back to its default).
    ///
    /// The value replaces the last line that sets it, since the last line wins. Without one,
    /// a new line goes right after the template's commented-out line for the setting, then
    /// at the end of its section, then at the end of the file. For `palette`, which repeats,
    /// "a line that sets it" means one for the same color number.
    public static func set(_ name: String, to value: String?, in text: String) -> String {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let endsWithNewline = text.isEmpty || text.hasSuffix("\n")
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if endsWithNewline, lines.last == "" { lines.removeLast() }

        let wanted = paletteIndex(name: name, value: value)
        let active = lines.indices.filter { index in
            guard let (key, existing) = activeSetting(lines[index]), key == name else { return false }
            return wanted == nil || paletteIndex(name: name, value: existing) == wanted
        }

        guard let value else {
            for index in active { lines[index] = "# " + lines[index] }
            return joined(lines, newline: newline, endsWithNewline: endsWithNewline)
        }
        let line = "\(name) = \(quoted(value))"
        if let last = active.last {
            let indent = lines[last].prefix { $0 == " " || $0 == "\t" }
            lines[last] = indent + line
        } else if let commented = lines.lastIndex(where: { isCommentedSetting($0, name: name) }) {
            lines.insert(line, at: commented + 1)
        } else if let section = ConfigSchema.key(named: name)?.section,
            let header = lines.firstIndex(where: { $0.trimmingSpaces == "# ---- \(section.rawValue) ----" })
        {
            var end = lines[(header + 1)...].firstIndex { $0.trimmingSpaces.hasPrefix("# ---- ") } ?? lines.endIndex
            while end > header + 1, lines[end - 1].trimmingSpaces.isEmpty { end -= 1 }
            lines.insert(line, at: end)
        } else {
            if let last = lines.last, !last.trimmingSpaces.isEmpty { lines.append("") }
            lines.append(line)
        }
        return joined(lines, newline: newline, endsWithNewline: endsWithNewline)
    }

    /// The name and value a line sets, if it is a setting rather than a comment.
    static func activeSetting(_ line: String) -> (name: Substring, value: Substring)? {
        let trimmed = line.trimmingSpaces
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
        return (trimmed[..<equals].trimmingSpaces, trimmed[trimmed.index(after: equals)...].trimmingSpaces)
    }

    /// The template's `# name = …` line for a setting.
    static func isCommentedSetting(_ line: String, name: String) -> Bool {
        let trimmed = line.trimmingSpaces
        guard trimmed.hasPrefix("#") else { return false }
        guard let (key, _) = activeSetting(String(trimmed.dropFirst())) else { return false }
        return key == name
    }

    /// For `palette`, the color number a value sets.
    private static func paletteIndex(name: String, value: (some StringProtocol)?) -> Int? {
        guard name == "palette", let value, let equals = value.firstIndex(of: "=") else { return nil }
        return Int(value[..<equals].trimmingSpaces)
    }

    /// Values with spaces at either end keep them in double quotes, as the parser expects,
    /// and so do values already in double quotes (a command whose path has spaces), which
    /// the parser would otherwise take as quoting and strip. A line break cannot be stored,
    /// so it becomes a space.
    static func quoted(_ value: String) -> String {
        let flat = String(value.map { $0.isNewline ? " " : $0 })
        guard let first = flat.first, let last = flat.last else { return flat }
        let edgeSpace = first == " " || first == "\t" || last == " " || last == "\t"
        let inQuotes = flat.count >= 2 && first == "\"" && last == "\""
        return edgeSpace || inQuotes ? "\"\(flat)\"" : flat
    }

    private static func joined(_ lines: [String], newline: String, endsWithNewline: Bool) -> String {
        let body = lines.joined(separator: newline)
        return endsWithNewline && !lines.isEmpty ? body + newline : body
    }
}

extension ConfigKey {
    /// The value `config` holds for this setting, as the file would spell it; nil for
    /// settings whose default is no value.
    public func value(in config: Config) -> String? {
        write(config)
    }
}
