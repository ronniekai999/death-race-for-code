import Foundation
import Testing
import Vault

@testable import AppCore

/// The board's vault: two Legends, Homelab and Work, a host in no group, keys and tunnels.
enum BoardVault {
    static let homelab = Group(id: GroupID(rawValue: "g1"), name: "Homelab")
    static let work = Group(id: GroupID(rawValue: "g2"), name: "Work")
    static let bastion = WRLDHost(
        id: HostID(rawValue: "h5"), name: "bastion",
        source: .wrld(Connection(address: "bastion.lan", user: "ops", identity: .secureEnclave(KeyID(rawValue: "k1")))),
        groupID: homelab.id)
    static let prodAPI = WRLDHost(
        id: HostID(rawValue: "h1"), name: "prod-api",
        source: .wrld(
            Connection(
                address: "10.0.4.21", user: "ubuntu", identity: .secureEnclave(KeyID(rawValue: "k1")),
                jumpHostID: bastion.id)),
        groupID: work.id, tags: ["prod"], isLegend: true,
        tunnels: [
            Tunnel(
                id: TunnelID(rawValue: "t1"),
                spec: TunnelSpec(kind: .local, listenPort: 5432, target: .init(host: "db", port: 5432)))
        ])
    static let nas = WRLDHost(
        id: HostID(rawValue: "h2"), name: "nas-999", source: .sshConfig(alias: "nas-999"), groupID: homelab.id,
        tags: ["homelab"], isLegend: true,
        tunnels: [Tunnel(id: TunnelID(rawValue: "t2"), spec: TunnelSpec(kind: .dynamic, listenPort: 1080))])
    static let piHole = WRLDHost(
        id: HostID(rawValue: "h3"), name: "pi-hole", source: .wrld(Connection(address: "192.168.12.2", user: "pi")),
        groupID: homelab.id)
    static let jellyfin = WRLDHost(
        id: HostID(rawValue: "h4"), name: "jellyfin",
        source: .wrld(
            Connection(address: "192.168.12.40", user: "media", identity: .keyFile("~/.ssh/id_ed25519"))),
        groupID: homelab.id)
    static let scratch = WRLDHost(
        id: HostID(rawValue: "h6"), name: "scratch", source: .wrld(Connection(address: "scratch.example.com")))
    static let deploy = Snippet(id: SnippetID(rawValue: "s1"), name: "deploy", text: "./deploy.sh {{env:prod|staging}}")

    static let vault = Vault(
        hosts: [prodAPI, nas, piHole, jellyfin, bastion, scratch], groups: [homelab, work], snippets: [deploy],
        keys: [
            Key(
                id: KeyID(rawValue: "k1"), kind: .secureEnclave, label: "Death Race", handle: "/k/k1",
                publicKey: "sk-ecdsa-sha2-nistp256@openssh.com AAAA Death Race")
        ])
}

@Suite("The WRLD board")
struct WRLDBoardTests {
    let vault = BoardVault.vault

    @Test func theListCountsEachPlace() {
        let hosts = WRLDBoard.hostRows(vault: vault)
        #expect(hosts.map(\.title) == ["All hosts", "Legends", "Homelab", "Work"])
        #expect(hosts.map(\.count) == [6, 2, 4, 1])
        let pages = WRLDBoard.vaultRows(vault: vault, knownHosts: 14)
        #expect(pages.map(\.title) == ["Keys", "Wishing Well", "Come & Go", "Known hosts"])
        #expect(pages.map(\.count) == [1, 1, 2, 14])
        #expect(WRLDBoard.summary(vault: vault) == "6 hosts · 1 key · 2 tunnels")
        #expect(WRLDBoard.summary(vault: Vault()) == "0 hosts")
    }

    @Test func allHostsShowsLegendsThenEachGroupThenTheRest() {
        let sections = WRLDBoard.cards(for: .allHosts, vault: vault)
        #expect(sections.map(\.title) == ["Legends", "Homelab", "Other hosts"])
        #expect(
            sections.map { $0.hosts.map(\.name) } == [
                ["prod-api", "nas-999"], ["pi-hole", "jellyfin", "bastion"], ["scratch"],
            ])
        // A group's own page shows its Legends too.
        #expect(WRLDBoard.cards(for: .group(BoardVault.homelab.id), vault: vault).first?.hosts.count == 4)
        #expect(WRLDBoard.cards(for: .legends, vault: vault).map(\.title) == ["Legends"])
        #expect(WRLDBoard.cards(for: .keys, vault: vault).isEmpty)
        // With nothing to tell apart, the heading is just "Hosts".
        let plain = Vault(hosts: [BoardVault.scratch])
        #expect(WRLDBoard.cards(for: .allHosts, vault: plain).map(\.title) == ["Hosts"])
    }

    // Section ids come from the place, not the title, so a group named like a built-in
    // heading doesn't collide and make SwiftUI drop a section.
    @Test func cardSectionIDsAreUniqueEvenWithACollidingGroupName() {
        let legendHost = WRLDHost(
            id: HostID(rawValue: "x1"), name: "a", source: .wrld(Connection(address: "a")), isLegend: true)
        let tricky = Group(id: GroupID(rawValue: "gX"), name: "Legends")
        let inGroup = WRLDHost(
            id: HostID(rawValue: "x2"), name: "b", source: .wrld(Connection(address: "b")), groupID: tricky.id)
        let board = Vault(hosts: [legendHost, inGroup], groups: [tricky])
        let sections = WRLDBoard.cards(for: .allHosts, vault: board)
        #expect(sections.map(\.title) == ["Legends", "Legends"])  // same title…
        #expect(Set(sections.map(\.id)).count == sections.count)  // …different ids
        #expect(sections.map(\.id) == ["legends", "group:gX"])
    }

    @Test func searchingFindsByAddressUserTagAndGroup() {
        func names(_ query: String) -> [String] {
            WRLDBoard.cards(for: .allHosts, vault: vault, query: query).flatMap { $0.hosts.map(\.name) }
        }
        #expect(names("192.168") == ["pi-hole", "jellyfin"])
        #expect(names("UBUNTU") == ["prod-api"])
        #expect(names("homelab") == ["nas-999", "pi-hole", "jellyfin", "bastion"])
        #expect(names("work prod") == ["prod-api"])
        #expect(names("nothing-like-it").isEmpty)
    }

    @Test func hostsFromSshConfigAreOfferedOnce() {
        let found = WRLDBoard.importable(
            aliases: ["nas-999", "github", "old-box", "github", "work-vm"], vault: vault, dismissed: ["old-box"])
        #expect(found == ["github", "work-vm"])
        #expect(WRLDBoard.importTitle(count: 12) == "Found 12 hosts in ~/.ssh/config")
        #expect(WRLDBoard.importTitle(count: 1) == "Found 1 host in ~/.ssh/config")
        let added = WRLDBoard.imported(found)
        #expect(added.map(\.name) == ["github", "work-vm"])
        #expect(added.map(\.source) == [.sshConfig(alias: "github"), .sshConfig(alias: "work-vm")])
    }
}

