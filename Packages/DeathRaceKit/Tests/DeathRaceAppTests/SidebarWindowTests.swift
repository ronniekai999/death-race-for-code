import AppCore
import AppKit
import ConfigKit
import Foundation
import Testing
import Vault

@testable import DeathRaceApp

// In the window tests' suite, so they run one at a time with the windows they share the
// screen with.
extension WindowTests {
    @Test func theSidebarShowsWRLDAndItsRowsDoWhatTheySay() async throws {
        let host = TestHost()
        let connections = FakeConnections()
        let homelab = Group(id: GroupID(rawValue: "g1"), name: "Homelab")
        connections.vault = Vault(
            hosts: [
                WRLDHost(
                    id: HostID(rawValue: "h1"), name: "prod-api", source: .wrld(Connection(address: "10.0.4.21")),
                    isLegend: true),
                WRLDHost(
                    id: HostID(rawValue: "h2"), name: "pi-hole", source: .wrld(Connection(address: "192.168.12.2")),
                    groupID: homelab.id),
            ], groups: [homelab])
        connections.results = [.ready(FakeConnections.session)]
        host.connections = connections
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        #expect(controller.root.sidebar == nil)
        #expect(!controller.root.titleBar.sidebarButton.isHidden)

        controller.toggleSidebar(nil)
        let sidebar = try #require(controller.root.sidebar as? WRLDSidebarView)
        #expect(controller.root.leadingColumnWidth == WRLDSidebarView.width)
        #expect(controller.root.titleBar.sidebarButton.isOn)
        controller.root.layoutSubtreeIfNeeded()
        // The status bar sits beside it, as on the board.
        #expect(controller.root.statusBar.frame.minX == WRLDSidebarView.width)
        #expect(sidebar.model.sections.map(\.title) == ["Legends", "WRLD"])

        // A group's row opens it; a host's opens a session on it in a new tab.
        let group = try #require(sidebar.model.sections[1].rows.first)
        sidebar.onRow?(group, false)
        #expect(sidebar.model.sections[1].rows.map(\.title) == ["Homelab", "pi-hole"])
        let prod = try #require(sidebar.model.sections[0].rows.first)
        sidebar.onRow?(prod, false)
        #expect(controller.model.tabs.count == 2)
        #expect(controller.activePane?.launch == .connection(.vault(HostID(rawValue: "h1"))))

        // Its menu pins and unpins.
        let menu = try #require(sidebar.menuForRow?(prod))
        #expect(menu.items.map(\.title).contains("Unpin from Legends"))

        controller.toggleSidebar(nil)
        #expect(controller.root.sidebar == nil)
        #expect(controller.root.leadingColumnWidth == 0)
        #expect(!controller.root.titleBar.sidebarButton.isOn)
    }

    @Test func withoutWRLDThereIsNoSidebar() {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        #expect(controller.root.titleBar.sidebarButton.isHidden)
        controller.toggleSidebar(nil)
        #expect(controller.root.sidebar == nil)
        let item = NSMenuItem(
            title: "", action: #selector(PitLaneWindowController.toggleSidebar(_:)), keyEquivalent: "")
        #expect(!controller.validateMenuItem(item))
    }
}
