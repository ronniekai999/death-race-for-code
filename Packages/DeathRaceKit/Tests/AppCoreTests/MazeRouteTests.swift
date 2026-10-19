import Testing
import Vault

@testable import AppCore

@Suite("Where Open in Maze goes")
struct MazeRouteTests {
    let hosts = BoardVault.vault.hosts

    @Test func aPaneOnAHostOpensThatHost() {
        let pane = HostRef.sshConfig(alias: "build-box")
        #expect(MazeRoute(pane: pane, hosts: hosts) == .open(pane))
        // Even with nothing saved: the pane's host is enough.
        #expect(MazeRoute(pane: pane, hosts: []) == .open(pane))
    }

    @Test func aLocalShellWithNoHostsAddsOne() {
        #expect(MazeRoute(pane: nil, hosts: []) == .addHost)
    }

    @Test func aLocalShellWithOneHostOpensIt() {
        #expect(MazeRoute(pane: nil, hosts: [BoardVault.scratch]) == .open(.vault(BoardVault.scratch.id)))
    }

    @Test func aLocalShellWithSeveralAsksWhichWithLegendsFirst() {
        let hosts = [BoardVault.scratch, BoardVault.piHole, BoardVault.nas, BoardVault.prodAPI]
        // Legends in the order they're saved, then the rest in theirs: the sidebar's order.
        let ids = [BoardVault.nas, BoardVault.prodAPI, BoardVault.scratch, BoardVault.piHole].map(\.id)
        #expect(MazeRoute(pane: nil, hosts: hosts) == .choose(ids))
    }
}
