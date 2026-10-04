/// How a shell ended, as far as the window cares.
public enum ShellEnd: Equatable, Sendable {
    case exited(code: Int32)
    case signaled(Int32)
    case unknown

    /// A clean exit closes the pane; anything else stays on screen.
    public var isFailure: Bool { self != .exited(code: 0) }

    /// "exited 1", for the tab's pill.
    public var short: String {
        switch self {
        case .exited(let code): "exited \(code)"
        case .signaled(let signal): "ended by signal \(signal)"
        case .unknown: "exited"
        }
    }

    /// "The shell exited with status 1.", for the pane.
    public var sentence: String {
        switch self {
        case .exited(let code): "The shell exited with status \(code)."
        case .signaled(let signal): "The shell was ended by signal \(signal)."
        case .unknown: "The shell exited."
        }
    }
}

/// A path as the chrome shows it: the home directory as `~`.
public func abbreviatingHome(_ path: String, home: String?) -> String {
    guard let home, !home.isEmpty, home != "/" else { return path }
    let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
    if path == trimmedHome { return "~" }
    if path.hasPrefix(trimmedHome + "/") { return "~" + path.dropFirst(trimmedHome.count) }
    return path
}

/// What a tab's pill says: the title the program set, else the program and where it is
/// ("zsh · ~/code"), and how the shell ended if it failed ("build · exited 1").
public enum TabLabel {
    public static func text(
        title: String, program: String?, directory: String?, home: String?, end: ShellEnd? = nil
    ) -> String {
        var base = title.trimmingSpacesAndNewlines
        if base.isEmpty {
            let place = directory.map { abbreviatingHome($0, home: home) }
            base = [program, place].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if base.isEmpty { base = "Shell" }
        guard let end, end.isFailure else { return base }
        return "\(base) · \(end.short)"
    }
}

/// The status bar's text, as runs a view draws in their styles.
public struct StatusLine: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        /// Secondary text, most of the bar.
        case muted
        /// Primary text.
        case ink
        /// The branch.
        case accent
        /// Something to look at: settings that could not be used.
        case warning
    }

    public struct Run: Equatable, Sendable {
        public var text: String
        public var style: Style
        /// The lock glyph before Secure input.
        public var symbol: String?

        public init(_ text: String, _ style: Style, symbol: String? = nil) {
            self.text = text
            self.style = style
            self.symbol = symbol
        }
    }

    public var leading: [Run]
    public var trailing: [Run]

    /// What the bar shows for the active pane.
    public struct Facts: Equatable, Sendable {
        public var directory: String?
        public var home: String?
        public var branch: String?
        public var secureInput = false
        public var columns: Int
        public var rows: Int
        public var program: String?
        /// Where the link under the pointer goes, while ⌘ is held; it takes the left side.
        public var hoveredLink: String?
        /// Settings lines that could not be used at the last automatic reload.
        public var settingsProblems = 0
        /// Come & Go's tunnels that are open, in every window.
        public var openTunnels = 0

        public init(columns: Int, rows: Int) {
            self.columns = columns
            self.rows = rows
        }
    }

    public init(_ facts: Facts) {
        var leading: [Run] = []
        if let link = facts.hoveredLink {
            leading.append(Run(link, .ink))
        } else {
            if let directory = facts.directory {
                leading.append(Run(abbreviatingHome(directory, home: facts.home), .muted))
            }
            if let branch = facts.branch { leading.append(Run(branch, .accent)) }
            if facts.openTunnels > 0 {
                let count = facts.openTunnels
                leading.append(
                    Run(count == 1 ? "1 tunnel" : "\(count) tunnels", .muted, symbol: "arrow.left.arrow.right"))
            }
            if facts.secureInput { leading.append(Run("Secure input", .muted, symbol: "lock.fill")) }
            if facts.settingsProblems > 0 {
                let count = facts.settingsProblems
                leading.append(
                    Run(count == 1 ? "1 setting could not be used" : "\(count) settings could not be used", .warning))
            }
        }
        var trailing = [Run("\(facts.columns)×\(facts.rows)", .muted)]
        if let program = facts.program, !program.isEmpty { trailing.append(Run(program, .muted)) }
        self.leading = leading
        self.trailing = trailing
    }

    /// The separator drawn between runs.
    public static let separator = " · "
}

/// What a tab's pill shows besides its title.
public struct TabActivity: Equatable, Sendable {
    /// Output arrived while the tab was in the background; cleared after `quiet` seconds
    /// without any, or when the tab is shown.
    public private(set) var lastOutput: Double?
    /// The bell rang in the background; cleared when the tab is shown.
    public private(set) var rang = false
    /// The tab's shell ended badly.
    public var failure: ShellEnd?

    /// Seconds of quiet before the equalizer stops.
    public static let quiet = 1.5

    public init() {}

    /// Output in a background tab, at `time` in seconds.
    public mutating func output(at time: Double) {
        lastOutput = time
    }

    public mutating func bell() {
        rang = true
    }

    /// The tab was shown: what it was signalling has been seen.
    public mutating func shown() {
        lastOutput = nil
        rang = false
    }

    public func isBusy(at time: Double) -> Bool {
        guard let lastOutput else { return false }
        return time - lastOutput < Self.quiet
    }

    /// When to look again to stop the equalizer, if it is running.
    public func quietAt() -> Double? {
        lastOutput.map { $0 + Self.quiet }
    }
}

extension String {
    fileprivate var trimmingSpacesAndNewlines: String {
        var text = Substring(self)
        while let first = text.first, first.isWhitespace { text.removeFirst() }
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return String(text)
    }
}
