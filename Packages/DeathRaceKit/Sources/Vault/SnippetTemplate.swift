import Foundation

/// A Wishing Well snippet's text with its `{{placeholders}}`.
///
/// | Syntax | Meaning |
/// |---|---|
/// | `{{env}}` | a field |
/// | `{{version=2.4.1}}` | a field with a default |
/// | `{{env:prod\|staging}}` | a choice; the first is the default |
/// | `\{{` | literal braces |
///
/// Anything else that looks like a placeholder but isn't one (`{{}}`, an unclosed `{{`,
/// braces inside a name) stays as literal text, so a snippet can never fail to parse.
public struct SnippetTemplate: Equatable, Sendable {
    public struct Placeholder: Equatable, Sendable {
        public var name: String
        public var defaultValue: String?
        public var choices: [String]

        public init(name: String, defaultValue: String? = nil, choices: [String] = []) {
            self.name = name
            self.defaultValue = defaultValue
            self.choices = choices
        }

        /// What the field starts with: the default, else the first choice, else nothing.
        public var initialValue: String { defaultValue ?? choices.first ?? "" }

        static let longestName = 64

        init?(parsing inner: Substring) {
            let equals = inner.firstIndex(of: "=")
            let colon = inner.firstIndex(of: ":")
            var namePart = inner
            if let equals, colon.map({ equals < $0 }) ?? true {
                namePart = inner[..<equals]
                defaultValue = String(inner[inner.index(after: equals)...]).trimmingSpaces
                choices = []
            } else if let colon {
                namePart = inner[..<colon]
                defaultValue = nil
                choices = inner[inner.index(after: colon)...].split(separator: "|")
                    .map { String($0).trimmingSpaces }.filter { !$0.isEmpty }
            } else {
                defaultValue = nil
                choices = []
            }
            let name = String(namePart).trimmingSpaces
            guard !name.isEmpty, name.count <= Self.longestName,
                !name.contains(where: { $0 == "{" || $0 == "}" || $0.isNewline })
            else { return nil }
            self.name = name
        }
    }

    public enum Part: Equatable, Sendable {
        case text(String)
        case placeholder(Placeholder)
    }

    public let parts: [Part]

    public init(_ text: String) {
        var parts: [Part] = []
        var literal = ""
        var index = text.startIndex
        while index < text.endIndex {
            let rest = text[index...]
            if rest.hasPrefix("\\{{") {
                literal += "{{"
                index = text.index(index, offsetBy: 3)
                continue
            }
            if rest.hasPrefix("{{") {
                let innerStart = text.index(index, offsetBy: 2)
                if let close = text[innerStart...].range(of: "}}"),
                    let placeholder = Placeholder(parsing: text[innerStart..<close.lowerBound])
                {
                    if !literal.isEmpty {
                        parts.append(.text(literal))
                        literal = ""
                    }
                    parts.append(.placeholder(placeholder))
                    index = close.upperBound
                    continue
                }
            }
            literal.append(text[index])
            index = text.index(after: index)
        }
        if !literal.isEmpty { parts.append(.text(literal)) }
        self.parts = parts
    }

    /// Each placeholder once, in the order they first appear. A name used twice is one
    /// field, described by its first appearance.
    public var placeholders: [Placeholder] {
        var seen: Set<String> = []
        var result: [Placeholder] = []
        for case .placeholder(let placeholder) in parts where seen.insert(placeholder.name).inserted {
            result.append(placeholder)
        }
        return result
    }

    /// The command with `values` filled in; a placeholder without a value gets its
    /// `initialValue`.
    public func render(_ values: [String: String] = [:]) -> String {
        let fields = Dictionary(placeholders.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var result = ""
        for part in parts {
            switch part {
            case .text(let text): result += text
            case .placeholder(let placeholder):
                result += values[placeholder.name] ?? fields[placeholder.name]?.initialValue ?? ""
            }
        }
        return result
    }
}

extension String {
    /// Without leading and trailing spaces and tabs (Foundation-free).
    var trimmingSpaces: String {
        let isSpace: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        guard let first = firstIndex(where: { !isSpace($0) }), let last = lastIndex(where: { !isSpace($0) }) else {
            return ""
        }
        return String(self[first...last])
    }
}
