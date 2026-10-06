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
