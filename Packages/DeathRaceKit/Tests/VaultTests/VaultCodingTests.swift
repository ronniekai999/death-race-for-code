import Foundation
import Testing

@testable import Vault

private func json(_ vault: Vault) -> String {
    String(decoding: VaultStore.encode(vault), as: UTF8.self)
}

private func decode(_ text: String) throws -> Vault {
    try JSONDecoder().decode(Vault.self, from: Data(text.utf8))
}

/// A vault with one of everything.
func sampleVault() -> Vault {
    let key = Key(
        id: KeyID(rawValue: "k1"), kind: .secureEnclave, label: "Death Race", handle: "/Users/r/.deathrace/keys/se-k1",
        publicKey: "sk-ecdsa-sha2-nistp256@openssh.com AAAA ssh:")
    let homelab = Group(id: GroupID(rawValue: "g1"), name: "Homelab")
    let deploy = Snippet(id: SnippetID(rawValue: "s1"), name: "deploy", text: "./deploy.sh {{env:prod|staging}}")
    let bastion = WRLDHost(
        id: HostID(rawValue: "h1"), name: "bastion",
        source: .wrld(Connection(address: "bastion.lan", user: "ops", identity: .secureEnclave(key.id))))
    let prod = WRLDHost(
        id: HostID(rawValue: "h2"), name: "prod-api",
        source: .wrld(
            Connection(
                address: "10.0.4.21", user: "ubuntu", port: 2222, identity: .keyFile("~/.ssh/id_ed25519"),
                jumpHostID: bastion.id, forwardAgent: true)),
        groupID: homelab.id, tags: ["prod"], isLegend: true,
        tunnels: [
            Tunnel(
                id: TunnelID(rawValue: "t1"),
                spec: TunnelSpec(kind: .local, listenPort: 5432, target: .init(host: "db", port: 5432)),
                opensWithConnection: true),
            Tunnel(id: TunnelID(rawValue: "t2"), spec: TunnelSpec(kind: .dynamic, listenPort: 1080)),
        ],
        onConnectSnippetID: deploy.id)
    let nas = WRLDHost(
        id: HostID(rawValue: "h3"), name: "nas-999", source: .sshConfig(alias: "nas-999"), isLegend: true)
    return Vault(hosts: [bastion, prod, nas], groups: [homelab], snippets: [deploy], keys: [key])
}

@Suite("The vault's file")
struct VaultCodingTests {
    @Test func everythingRoundTrips() throws {
        let vault = sampleVault()
        #expect(try decode(json(vault)) == vault)
    }

    @Test func theFileReadsLikeAFileYouWouldWrite() throws {
        let text = json(sampleVault())
        // Ids are plain strings, a host is flat, defaults are left out.
        #expect(text.contains(#""id" : "h2""#))
        #expect(text.contains(#""address" : "10.0.4.21""#))
        #expect(text.contains(#""jumpHost" : "h1""#))
        #expect(text.contains(#""keyFile" : "~/.ssh/id_ed25519""#))
        #expect(text.contains(#""secureEnclave" : "k1""#))
        #expect(text.contains(#""sshConfigAlias" : "nas-999""#))
        #expect(text.contains(#""listen" : "5432""#))
        #expect(text.contains(#""target" : "db:5432""#))
        #expect(!text.contains("automatic"))
        #expect(!text.contains("rawValue"))
        #expect(!text.contains(#""spec""#))
        #expect(text.hasSuffix("}\n"))
        // Sorted keys, so the same vault always writes the same text.
        #expect(json(sampleVault()) == text)
    }

