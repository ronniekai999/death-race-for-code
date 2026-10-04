/// What a ⌘-click on a link does. A link's text is the program's to choose, so the target
/// is what decides, and some targets are never opened at all.
public enum LinkAction: Equatable, Sendable {
    /// http, https and mailto: handed to the app that opens them.
    case open(String)
    /// A file on this Mac: shown in Finder, never opened, since opening an app or a script
    /// runs it.
    case reveal(path: String)
    /// Any other scheme (ssh:, vscode:, x-man-page:…) asks first, naming the app it would
    /// open.
    case confirm(scheme: String)
    case refuse(LinkRefusal)
}

public enum LinkRefusal: Equatable, Sendable {
    /// Not a URL, or one with spaces or control characters in it.
    case malformed
    /// Longer than any browser takes.
    case tooLong
    /// javascript: and data: can only cause trouble when handed to a browser.
    case script
    /// file:// on another computer: there is nothing here to show.
    case otherComputer(host: String)
}

public enum LinkPolicy {
    /// Browsers stop at about this many characters; OSC 8 links longer than it are ignored
    /// when they arrive.
    public static let maxLength = 2083

    public static func action(for uri: String, localHostNames: Set<String>) -> LinkAction {
        guard uri.utf8.count <= maxLength else { return .refuse(.tooLong) }
        guard !uri.unicodeScalars.contains(where: { $0.value < 0x21 || (0x7F...0x9F).contains($0.value) }) else {
            return .refuse(.malformed)
        }
        guard let scheme = scheme(of: uri) else { return .refuse(.malformed) }
        switch scheme {
        case "http", "https":
            return uri.dropFirst(scheme.count + 1).hasPrefix("//") && host(of: uri) != nil
                ? .open(uri) : .refuse(.malformed)
        case "mailto":
            return uri.count > "mailto:".count ? .open(uri) : .refuse(.malformed)
        case "file":
            if let path = WorkingDirectoryURL.path(from: "file" + uri.dropFirst(4), localHostNames: localHostNames) {
                return .reveal(path: path)
            }
            if let host = host(of: uri), !host.isEmpty { return .refuse(.otherComputer(host: host)) }
            return .refuse(.malformed)
        case "javascript", "data", "vbscript":
            return .refuse(.script)
        default:
            return .confirm(scheme: scheme)
        }
    }

    /// True when the link's visible text names a site and the link goes to another one,
    /// as in a phishing link: the text says apple.com, the link opens evil.example. Such a
    /// link asks before it opens, whatever its scheme.
    public static func misleads(text: String, target: String) -> Bool {
        guard let shownHost = namedHost(in: text) else { return false }
        guard let targetHost = host(of: target) else { return true }
        return comparable(shownHost) != comparable(targetHost)
    }

