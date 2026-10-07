import Testing

@testable import AppCore

@Suite struct StatusLineTests {
    @Test func tabLabelsPreferTheProgramsTitle() {
        #expect(
            TabLabel.text(title: "vim — notes.md", program: "vim", directory: "/tmp", home: "/Users/r")
                == "vim — notes.md")
        #expect(
            TabLabel.text(title: "", program: "zsh", directory: "/Users/r/code", home: "/Users/r") == "zsh · ~/code")
        #expect(TabLabel.text(title: "  ", program: "zsh", directory: "/Users/r", home: "/Users/r") == "zsh · ~")
        #expect(TabLabel.text(title: "", program: nil, directory: nil, home: nil) == "Shell")
        #expect(
            TabLabel.text(title: "build", program: "make", directory: nil, home: nil, end: .exited(code: 1))
                == "build · exited 1")
        #expect(
            TabLabel.text(title: "build", program: "make", directory: nil, home: nil, end: .exited(code: 0)) == "build")
    }

    @Test func homeIsShownAsATilde() {
        #expect(abbreviatingHome("/Users/r/code", home: "/Users/r") == "~/code")
        #expect(abbreviatingHome("/Users/r", home: "/Users/r/") == "~")
        #expect(abbreviatingHome("/Users/robert", home: "/Users/r") == "/Users/robert")
        #expect(abbreviatingHome("/etc", home: nil) == "/etc")
        #expect(abbreviatingHome("/x", home: "/") == "/x")
    }

    @Test func theStatusLineFollowsTheMockup() {
        var facts = StatusLine.Facts(columns: 132, rows: 38)
        facts.directory = "/Users/r/code"
        facts.home = "/Users/r"
        facts.branch = "main"
        facts.program = "zsh"
        let line = StatusLine(facts)
        #expect(line.leading == [StatusLine.Run("~/code", .muted), StatusLine.Run("main", .accent)])
        #expect(line.trailing == [StatusLine.Run("132×38", .muted), StatusLine.Run("zsh", .muted)])
    }

    @Test func secureInputShowsOnlyWhileOn() {
        var facts = StatusLine.Facts(columns: 80, rows: 24)
        #expect(StatusLine(facts).leading.isEmpty)
        facts.secureInput = true
        #expect(StatusLine(facts).leading == [StatusLine.Run("Secure input", .muted, symbol: "lock.fill")])
    }

    @Test func aHoveredLinkTakesTheLeftSide() {
        var facts = StatusLine.Facts(columns: 80, rows: 24)
        facts.directory = "/tmp"
        facts.hoveredLink = "https://example.com"
        #expect(StatusLine(facts).leading == [StatusLine.Run("https://example.com", .ink)])
    }

    @Test func settingsProblemsAreCounted() {
        var facts = StatusLine.Facts(columns: 80, rows: 24)
        facts.settingsProblems = 2
        #expect(
            StatusLine(facts).leading.last
                == StatusLine.Run("2 settings could not be used", .warning, tap: .settingsProblems))
        facts.settingsProblems = 1
        #expect(StatusLine(facts).leading.last?.text == "1 setting could not be used")
    }

    @Test func sessionsThatWillNotSurviveAreSaidSo() {
        var facts = StatusLine.Facts(columns: 80, rows: 24)
        #expect(!StatusLine(facts).leading.contains { $0.tap == .sessions })
        facts.sessionsEndWithTheApp = true
        #expect(
            StatusLine(facts).leading.contains(StatusLine.Run("Sessions end with the app", .warning, tap: .sessions)))
        // A hovered link takes the whole left side, as it does over everything else there.
        facts.hoveredLink = "https://example.com"
        #expect(StatusLine(facts).leading == [StatusLine.Run("https://example.com", .ink)])
    }

    @Test func activityQuietsDownAndClearsWhenSeen() {
        var activity = TabActivity()
        #expect(!activity.isBusy(at: 0))
        activity.output(at: 10)
        #expect(activity.isBusy(at: 11))
        #expect(!activity.isBusy(at: 11.6))
        #expect(activity.quietAt() == 11.5)
        activity.bell()
        #expect(activity.rang)
        activity.shown()
        #expect(!activity.rang && !activity.isBusy(at: 10))
        activity.failure = .exited(code: 2)
        activity.shown()
        #expect(activity.failure == .exited(code: 2))
    }

    @Test func shellEndsReadPlainly() {
        #expect(ShellEnd.exited(code: 3).sentence == "The shell exited with status 3.")
        #expect(ShellEnd.signaled(9).short == "ended by signal 9")
        #expect(!ShellEnd.exited(code: 0).isFailure)
        #expect(ShellEnd.unknown.isFailure)
    }
}

