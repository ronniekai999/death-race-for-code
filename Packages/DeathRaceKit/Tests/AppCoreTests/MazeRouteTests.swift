import Testing
import Vault

@testable import AppCore

@Suite("Where Open in Maze goes")
struct MazeRouteTests {
    let hosts = BoardVault.vault.hosts

    @Test func aPaneOnAHostOpensThatHost() {
        let pane = HostRef.sshConfig(alias: "build-box")
        #expect(MazeRoute(pane: pane, hosts: hosts, aliases: []) == .open(pane))
        // Even with nothing saved: the pane's host is enough.
        #expect(MazeRoute(pane: pane, hosts: [], aliases: []) == .open(pane))
    }

    @Test func aLocalShellWithNoHostsAddsOne() {
        #expect(MazeRoute(pane: nil, hosts: [], aliases: []) == .addHost)
    }

    @Test func aLocalShellWithOneHostOpensIt() {
        #expect(
            MazeRoute(pane: nil, hosts: [BoardVault.scratch], aliases: []) == .open(.vault(BoardVault.scratch.id)))
    }

    /// Someone whose hosts are all in `~/.ssh/config` has hosts to browse: WRLD not having
    /// imported them is no reason to send them to New Host.
    @Test func aLocalShellCountsTheSSHConfigsNames() {
        #expect(MazeRoute(pane: nil, hosts: [], aliases: ["devbox"]) == .open(.sshConfig(alias: "devbox")))
        #expect(
            MazeRoute(pane: nil, hosts: [], aliases: ["devbox", "nas"])
                == .choose([.sshConfig(alias: "devbox"), .sshConfig(alias: "nas")]))
    }

    @Test func aLocalShellWithSeveralAsksWhichInHearMeCallingsOrder() {
        let hosts = [BoardVault.scratch, BoardVault.piHole, BoardVault.nas, BoardVault.prodAPI]
        // Legends in the order they're saved, then the rest in theirs, then the names WRLD
        // doesn't hold: nas-999 is held (imported), so it shows once, as the saved host.
        let route = MazeRoute(pane: nil, hosts: hosts, aliases: ["nas-999", "devbox"])
        let saved = [BoardVault.nas, BoardVault.prodAPI, BoardVault.scratch, BoardVault.piHole].map {
            HostRef.vault($0.id)
        }
        #expect(route == .choose(saved + [.sshConfig(alias: "devbox")]))
    }
}
