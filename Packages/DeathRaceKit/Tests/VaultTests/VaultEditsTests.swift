import Testing

@testable import Vault

@Suite("Changing WRLD")
struct VaultEditsTests {
    let bastion = WRLDHost(
        id: HostID(rawValue: "h1"), name: "bastion", source: .wrld(Connection(address: "bastion.lan")))
    let homelab = Group(id: GroupID(rawValue: "g1"), name: "Homelab")
    let tmux = Snippet(id: SnippetID(rawValue: "s1"), name: "tmux", text: "tmux new -A -s main")

    func vault() -> Vault {
        let prod = WRLDHost(
            id: HostID(rawValue: "h2"), name: "prod-api",
            source: .wrld(Connection(address: "10.0.4.21", jumpHostID: bastion.id)), groupID: homelab.id,
            tunnels: [
                Tunnel(
                    id: TunnelID(rawValue: "t1"),
                    spec: TunnelSpec(kind: .local, listenPort: 5432, target: .init(host: "db", port: 5432)))
            ], onConnectSnippetID: tmux.id)
        return Vault(hosts: [bastion, prod], groups: [homelab], snippets: [tmux])
    }

    @Test func removingAJumpHostLeavesItsHostsConnectingDirectly() {
        var vault = vault()
        #expect(vault.hosts(jumpingThrough: bastion.id).map(\.name) == ["prod-api"])
        vault.removeHost(bastion.id)
        #expect(vault.hosts.map(\.name) == ["prod-api"])
        #expect(vault.hosts[0].connection?.jumpHostID == nil)
        #expect(vault.hosts[0].connection?.address == "10.0.4.21")
    }

    @Test func aHostCantJumpThroughItselfOrALoop() {
        var vault = vault()
        let prod = HostID(rawValue: "h2")
        // prod-api jumps through bastion: bastion can't jump through prod-api.
        #expect(vault.jumpChoices(for: bastion.id).map(\.name).isEmpty)
        #expect(vault.jumpChoices(for: prod).map(\.name) == ["bastion"])
        #expect(vault.jumpChoices(for: nil).map(\.name) == ["bastion", "prod-api"])
        vault.importAliases(["nas-999"])
        // A host from ~/.ssh/config is reached as that file says: not a choice.
        #expect(vault.jumpChoices(for: nil).count == 2)
    }

    @Test func theInspectorEditsHowAHostIsReachedAndKeepsTheRest() throws {
        let vault = vault()
        let prod = try #require(vault.host(HostID(rawValue: "h2")))
        var draft = try #require(HostDraft(editing: prod))
        #expect(draft.address == "10.0.4.21")
        #expect(draft.jumpHostID == bastion.id)
        draft.address = "10.0.4.22"
        draft.port = "2222"
        draft.signIn = .secureEnclaveKey(KeyID(rawValue: "k1"))
        let edited = try draft.applied(to: prod)
        #expect(edited.id == prod.id)
        #expect(edited.connection?.address == "10.0.4.22")
        #expect(edited.connection?.port == 2222)
        #expect(edited.connection?.identity == .secureEnclave(KeyID(rawValue: "k1")))
        #expect(edited.tunnels == prod.tunnels)
        #expect(edited.groupID == prod.groupID)
        #expect(edited.onConnectSnippetID == prod.onConnectSnippetID)
        draft.port = "99999"
        #expect(throws: HostDraft.Problem.port) { try draft.applied(to: prod) }
        #expect(HostDraft(editing: WRLDHost(name: "nas", source: .sshConfig(alias: "nas"))) == nil)
    }

