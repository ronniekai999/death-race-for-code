import Testing

@testable import AppCore

@Suite("Armed and Dangerous")
struct ArmedTests {
    let a = PaneID(1)
    let b = PaneID(2)
    let c = PaneID(3)

    func window() -> WindowModel {
        var model = WindowModel(tab: TabModel(id: TabID(1), pane: a))
        model.split(.sideBySide, newPane: b)
        model.split(.stacked, newPane: c)
        return model
    }

    @Test func armingSendsTypingToEveryOtherPane() throws {
        var model = window()
        model.toggleArmed()
        let tab = try #require(model.activeTab)
        #expect(tab.isArmed)
        #expect(tab.armedPanes == [a, b, c])
        #expect(tab.broadcastTargets(from: b) == [a, c])
        model.toggleArmed()
        #expect(model.activeTab?.isArmed == false)
        #expect(model.activeTab?.broadcastTargets(from: b) == [])
    }

    @Test func stopDisarmsItsTabWhereverTheKeysAre() {
        var model = window()
        model.toggleArmed()
        model.newTab(TabID(2), pane: PaneID(9))
        model.disarm(TabID(1))
        #expect(model.tabs.first?.isArmed == false)
        #expect(model.activeTabID == TabID(2))
    }

    @Test func aPaneLeftOutNeitherSendsNorReceives() throws {
        var model = window()
        model.toggleArmed()
        model.setArmed(c, false)
        let tab = try #require(model.activeTab)
        #expect(tab.armedPanes == [a, b])
        #expect(tab.broadcastTargets(from: a) == [b])
        #expect(tab.broadcastTargets(from: c) == [])
        model.setArmed(c, true)
        #expect(model.activeTab?.armedPanes == [a, b, c])
    }

    @Test func oneArmedPaneOnItsOwnDisarms() {
        var model = window()
        model.toggleArmed()
        model.setArmed(b, false)
        model.setArmed(c, false)
        #expect(model.activeTab?.isArmed == false)

        var closing = window()
        closing.toggleArmed()
        closing.closePane(b)
        #expect(closing.activeTab?.isArmed == true)
        closing.closePane(c)
        #expect(closing.activeTab?.isArmed == false)
    }

    @Test func aTabOfOnePaneCantBeArmedAndNewSplitsJoin() {
        var single = WindowModel(tab: TabModel(id: TabID(1), pane: a))
        single.toggleArmed()
        #expect(single.activeTab?.isArmed == false)

        var model = window()
        model.toggleArmed()
        let d = PaneID(4)
        model.split(.sideBySide, newPane: d)
        #expect(model.activeTab?.armedPanes.contains(d) == true)
    }

    @Test func theStatusBarLeadsWithIt() {
        var facts = StatusLine.Facts(columns: 80, rows: 24)
        facts.directory = "/Users/r/code"
        facts.home = "/Users/r"
        facts.armedPanes = 3
        facts.endedArmedPanes = 1
        let line = StatusLine(facts)
        #expect(
            line.leading.first
                == .init(
                    "Armed and Dangerous · 3 panes · 1 ended", .warning, symbol: "exclamationmark.triangle.fill"))
        #expect(line.leading.map(\.text).last == "~/code")
        facts.armedPanes = 0
        #expect(StatusLine(facts).leading.map(\.text) == ["~/code"])
    }

    @Test func theWords() {
        #expect(BroadcastLabel.pill(names: ["prod-api", "prod-api", "prod-api"]) == "prod-api × 3")
        #expect(BroadcastLabel.pill(names: ["prod-api", "zsh"]) == "2 panes")
        #expect(BroadcastLabel.pill(names: ["prod-api-1", "prod-api-2", "prod-api-3"]) == "prod-api × 3")
        #expect(BroadcastLabel.pill(names: ["prod-api-10", "prod-api-11"]) == "prod-api × 2")
        #expect(BroadcastLabel.pill(names: ["prod-api", "prod-api-2"]) == "prod-api × 2")
        #expect(BroadcastLabel.pill(names: ["db1", "db2"]) == "db × 2")
        #expect(BroadcastLabel.pill(names: ["web", "website"]) == "2 panes")
        #expect(BroadcastLabel.pill(names: ["a1", "a2"]) == "2 panes")
        // A digit the names share, with the difference after it, stays in the stem.
        #expect(BroadcastLabel.pill(names: ["web2-a", "web2-b"]) == "web2 × 2")
        #expect(BroadcastLabel.pill(names: ["db01-east", "db01-west"]) == "db01 × 2")
        #expect(BroadcastLabel.pill(names: ["x86-a", "x86-b"]) == "x86 × 2")
        // But a split counter (10 vs 11) drops to the shared stem before it.
        #expect(BroadcastLabel.pill(names: ["prod-api-10", "prod-api-11"]) == "prod-api × 2")
        #expect(
            BroadcastLabel.banner(names: ["prod-api-1", "prod-api-2", "prod-api-3"])
                == "Typing goes to 3 panes: prod-api-1, prod-api-2 and prod-api-3.")
        #expect(BroadcastLabel.banner(names: ["a", "b"]) == "Typing goes to 2 panes: a and b.")
        #expect(BroadcastLabel.status(panes: 3, ended: 1) == "Armed and Dangerous · 3 panes · 1 ended")
        #expect(BroadcastLabel.status(panes: 3, ended: 0) == "Armed and Dangerous · 3 panes")
    }
}