/// The mockup's "Fast 12.4s" and "2 of 3 healthy", and the pill fill a program asks for. All
/// three were parsed or decided in earlier phases and had nowhere to go until Fast.
@Suite("Fast, health and progress") struct FastFactsTests {

    private func facts() -> StatusLine.Facts { StatusLine.Facts(columns: 80, rows: 24) }

    private func texts(_ facts: StatusLine.Facts) -> [String] { StatusLine(facts).leading.map(\.text) }

    // MARK: - Fast, in the bar

    @Test func theLastCommandIsNamedWithItsTime() {
        var f = facts()
        f.lastCommand = CommandOutcome(text: "swift build", milliseconds: 12_400, exitCode: 0)
        #expect(texts(f).contains("Fast 12.4s ✓"))
        #expect(StatusLine(f).leading.first { $0.text == "Fast 12.4s ✓" }?.style == .muted)
    }

    /// A win is worth saying; being slower than your best is not, which `FastLabel` already
    /// decided and the bar inherits.
    @Test func beatingYourBestIsSaidInTheBar() {
        var f = facts()
        f.lastCommand = CommandOutcome(
            text: "swift build", milliseconds: 9_300, exitCode: 0, bestMilliseconds: 12_400)
        #expect(texts(f).contains("Fast 9.3s · 3.1s faster than your best ✓"))
    }

    /// `docs/DESIGN.md` allows the danger colour only with a word, and this run carries one.
    @Test func aFailedCommandIsSaidInDanger() {
        var f = facts()
        f.lastCommand = CommandOutcome(text: "make test", milliseconds: 4, exitCode: 2)
        let run = StatusLine(f).leading.first { $0.text.contains("exited with status") }
        // The duration clause comes first, so the status clause is the lower-case one.
        #expect(run?.text == "Fast 4ms · exited with status 2 ✗", "\(texts(f))")
        #expect(run?.style == .danger)
    }

    /// Most commands have nothing worth saying, and the bar stays as it was.
    @Test func aQuickCommandAddsNothingToTheBar() {
        var f = facts()
        f.lastCommand = CommandOutcome(text: "ls", milliseconds: 8, exitCode: 0)
        #expect(StatusLine(f).leading.isEmpty, "\(texts(f))")
    }

    /// A pane whose shell says nothing about commands — no integration — reads as it always did.
    @Test func withNoCommandTheBarIsUnchanged() {
        #expect(StatusLine(facts()).leading.isEmpty)
    }

    // MARK: - "2 of 3 healthy"

    @Test func panesThatWentWrongAreCounted() {
        var f = facts()
        f.panesWithACommand = 3
        f.healthyPanes = 2
        #expect(texts(f).contains("2 of 3 healthy"))
        #expect(StatusLine(f).leading.first { $0.text.hasSuffix("healthy") }?.style == .warning)
    }

    /// With everything healthy the bar has better things to say than a tautology.
    @Test func everyPaneHealthyIsNotWorthSaying() {
        var f = facts()
        f.panesWithACommand = 3
        f.healthyPanes = 3
        #expect(!texts(f).contains { $0.hasSuffix("healthy") }, "\(texts(f))")
    }

    /// And "0 of 1 healthy" is a sentence about one pane, which its own Fast run already covers.
    @Test func oneLonePaneIsNotCounted() {
        var f = facts()
        f.panesWithACommand = 1
        f.healthyPanes = 0
        #expect(!texts(f).contains { $0.hasSuffix("healthy") }, "\(texts(f))")
    }

    // MARK: - The pill's fill

    @Test func aProgressFractionIsKeptInRange() {
        #expect(TabProgress(fraction: 0.5).fraction == 0.5)
        #expect(TabProgress(fraction: -1).fraction == 0)
        #expect(TabProgress(fraction: 2).fraction == 1)
        #expect(TabProgress(fraction: nil).fraction == nil, "working, without saying how far")
        #expect(TabProgress(fraction: 0.3, failed: true).failed)
    }

    @Test func aTabRemembersWhatAProgramReported() {
        var activity = TabActivity()
        #expect(activity.progress == nil)
        activity.progress = TabProgress(fraction: 0.72)
        #expect(activity.progress?.fraction == 0.72)
    }
}
