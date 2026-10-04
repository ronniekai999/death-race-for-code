/// Armed and Dangerous's words: the pill, the banner, the status bar.
public enum BroadcastLabel {
    /// The pill: "prod-api × 3" when the armed panes are all one host or program, else
    /// "3 panes".
    public static func pill(names: [String]) -> String {
        if let first = names.first, names.allSatisfy({ $0 == first }) { return "\(first) × \(names.count)" }
        return "\(names.count) panes"
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
