import PTYKit
import Testing
import Vault

@testable import AppCore

@Suite("Hosts in Hear Me Calling, and ssh in a pane")
struct HostItemsTests {
    let group = Group(id: GroupID(rawValue: "g1"), name: "Homelab")

    func vault() -> Vault {
        Vault(
            hosts: [
                WRLDHost(
                    id: HostID(rawValue: "h1"), name: "prod-api",
                    source: .wrld(Connection(address: "10.0.4.21", user: "ubuntu")),
                    tags: ["api"]),
                WRLDHost(
                    id: HostID(rawValue: "h2"), name: "nas-999", source: .sshConfig(alias: "nas-999"),
                    groupID: group.id,
                    isLegend: true),
            ], groups: [group])
    }

    @Test func legendsFirstThenWRLDThenYourConfig() {
        let items = PaletteSearch.hosts(vault: vault(), aliases: ["nas-999", "pi-hole", "pi-hole"])
        #expect(items.map(\.title) == ["nas-999", "prod-api", "pi-hole"])
        #expect(items.map(\.detail) == ["Legend · ~/.ssh/config", "ubuntu@10.0.4.21", "~/.ssh/config"])
        #expect(
            items.map(\.target) == [
                .host(.vault(HostID(rawValue: "h2"))), .host(.vault(HostID(rawValue: "h1"))),
                .host(.sshConfig(alias: "pi-hole")),
            ])
        #expect(items.map(\.id) == ["host.h2", "host.h1", "host.alias.pi-hole"])
        #expect(items.allSatisfy { $0.kind == .host && $0.alternate == "Open Beside" })
    }

    @Test func foundByAddressGroupAndTag() {
        let items = PaletteSearch.hosts(vault: vault(), aliases: [])
        #expect(PaletteSearch.search("10.0.4", in: items).map(\.item.title) == ["prod-api"])
        #expect(PaletteSearch.search("homelab", in: items).map(\.item.title) == ["nas-999"])
        #expect(PaletteSearch.search("api", in: items).first?.item.title == "prod-api")
    }

    @Test func otherKindsHaveNoAlternate() {
        #expect(PaletteSearch.actions.allSatisfy { $0.alternate == nil })
    }

    @Test func sshInAPaneGetsTheTerminalAndYourLoginShellsAgent() {
        let launch = ShellLaunchPlan.ssh(
            arguments: ["/usr/bin/ssh", "-F", "/h/.deathrace/ssh_config", "deathrace-prod-api"],
            login: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "SSH_AUTH_SOCK": "/tmp/agent"],
            environment: ["HOME": "/h", "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"], appVersion: "0.4.0")
        #expect(launch.executable == "/usr/bin/ssh")
        #expect(launch.arguments == ["/usr/bin/ssh", "-F", "/h/.deathrace/ssh_config", "deathrace-prod-api"])
        #expect(launch.workingDirectory == "/h")
        #expect(launch.environment["TERM"] == "xterm-256color")
        #expect(launch.environment["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin")
        #expect(launch.environment["SSH_AUTH_SOCK"] == "/tmp/agent")
        #expect(launch.environment["LANG"] == "en_US.UTF-8")
    }
}

@Suite("Tunnels in Hear Me Calling and the status bar")
struct TunnelItemsTests {
    @Test func tunnelsAreListedWithTheirState() {
        let open = Tunnel(
            id: TunnelID(rawValue: "t1"),
            spec: TunnelSpec(kind: .local, listenPort: 5432, target: .init(host: "db", port: 5432)))
        let off = Tunnel(id: TunnelID(rawValue: "t2"), spec: TunnelSpec(kind: .dynamic, listenPort: 1080))
        let vault = Vault(hosts: [
            WRLDHost(
                id: HostID(rawValue: "h1"), name: "prod-api", source: .wrld(Connection(address: "10.0.4.21")),
                tunnels: [open, off])
        ])
        let items = PaletteSearch.tunnels(vault: vault, open: [open.id])
        #expect(
            items.map(\.title) == [
                "5432 → db:5432 · Local · through prod-api", "SOCKS 1080 · Dynamic · through prod-api",
            ])
        #expect(items.map(\.detail) == ["Open · ↵ turns it off", "Off · ↵ turns it on"])
        #expect(items.map(\.id) == ["tunnel.t1", "tunnel.t2"])
        #expect(PaletteSearch.search("5432", in: items).map(\.item.id) == ["tunnel.t1"])
    }

    @Test func theStatusBarCountsOpenTunnels() {
        var facts = StatusLine.Facts(columns: 80, rows: 24)
        facts.directory = "/Users/r/code"
        facts.home = "/Users/r"
        #expect(StatusLine(facts).leading.map(\.text) == ["~/code"])
        facts.openTunnels = 1
        #expect(StatusLine(facts).leading.map(\.text) == ["~/code", "1 tunnel"])
        facts.openTunnels = 2
        #expect(StatusLine(facts).leading.last == .init("2 tunnels", .muted, symbol: "arrow.left.arrow.right"))
    }
}
