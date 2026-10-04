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
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            let key = line[..<equals].trimmingWhitespace
            let value = Self.unquote(String(line[line.index(after: equals)...]).trimmingWhitespace)
            switch key {
            case "NAME": name = Self.clean(value)
            case "VERSION_ID": versionID = Self.clean(value)
            case "PRETTY_NAME": prettyName = Self.clean(value)
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

    /// A value fit to show. A host's `/etc/os-release` is read over the connection and is
    /// untrusted: a corrupt or hostile one could otherwise send control characters or an absurd
    /// length straight into the card's line and its VoiceOver label. Drop C0, C1 and DEL (the
    /// rule `SSHValue.isPath` uses) and cap the length; a real name or version is far shorter.
    static func clean(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(
            contentsOf: value.unicodeScalars.filter {
                $0.value >= 0x20 && $0.value != 0x7F && !(0x80...0x9F).contains($0.value)
            })
        return String(String(scalars).prefix(64))
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