    @Test func hostsArePinnedChangedAndImported() {
        var vault = vault()
        vault.setLegend(bastion.id, true)
        #expect(vault.host(bastion.id)?.isLegend == true)
        var renamed = vault.host(bastion.id)!
        renamed.name = "jump"
        vault.update(renamed)
        #expect(vault.host(bastion.id)?.name == "jump")
        vault.update(WRLDHost(name: "stranger", source: .sshConfig(alias: "stranger")))
        #expect(vault.hosts.count == 2)
        vault.importAliases(["nas-999", "github", "nas-999"])
        vault.importAliases(["github"])
        #expect(vault.hosts.compactMap(\.sshConfigAlias) == ["nas-999", "github"])
    }

    @Test func groupsComeAndGoWithoutTakingTheirHosts() {
        var vault = vault()
        #expect(vault.addGroup(named: " homelab ") == homelab.id)
        let work = vault.addGroup(named: "Work")
        #expect(vault.groups.map(\.name) == ["Homelab", "Work"])
        vault.move(bastion.id, to: work)
        #expect(vault.host(bastion.id)?.groupID == work)
        vault.move(bastion.id, to: GroupID(rawValue: "g-gone"))
        #expect(vault.host(bastion.id)?.groupID == work)
        vault.renameGroup(work, to: "  ")
        vault.renameGroup(work, to: "Day job")
        #expect(vault.group(work)?.name == "Day job")
        vault.removeGroup(homelab.id)
        #expect(vault.groups.map(\.name) == ["Day job"])
        #expect(vault.hosts.map(\.groupID) == [work, nil])
    }

    @Test func tunnelsAreCheckedBeforeTheyreAdded() throws {
        var vault = vault()
        let spec = TunnelSpec(kind: .local, listenPort: 6379, target: .init(host: "cache", port: 6379))
        try vault.addTunnel(Tunnel(id: TunnelID(rawValue: "t2"), spec: spec), to: bastion.id)
        #expect(vault.host(holding: TunnelID(rawValue: "t2"))?.name == "bastion")
        // Two tunnels on one port of this Mac couldn't be open together.
        let clash = TunnelSpec(kind: .dynamic, listenPort: 5432)
        #expect(throws: Vault.TunnelProblem.clash(with: "5432 → db:5432 · Local · through prod-api")) {
            try vault.addTunnel(Tunnel(spec: clash), to: bastion.id)
        }
        // A remote one listens on its server, so another server's port is no clash.
        let remote = TunnelSpec(kind: .remote, listenPort: 5432, target: .init(host: "localhost", port: 3000))
        try vault.addTunnel(Tunnel(id: TunnelID(rawValue: "t3"), spec: remote), to: bastion.id)
        #expect(throws: Vault.TunnelProblem.self) {
            try vault.addTunnel(Tunnel(spec: remote), to: bastion.id)
        }
        let broken = TunnelSpec(kind: .local, listenPort: 70_000, target: .init(host: "db", port: 1))
        #expect(throws: Vault.TunnelProblem.spec(.port("70000"))) {
            try vault.addTunnel(Tunnel(spec: broken), to: bastion.id)
        }
        #expect(Vault.TunnelProblem.spec(.missingTarget).sentence == "Say where it forwards to, as host:port.")

        vault.setOpensWithConnection(TunnelID(rawValue: "t2"), true)
        #expect(vault.host(bastion.id)?.tunnels.first?.opensWithConnection == true)
        vault.removeTunnel(TunnelID(rawValue: "t2"))
        #expect(vault.host(holding: TunnelID(rawValue: "t2")) == nil)
    }

    @Test func removingASnippetTakesItOffItsHosts() {
        var vault = vault()
        #expect(vault.hosts(runningOnConnect: tmux.id).map(\.name) == ["prod-api"])
        var edited = tmux
        edited.text = "tmux new -A -s work"
        vault.save(edited)
        vault.save(Snippet(name: "uptime", text: "uptime"))
        #expect(vault.snippets.map(\.text) == ["tmux new -A -s work", "uptime"])
        vault.removeSnippet(tmux.id)
        #expect(vault.snippets.map(\.name) == ["uptime"])
        #expect(vault.hosts.allSatisfy { $0.onConnectSnippetID == nil })
    }
}