    /// The site a link's text names, as a reader takes it. Characters that do not show (a
    /// zero-width space inside "apple.com") are dropped; dots and letters that only look like
    /// ASCII ones (U+2024, full-width letters) count as them; and the punctuation of the
    /// sentence around it, a user name, a port and a path are not the site.
    static func namedHost(in text: String) -> String? {
        var folded = ""
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .format { continue }
            if lookalikeDots.contains(scalar.value) {
                folded.append(".")
            } else if (0xFF01...0xFF5E).contains(scalar.value), let ascii = Unicode.Scalar(scalar.value - 0xFEE0) {
                folded.unicodeScalars.append(ascii)
            } else {
                folded.unicodeScalars.append(scalar)
            }
        }
        func edge(_ character: Character) -> Bool { character.isWhitespace || "\"'()[]<>{}.,;:!?`".contains(character) }
        let core = String(Substring(folded).drop(while: edge).reversed().drop(while: edge).reversed())
        if let named = host(of: core) { return named }
        return bareHost(Substring(core))
    }

    /// Dots that read as a full stop in an address.
    static let lookalikeDots: Set<UInt32> = [
        0x00B7, 0x2024, 0x2027, 0x2219, 0x22C5, 0x3002, 0x30FB, 0xFE52, 0xFF0E, 0xFF61,
    ]

    /// A URI as it is safe to show, in the status bar or a question.
    /// - Characters that are invisible, separate lines or reorder text are percent-encoded:
    ///   U+202E can make `example.com/gpj.exe` read as `example.com/exe.jpg`.
    /// - The scheme and host always show: past `limit` the path gives way, a long user
    ///   name before an `@` shows as "…", and a very long host keeps its end, which is the
    ///   site.
    public static func shown(_ uri: String, limit: Int = 200) -> String {
        guard let start = uri.firstRange(of: "://")?.upperBound else { return escaped(uri[...], limit: limit) }
        let rest = uri[start...]
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        var host = rest[..<authorityEnd]
        var head = escaped(uri[..<start], limit: .max)
        if let at = host.lastIndex(of: "@") {
            let user = host[...at]
            head += user.count > 24 ? "…@" : escaped(user, limit: .max)
            host = host[host.index(after: at)...]
        }
        let site = escaped(host, limit: .max)
        head += site.count > 64 ? String(site.prefix(16)) + "…" + String(site.suffix(44)) : site
        return head + escaped(rest[authorityEnd...], limit: max(limit - head.count, 16))
    }

    /// A link's text as it is safe to show in a question: characters that are invisible or
    /// reorder text are spelled out (⟨U+202E⟩), and long text ends in "…".
    public static func visibleText(_ text: String, limit: Int = 120) -> String {
        var out = ""
        for (count, scalar) in text.unicodeScalars.enumerated() {
            guard count < limit else {
                out += "…"
                break
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .unassigned, .privateUse, .surrogate:
                out += spelledOut(scalar)
            case .spaceSeparator where scalar.value != 0x20:
                out += spelledOut(scalar)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func spelledOut(_ scalar: Unicode.Scalar) -> String {
        let digits = String(scalar.value, radix: 16, uppercase: true)
        return "⟨U+" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits + "⟩"
    }

    /// `text` with invisible, line-breaking and reordering characters percent-encoded, cut
    /// at `limit` characters with "…".
    private static func escaped(_ text: Substring, limit: Int) -> String {
        let hex = Array("0123456789ABCDEF")
        var out = ""
        for (count, scalar) in text.unicodeScalars.enumerated() {
            guard count < limit else {
                out += "…"
                break
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator, .unassigned, .privateUse,
                .surrogate:
                for byte in String(scalar).utf8 {
                    out.append("%")
                    out.append(hex[Int(byte >> 4)])
                    out.append(hex[Int(byte & 0xF)])
                }
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// The scheme, lowercased: letters, then letters, digits, + . or -, then a colon.
    static func scheme(of uri: String) -> String? {
        guard let colon = uri.firstIndex(of: ":") else { return nil }
        let scheme = uri[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
            scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) })
        else { return nil }
        return scheme.lowercased()
    }

    /// The host of `scheme://user@host:port/…`, lowercased; nil without `//`.
    static func host(of uri: String) -> String? {
        guard let start = uri.firstRange(of: "://")?.upperBound else { return nil }
        var authority = uri[start...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        if authority.hasPrefix("[") {
            return authority.firstIndex(of: "]").map { String(authority[...$0]).lowercased() }
        }
        return String(authority.prefix { $0 != ":" }).lowercased()
    }

    /// Text like "apple.com" or "www.apple.com/store": a name with a dot and no spaces. A
    /// user name before an `@`, a port and the dot that ends a fully qualified name are not
    /// part of it.
    static func bareHost(_ text: Substring) -> String? {
        var name = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if let at = name.lastIndex(of: "@") { name = name[name.index(after: at)...] }
        name = name.prefix { $0 != ":" }
        while name.hasSuffix(".") { name = name.dropLast() }
        guard name.contains("."), !name.hasPrefix("."),
            name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }),
            let tld = name.split(separator: ".").last, tld.count >= 2, tld.allSatisfy(\.isLetter)
        else { return nil }
        return name.lowercased()
    }

    private static func host(of text: Substring) -> String? {
        host(of: String(text))
    }

    /// Hosts compare without case, a leading "www." or the dot that ends a fully qualified name.
    private static func comparable(_ host: String) -> String {
        var host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Finds URLs in plain text, for ⌘-clicking output that has no OSC 8 links: http, https,
/// file and mailto, the way most terminals do. Bare domains and paths are left alone, since
/// guessing them makes ordinary words clickable.
public enum URLDetector {
    public struct Found: Equatable, Sendable {
        /// The columns it covers.
        public var columns: Range<Int>
        public var url: String
    }

    static let schemes = ["https://", "http://", "file://", "mailto:"]

    /// The URL covering `column` in a row, if any. `line` holds what each column shows: a
    /// character, or nil for the right half of a wide one.
    public static func url(in line: [Character?], at column: Int) -> Found? {
        urls(in: line).first { $0.columns.contains(column) }
    }

    public static func urls(in line: [Character?]) -> [Found] {
        var characters: [Character] = []
        var startColumn: [Int] = []
        for (column, character) in line.enumerated() {
            guard let character else { continue }
            characters.append(character)
            startColumn.append(column)
        }
        var found: [Found] = []
        var index = 0
        while index < characters.count {
            guard let scheme = schemes.first(where: { matches($0, at: index, in: characters) }),
                index == 0 || !(characters[index - 1].isLetter || characters[index - 1].isNumber)
            else {
                index += 1
                continue
            }
            var end = index + scheme.count
            while end < characters.count, allowed(characters[end]) { end += 1 }
            end = trimmed(characters, from: index, to: end)
            let url = String(characters[index..<end])
            let body = url.dropFirst(scheme.count)
            if !body.isEmpty, scheme != "mailto:" || body.contains("@") {
                let lastColumn = startColumn[end - 1]
                let width = (lastColumn + 1 < line.count && line[lastColumn + 1] == nil) ? 2 : 1
                found.append(Found(columns: startColumn[index]..<(lastColumn + width), url: url))
            }
            index = max(end, index + 1)
        }
        return found
    }

    private static func matches(_ scheme: String, at index: Int, in characters: [Character]) -> Bool {
        guard index + scheme.count <= characters.count else { return false }
        for (offset, expected) in scheme.enumerated() where characters[index + offset].lowercased() != String(expected)
        {
            return false
        }
        return true
    }

    /// Characters a URL in running text can hold: no spaces, controls, quotes or angle
    /// brackets, which end it.
    private static func allowed(_ character: Character) -> Bool {
        guard !character.isWhitespace, let scalar = character.unicodeScalars.first,
            scalar.value >= 0x21, !(0x7F...0x9F).contains(scalar.value)
        else { return false }
        return !"<>\"'`{}|\\^".contains(character)
    }

    /// Drops what ends a sentence rather than the URL: final punctuation, and a closing
    /// bracket with no opening one inside the URL, as in "(see https://example.com)".
    private static func trimmed(_ characters: [Character], from start: Int, to end: Int) -> Int {
        var end = end
        while end > start {
            let last = characters[end - 1]
            if ".,;:!?*".contains(last) {
                end -= 1
                continue
            }
            if let open = ["(": ")", "[": "]"].first(where: { $0.value == String(last) })?.key {
                let text = characters[start..<end]
                let opens = text.filter { String($0) == open }.count
                let closes = text.filter { $0 == last }.count
                if closes > opens {
                    end -= 1
                    continue
                }
            }
            break
        }
        return end
    }
}
