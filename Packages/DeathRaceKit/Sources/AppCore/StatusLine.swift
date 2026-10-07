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
        /// Something that went wrong: a command that exited badly. `docs/DESIGN.md` allows the
        /// danger colour only alongside a word or a glyph, and this run always carries the
        /// words — "Exited with status 1" — so it qualifies.
        case danger
    }

    /// What a click on a run does.
    public enum Tap: Equatable, Sendable {
        /// Shows the settings lines that could not be used.
        case settingsProblems
        /// Opens the Come & Go page of the WRLD window.
        case comeAndGo
        /// Opens Settings at the page the Sessions group is on.
        case sessions
        /// Scrolls to the command the Fast run is about, which is the only thing a tap on it
        /// could usefully mean.
        case lastCommand
    }

    public struct Run: Equatable, Sendable {
        public var text: String
        public var style: Style
        /// The lock glyph before Secure input.
        public var symbol: String?
        public var tap: Tap?

        public init(_ text: String, _ style: Style, symbol: String? = nil, tap: Tap? = nil) {
            self.text = text
            self.style = style
            self.symbol = symbol
            self.tap = tap
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
        /// Armed and Dangerous: the panes typing in the active tab goes to, none while it's
        /// off, and how many of them have ended. It leads the bar, in the warning color.
        public var armedPanes = 0
        public var endedArmedPanes = 0
        /// Legends Never Die was asked for and could not be had, so this app's sessions go
        /// when it does. The bar says so in a few words and the full reason is in the log,
        /// because a setting that reads on while nothing is keeping sessions is a lie.
        public var sessionsEndWithTheApp = false
        /// The last command this pane finished, for the mockup's "Fast 12.4s". Nil when the
        /// shell said nothing about one, which is every pane without the integration.
        public var lastCommand: CommandOutcome?
        /// Panes in the active tab whose last command worked, and how many ran one at all —
        /// the mockup's "2 of 3 healthy", which Phase 4 had to defer for want of exit codes.
        /// Said only when more than one pane has run something, because "1 of 1 healthy" is
        /// a sentence about nothing.
        public var healthyPanes = 0
        public var panesWithACommand = 0

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
            if facts.armedPanes > 0 {
                leading.append(
                    Run(
                        BroadcastLabel.status(panes: facts.armedPanes, ended: facts.endedArmedPanes), .warning,
                        symbol: "exclamationmark.triangle.fill"))
            }
            if let directory = facts.directory {
                leading.append(Run(abbreviatingHome(directory, home: facts.home), .muted))
            }
            if let branch = facts.branch { leading.append(Run(branch, .accent)) }
            if facts.openTunnels > 0 {
                let count = facts.openTunnels
                leading.append(
                    Run(
                        count == 1 ? "1 tunnel" : "\(count) tunnels", .muted, symbol: "arrow.left.arrow.right",
                        tap: .comeAndGo))
            }
            if let last = facts.lastCommand, let words = last.words {
                leading.append(Run(words, last.failed ? .danger : .muted, tap: .lastCommand))
            }
            // "2 of 3 healthy" only once there is a disagreement worth reporting; with every
            // pane happy the bar has better things to say.
            if facts.panesWithACommand > 1, facts.healthyPanes < facts.panesWithACommand {
                leading.append(
                    Run(
                        "\(facts.healthyPanes) of \(facts.panesWithACommand) healthy", .warning,
                        symbol: "heart.slash"))
            }
            if facts.secureInput { leading.append(Run("Secure input", .muted, symbol: "lock.fill")) }
            if facts.sessionsEndWithTheApp {
                leading.append(Run("Sessions end with the app", .warning, tap: .sessions))
            }
            if facts.settingsProblems > 0 {
                let count = facts.settingsProblems
                leading.append(
                    Run(
                        count == 1 ? "1 setting could not be used" : "\(count) settings could not be used", .warning,
                        tap: .settingsProblems))
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
    /// What a program in it last reported, for the fill in its pill — parsed, encoded, decoded
    /// and tested since Phase 1, and dropped on the floor until now. A fraction rather than
    /// `VTCore.ProgressReport`, because AppCore does not depend on VTCore and should not start:
    /// the app translates at the boundary, as it already does for `FastLabel`'s numbers.
    public var progress: TabProgress?

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

/// How a pane's last command went, in plain numbers: AppCore does not depend on VTCore, so the
/// app reads a `CommandRecord` and hands this over.
public struct CommandOutcome: Equatable, Sendable {
    public var text: String
    public var milliseconds: UInt32?
    public var exitCode: Int32?
    /// The fastest this command has been, so the words can say by how much it was beaten.
    public var bestMilliseconds: UInt32?
    /// What the status bar says about it, and what a badge over it would say. Nil when there is
    /// nothing worth saying, which is most commands.
    public var words: String?

    public init(
        text: String, milliseconds: UInt32?, exitCode: Int32?, bestMilliseconds: UInt32? = nil,
        thresholdMilliseconds: UInt32 = 1_000
    ) {
        self.text = text
        self.milliseconds = milliseconds
        self.exitCode = exitCode
        self.bestMilliseconds = bestMilliseconds
        words = FastLabel.words(
            milliseconds: milliseconds, exitCode: exitCode, bestMilliseconds: bestMilliseconds,
            thresholdMilliseconds: thresholdMilliseconds)
    }

    /// Whether it ended badly. No exit code is not a failure: it is a shell that said nothing.
    public var failed: Bool { (exitCode ?? 0) != 0 }
}

/// What a program reported about its own progress, as a tab pill needs it.
///
/// `OSC 9;4`'s five states collapse to the two questions a pill can answer — how far along, and
/// whether something went wrong — because a 3 pt fill has no room to say more.
public struct TabProgress: Equatable, Sendable {
    /// 0...1, or nil for a program that says it is working without saying how far.
    public var fraction: Double?
    /// The program reported trouble, so the fill is drawn in `danger`.
    public var failed: Bool

    public init(fraction: Double?, failed: Bool = false) {
        self.fraction = fraction.map { min(max($0, 0), 1) }
        self.failed = failed
    }
}