@Suite("A host's dot, line and chips")
struct HostStatusTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    @Test func timesSayHowLongAgo() {
        func ago(_ seconds: Double) -> String {
            RelativeTime.phrase(now.addingTimeInterval(-seconds), now: now, calendar: calendar)
        }
        #expect(ago(20) == "just now")
        // A date in the future (the clock moved back) isn't "just now": it shows as a date.
        #expect(ago(-300) == "on Sep 21")
        #expect(ago(4 * 60) == "4 min ago")
        #expect(ago(3_600) == "1 hour ago")
        #expect(ago(3 * 3_600) == "3 hours ago")
        #expect(ago(86_400) == "yesterday")
        #expect(ago(2 * 86_400) == "2 days ago")
        #expect(ago(8 * 86_400) == "1 week ago")
        #expect(ago(21 * 86_400) == "3 weeks ago")
        #expect(ago(60 * 86_400) == "on Jul 23")
        #expect(ago(400 * 86_400) == "on Aug 17, 2025")
    }

    @Test func theLineSaysWhatsKnown() {
        let checked = now.addingTimeInterval(-60)
        let answering = WRLDState.HostFacts(os: "Ubuntu 24.04", latency: 18, latencyCheckedAt: checked)
        let status = HostStatus(facts: answering, isConnected: false, now: now, calendar: calendar)
        #expect(status.dot == .answering)
        #expect(status.line == "18 ms · Ubuntu 24.04")
        #expect(status.meta == "18 ms")

        let silent = WRLDState.HostFacts(
            lastConnected: now.addingTimeInterval(-2 * 86_400), latencyCheckedAt: checked)
        let offline = HostStatus(facts: silent, isConnected: false, now: now, calendar: calendar)
        #expect(offline.dot == .silent)
        #expect(offline.line == "offline · last seen 2 days ago")
        #expect(offline.meta == "offline")

        let connected = HostStatus(
            facts: WRLDState.HostFacts(os: "TrueNAS"), isConnected: true, now: now, calendar: calendar)
        #expect(connected.dot == .connected)
        #expect(connected.line == "connected · TrueNAS")

        let seen = WRLDState.HostFacts(lastConnected: now.addingTimeInterval(-3 * 3_600))
        #expect(
            HostStatus(facts: seen, isConnected: false, now: now, calendar: calendar).line == "last seen 3 hours ago")
        let never = HostStatus(facts: WRLDState.HostFacts(), isConnected: false, now: now, calendar: calendar)
        #expect(never.dot == .unknown)
        #expect(never.line == "never connected")
        #expect(never.meta == nil)
    }

    @Test func chipsSayHowItSignsInAndIsReached() {
        let vault = BoardVault.vault
        #expect(
            HostChips.chips(for: BoardVault.prodAPI, in: vault).map(\.text)
                == ["Secure Enclave · Touch ID", "via bastion", "prod"])
        #expect(HostChips.chips(for: BoardVault.prodAPI, in: vault).first?.isKey == true)
        #expect(
            HostChips.chips(for: BoardVault.bastion, in: vault).map(\.text) == [
                "Secure Enclave · Touch ID", "jump host",
            ])
        #expect(HostChips.chips(for: BoardVault.jellyfin, in: vault).map(\.text) == ["ed25519"])
        #expect(HostChips.chips(for: BoardVault.nas, in: vault).map(\.text) == ["~/.ssh/config", "homelab"])
        #expect(
            HostChips.chips(for: BoardVault.piHole, in: vault, savedPassword: true).map(\.text)
                == ["password in Keychain"])
        #expect(HostChips.keyName("/Users/r/.ssh/id_rsa") == "rsa")
        #expect(HostChips.keyName("~/.ssh/id_ed25519_sk") == "ed25519 security key")
        #expect(HostChips.keyName("~/keys/deploy.pem") == "deploy.pem")
    }
}