    @Test func aMinimalFileIsEnough() throws {
        let vault = try decode(
            #"{"hosts": [{"id": "h9", "name": "pi", "address": "192.168.12.2"}]}"#)
        #expect(vault.version == 1)
        #expect(vault.hosts.first?.connection == Connection(address: "192.168.12.2"))
        #expect(vault.hosts.first?.isLegend == false)
        #expect(vault.groups.isEmpty && vault.snippets.isEmpty && vault.keys.isEmpty)
    }

    @Test func unknownFieldsAreIgnored() throws {
        let vault = try decode(
            #"{"version": 1, "future": true, "hosts": [{"id": "h9", "name": "pi", "address": "pi.local", "color": "pink"}]}"#
        )
        #expect(vault.hosts.count == 1)
    }

    // A field a hand edit spelled in the wrong case would be ignored and then erased on the
    // next save, losing what it held. It's refused instead, so the file is left alone.
    @Test func aMisspelledFieldIsRefusedRatherThanErased() {
        // "Hosts" for "hosts" would hide every host.
        #expect(throws: DecodingError.self) {
            try decode(#"{"version": 1, "Hosts": [{"id": "h1", "name": "pi", "address": "pi.local"}]}"#)
        }
        // "jumphost" for "jumpHost" would connect directly, skipping the bastion.
        #expect(throws: DecodingError.self) {
            try decode(
                #"{"version": 1, "hosts": [{"id": "h1", "name": "pi", "address": "pi.local", "jumphost": "h2"}]}"#)
        }
    }

    // Two records sharing an id make a remove delete both and an edit touch the wrong one.
    @Test func duplicateIDsAreRefused() {
        #expect(throws: DecodingError.self) {
            try decode(
                #"{"version": 1, "hosts": [{"id": "h1", "name": "a", "address": "a"}, {"id": "h1", "name": "b", "address": "b"}]}"#
            )
        }
        // Across hosts, tunnel ids must be unique too. The tunnels here are well-formed, so
        // the only thing wrong is the shared id.
        let twoHostsOneTunnelEach = """
            {"version": 1, "hosts": [
              {"id": "h1", "name": "a", "address": "a", "tunnels": [{"id": "ID", "kind": "local", "listen": "5432", "target": "db:5432"}]},
              {"id": "h2", "name": "b", "address": "b", "tunnels": [{"id": "ID", "kind": "local", "listen": "5433", "target": "db:5433"}]}
            ]}
            """
        #expect(throws: DecodingError.self) {
            try decode(twoHostsOneTunnelEach.replacingOccurrences(of: "ID", with: "t1"))
        }
        // Distinct ids decode cleanly, proving it was the duplicate that was refused.
        let distinct = """
            {"version": 1, "hosts": [
              {"id": "h1", "name": "a", "address": "a", "tunnels": [{"id": "t1", "kind": "local", "listen": "5432", "target": "db:5432"}]},
              {"id": "h2", "name": "b", "address": "b", "tunnels": [{"id": "t2", "kind": "local", "listen": "5433", "target": "db:5433"}]}
            ]}
            """
        #expect(throws: Never.self) { try decode(distinct) }
    }

    @Test func identitiesTakeTheirThreeShapes() throws {
        for (text, identity) in [
            (#""automatic""#, Connection.Identity.automatic),
            (#"{"secureEnclave": "k2"}"#, .secureEnclave(KeyID(rawValue: "k2"))),
            (#"{"keyFile": "/k"}"#, .keyFile("/k")),
        ] {
            let vault = try decode(#"{"hosts": [{"id": "h", "name": "x", "address": "x", "identity": \#(text)}]}"#)
            #expect(vault.hosts.first?.connection?.identity == identity)
        }
        #expect(throws: DecodingError.self) {
            try decode(#"{"hosts": [{"id": "h", "name": "x", "address": "x", "identity": "password"}]}"#)
        }
        #expect(throws: DecodingError.self) {
            try decode(#"{"hosts": [{"id": "h", "name": "x", "address": "x", "identity": {}}]}"#)
        }
    }

    @Test func aTunnelThatWouldMisleadSshIsRefused() {
        for tunnel in [
            #"{"id": "t", "kind": "local", "listen": "99999", "target": "db:5432"}"#,
            #"{"id": "t", "kind": "local", "listen": "5432", "target": "-oProxyCommand=x:5432"}"#,
            #"{"id": "t", "kind": "local", "listen": "5432"}"#,
            #"{"id": "t", "kind": "sideways", "listen": "5432", "target": "db:5432"}"#,
        ] {
            #expect(throws: DecodingError.self) {
                try decode(#"{"hosts": [{"id": "h", "name": "x", "address": "x", "tunnels": [\#(tunnel)]}]}"#)
            }
        }
    }

    @Test func newIdsHaveTheirKindsLetter() {
        let host = HostID.make()
        #expect(host.rawValue.hasPrefix("h"))
        #expect(host.rawValue.count == 9)
        #expect(host.rawValue.dropFirst().allSatisfy { $0.isHexDigit })
        #expect(SnippetID.make().rawValue.hasPrefix("s"))
        #expect(HostID.make() != HostID.make())
    }

    @Test func lookupsFindByID() {
        let vault = sampleVault()
        #expect(vault.host(HostID(rawValue: "h3"))?.sshConfigAlias == "nas-999")
        #expect(vault.group(GroupID(rawValue: "g1"))?.name == "Homelab")
        #expect(vault.snippet(SnippetID(rawValue: "s1"))?.template.placeholders.first?.name == "env")
        #expect(vault.key(KeyID(rawValue: "k1"))?.kind == .secureEnclave)
        #expect(vault.host(HostID(rawValue: "nope")) == nil)
    }
}
