import Vault

/// Wishing Well's rules apart from the views: the buttons' words, the names and text a saved
/// selection starts with, and a command shortened for a list.
public enum WishingWell {
    /// "Insert", or "Insert in 3 panes" while the tab is armed.
    public static func insertTitle(panes: Int) -> String {
        panes > 1 ? "Insert in \(panes) panes" : "Insert"
    }

    /// "Run", or "Run in 3 panes".
    public static func runTitle(panes: Int) -> String {
        panes > 1 ? "Run in \(panes) panes" : "Run"
    }

    /// A command on one line, for a list: its first line, with "…" when there's more.
    public static func preview(_ text: String, limit: Int = 80) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var first = String(lines.first ?? "")
        var cut = lines.dropFirst().contains { !$0.allSatisfy(\.isWhitespace) }
        if first.count > limit {
            first = String(first.prefix(limit))
            cut = true
        }
        return cut ? first + " …" : first
    }

    /// A selection as a snippet's text: without the blank lines and spaces around it, and
    /// with every `{{` kept as it is, so a Go template (`docker inspect -f '{{.State}}'`)
    /// doesn't turn into a field.
    public static func snippetText(fromSelection text: String) -> String {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line in
            var line = Substring(line)
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            return String(line)
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        var result = ""
        var rest = Substring(lines.joined(separator: "\n"))
        while let range = rest.firstRange(of: "{{") {
            result += rest[..<range.lowerBound] + "\\{{"
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    /// A name for a saved selection, to change before saving: its first line, cut at a
    /// word to at most `limit` characters.
    public static func suggestedName(for text: String, limit: Int = 40) -> String {
        let line =
            text.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") } ?? ""
        guard !line.isEmpty else { return "Snippet" }
        guard line.count > limit else { return line }
        var name = ""
        for word in line.split(separator: " ") {
            let next = name.isEmpty ? String(word) : name + " " + word
            guard next.count <= limit else { break }
            name = next
        }
        return name.isEmpty ? String(line.prefix(limit)) : name
    }
}

/// A snippet being filled in: a value for each placeholder, and the command they make.
public struct SnippetFill: Equatable, Sendable {
    public let template: SnippetTemplate
    /// By placeholder name; each starts at its default or first choice.
    public var values: [String: String]

    public init(_ text: String) {
        template = SnippetTemplate(text)
        values = Dictionary(
            template.placeholders.map { ($0.name, $0.initialValue) }, uniquingKeysWith: { first, _ in first })
    }

    /// One field for each placeholder, in the order they first appear.
    public var fields: [SnippetTemplate.Placeholder] { template.placeholders }

    /// What gets typed.
    public var command: String { template.render(values) }

    /// Every field has something in it, so the command has no gaps: Run waits for that.
    public var isComplete: Bool {
        fields.allSatisfy { !(values[$0.name] ?? "").allSatisfy(\.isWhitespace) }
    }
}
