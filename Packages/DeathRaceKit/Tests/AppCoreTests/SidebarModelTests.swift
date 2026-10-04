import Foundation
import Testing
import Vault

@testable import AppCore

@Suite("The WRLD sidebar")
struct SidebarModelTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func model(
        query: String = "", expanded: Set<GroupID> = [], connected: Set<String> = [], open: Set<TunnelID> = [],
        vault: Vault = BoardVault.vault
    ) -> SidebarModel {
        var state = WRLDState()
        state.update(.vault(BoardVault.prodAPI.id)) {
            $0.latency = 18
            $0.latencyCheckedAt = now
        }
        state.update(.vault(BoardVault.scratch.id)) { $0.latencyCheckedAt = now }
        return SidebarModel(
            .init(
                vault: vault, state: state, connected: connected, openTunnels: open, expandedGroups: expanded,
                query: query, now: now))
    }

    @Test func itShowsTheBoardsSections() {
        let sidebar = model(open: [TunnelID(rawValue: "t1")])
        #expect(sidebar.sections.map(\.title) == ["Legends", "WRLD", "Wishing Well", "Come & Go"])
        #expect(sidebar.sections.map(\.count) == [2, 6, 1, 2])
        let legends = sidebar.sections[0].rows
        #expect(legends.map(\.title) == ["prod-api", "nas-999"])
        #expect(legends.first?.meta == "18 ms")
        #expect(legends.first?.dot == .answering)
        #expect(legends.first?.accessibilityLabel == "prod-api, 18 ms")
        // Groups, closed, then the hosts in none.
        let wrld = sidebar.sections[1].rows
        #expect(wrld.map(\.title) == ["Homelab", "Work", "scratch"])
        #expect(wrld.map(\.meta) == ["4", "1", "offline"])
        #expect(wrld.first?.kind == .group(BoardVault.homelab.id, expanded: false))
        #expect(wrld.first?.accessibilityLabel == "Homelab, 4 hosts")
        let snippet = sidebar.sections[2].rows.first
        #expect(snippet?.fields == ["env"])
        #expect(snippet?.accessibilityLabel == "deploy, asks for env")
        let tunnels = sidebar.sections[3].rows
        #expect(tunnels.map(\.title) == ["5432 → db", "SOCKS 1080"])
        #expect(tunnels.map(\.dot) == [.connected, .unknown])
        #expect(tunnels.first?.accessibilityLabel == "5432 → db:5432 · Local · through prod-api, open")
    }

    @Test func anOpenGroupShowsItsHostsUnderIt() {
        // nas-999 comes from ~/.ssh/config, so the pool files it under "alias:nas-999", not
        // its vault id "h2"; the row must look it up by that key to show connected.
        let sidebar = model(expanded: [BoardVault.homelab.id], connected: [BoardVault.nas.connectionKey])
        #expect(BoardVault.nas.connectionKey == "alias:nas-999")
        let wrld = sidebar.sections[1].rows
        #expect(wrld.map(\.title) == ["Homelab", "nas-999", "pi-hole", "jellyfin", "bastion", "Work", "scratch"])
        #expect(wrld[1].isIndented)
        #expect(wrld[1].dot == .connected)
        #expect(wrld[1].accessibilityLabel == "nas-999, connected")
        // nas-999 is a Legend too: its two rows can't share an id.
        let ids = sidebar.sections.flatMap(\.rows).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func searchingShowsOnlyWhatItFinds() {
        let sidebar = model(query: "prod")
        #expect(sidebar.isSearching)
        #expect(sidebar.sections.map(\.title) == ["Legends", "Wishing Well", "Come & Go"])
        #expect(sidebar.sections[0].rows.map(\.title) == ["prod-api"])
        #expect(sidebar.sections[2].rows.map(\.title) == ["5432 → db"])
        let grouped = model(query: "192.168")
        // Matches come out of their groups.
        #expect(grouped.sections.map(\.title) == ["WRLD"])
        #expect(grouped.sections[0].rows.map(\.title) == ["pi-hole", "jellyfin"])
        #expect(model(query: "zzz").sections.isEmpty)
    }

    @Test func anEmptyWRLDStillShowsItsSection() {
        let sidebar = model(vault: Vault())
        #expect(sidebar.sections.map(\.title) == ["WRLD"])
        #expect(sidebar.sections[0].rows.isEmpty)
        #expect(SidebarModel.emptyHint == "Add a host to WRLD to connect with one click.")
    }

    @Test func tunnelsHaveShortNames() {
        #expect(
            SidebarModel.shortName(
                TunnelSpec(kind: .remote, listenPort: 8080, target: .init(host: "localhost", port: 3000)))
                == "remote 8080 → localhost")
        #expect(
            SidebarModel.shortName(TunnelSpec(kind: .dynamic, bindAddress: "127.0.0.1", listenPort: 1080))
                == "SOCKS 127.0.0.1:1080")
    }
}
