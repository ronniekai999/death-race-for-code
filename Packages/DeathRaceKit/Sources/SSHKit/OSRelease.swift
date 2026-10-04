/// What a host's `/etc/os-release` says, for the card's "Ubuntu 24.04".
public struct OSRelease: Equatable, Sendable {
    public var name: String?
    public var versionID: String?
    public var prettyName: String?

    public init(name: String? = nil, versionID: String? = nil, prettyName: String? = nil) {
        self.name = name
        self.versionID = versionID
        self.prettyName = prettyName
    }

    /// The file's `KEY=value` lines; values may be quoted, with backslash escapes.
    public init(parsing text: String) {
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            let key = line[..<equals].trimmingWhitespace
            let value = Self.unquote(String(line[line.index(after: equals)...]).trimmingWhitespace)
            switch key {
            case "NAME": name = value
            case "VERSION_ID": versionID = value
            case "PRETTY_NAME": prettyName = value
            default: break
            }
        }
    }

    /// "Ubuntu 24.04", "Debian 13", "Fedora Linux 42"; nil when the file says nothing useful.
    public var display: String? {
        if var name, !name.isEmpty {
            if name.hasSuffix(" GNU/Linux") { name.removeLast(" GNU/Linux".count) }
            if let versionID, !versionID.isEmpty { return "\(name) \(versionID)" }
            return name
        }
        return prettyName.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func unquote(_ value: String) -> String {
        guard let quote = value.first, quote == "\"" || quote == "'", value.count >= 2, value.last == quote else {
            return value
        }
        var result = ""
        var escaped = false
        for character in value.dropFirst().dropLast() {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" && quote == "\"" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}

extension StringProtocol {
    var trimmingWhitespace: String {
        let isSpace: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\r" }
        guard let first = firstIndex(where: { !isSpace($0) }), let last = lastIndex(where: { !isSpace($0) }) else {
            return ""
        }
        return String(self[first...last])
    }
}
