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
