/// Armed and Dangerous's words: the pill, the banner, the status bar.
public enum BroadcastLabel {
    /// The pill: "prod-api × 3" when the armed panes are one host or program, or hosts
    /// named alike (prod-api-1, prod-api-2 and prod-api-3), else "3 panes".
    public static func pill(names: [String]) -> String {
        let stem = stem(of: names)
        return stem.isEmpty ? "\(names.count) panes" : "\(stem) × \(names.count)"
    }

    /// The start every name shares up to where they part at a number or a separator:
    /// "prod-api" for prod-api-1 and prod-api-2, "db" for db1 and db2; nothing for web and
    /// website, which part mid-word, or when it would be a single letter.
    static func stem(of names: [String]) -> String {
        guard let first = names.first else { return "" }
        var shared = Array(first)
        for name in names.dropFirst() {
            let characters = Array(name)
            var count = 0
            while count < shared.count, count < characters.count, shared[count] == characters[count] { count += 1 }
            shared.removeSubrange(count...)
        }
        func isSeparator(_ character: Character) -> Bool { "-_. ".contains(character) }
        func parts(_ character: Character) -> Bool { character.isNumber || isSeparator(character) }
        // When the shared prefix stops in the middle of a number, that number is a counter
        // the names differ by (prod-api-10, prod-api-11), so drop the whole digit run. But a
        // digit the names share, with the difference after it (web2-a, web2-b), stays. Then
        // trailing separators always go.
        let splitInsideNumber =
            shared.last?.isNumber == true
            && names.contains { Array($0).dropFirst(shared.count).first?.isNumber == true }
        if splitInsideNumber {
            while let last = shared.last, last.isNumber { shared.removeLast() }
        }
        while let last = shared.last, isSeparator(last) { shared.removeLast() }
        guard shared.count > 1 else { return "" }
        // Every name must go on from the stem with a number or a separator, or end there.
        for name in names {
            let rest = name.dropFirst(shared.count)
            if let next = rest.first, !parts(next) { return "" }
        }
        return String(shared)
    }

    /// The banner: "Typing goes to 3 panes: prod-api-1, prod-api-2 and prod-api-3."
    public static func banner(names: [String]) -> String {
        "Typing goes to \(names.count) panes: \(joined(names))."
    }

    /// The status bar: "Armed and Dangerous · 3 panes · 1 ended".
    public static func status(panes: Int, ended: Int) -> String {
        ended > 0 ? "Armed and Dangerous · \(panes) panes · \(ended) ended" : "Armed and Dangerous · \(panes) panes"
    }

    /// "a", "a and b", "a, b and c".
    static func joined(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
