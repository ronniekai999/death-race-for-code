import Testing

@testable import Vault

@Suite("The New Host sheet's fields")
struct HostDraftTests {
    @Test func theFieldsMakeAHost() throws {
        let jump = HostID(rawValue: "h-bastion")
        let draft = HostDraft(
            name: " prod-api ", address: " 10.0.4.21", user: "ubuntu ", port: "2222", jumpHostID: jump)
        let host = try draft.host(id: HostID(rawValue: "h1"))
        #expect(host.name == "prod-api")
        #expect(
            host.source
                == .wrld(Connection(address: "10.0.4.21", user: "ubuntu", port: 2222, jumpHostID: jump)))
    }

    @Test func blanksAreLeftToSsh() throws {
        let host = try HostDraft(address: "nas.local").host(id: HostID(rawValue: "h1"))
        #expect(host.name == "nas.local")
        #expect(host.source == .wrld(Connection(address: "nas.local")))
    }

    @Test func aNewSecureEnclaveKeySignsInAsUsualUntilItsOnTheServer() throws {
        let host = try HostDraft(address: "nas.local", signIn: .newSecureEnclaveKey).host()
        #expect(host.connection?.identity == .automatic)
        let file = try HostDraft(address: "nas.local", signIn: .keyFile("/Users/r/.ssh/id_ed25519")).host()
        #expect(file.connection?.identity == .keyFile("/Users/r/.ssh/id_ed25519"))
    }

    @Test func whatsWrongIsSaid() {
        let cases: [(HostDraft, HostDraft.Problem)] = [
            (HostDraft(address: "  "), .noAddress),
            (HostDraft(address: "db prod"), .address),
            (HostDraft(address: "-oProxyCommand=x"), .address),
            (HostDraft(address: "db\nProxyCommand x"), .address),
            (HostDraft(address: "ubuntu@db", user: "root"), .userInAddress),
            (HostDraft(address: "@db"), .user),
            (HostDraft(address: "ubuntu@"), .noAddress),
            (HostDraft(address: "db:2222", port: "22"), .portInAddress),
            (HostDraft(address: "[fe80::1]:2222", port: "22"), .portInAddress),
            (HostDraft(address: "db:0"), .port),
            (HostDraft(address: "db:"), .port),
            (HostDraft(address: "db:ssh"), .port),
            (HostDraft(address: "ubuntu@db:"), .port),
            (HostDraft(address: "[fe80::1"), .address),
            (HostDraft(address: "db", user: "o'brien"), .user),
            (HostDraft(address: "db", port: "0"), .port),
            (HostDraft(address: "db", port: "65536"), .port),
            (HostDraft(address: "db", port: "22a"), .port),
            (HostDraft(address: "db", port: "２２"), .port),
            (HostDraft(address: "db", signIn: .keyFile("")), .keyFile),
            (HostDraft(address: "db", signIn: .keyFile("/x\"y")), .keyFile),
        ]
        for (draft, problem) in cases {
            #expect(throws: problem, "\(draft)") { try draft.host() }
        }
        #expect(HostDraft.Problem.port.sentence == "A port is a number from 1 to 65535.")
    }

    /// ssh's own `user@host:port` in Address fills User and Port, as typed or pasted from a
    /// shell; a field that agrees with it is no contradiction.
    @Test func sshsOwnAddressFillsUserAndPort() throws {
        let cases: [(HostDraft, Connection)] = [
            (HostDraft(address: "ubuntu@db"), Connection(address: "db", user: "ubuntu")),
            (
                HostDraft(address: " wrldjump@127.0.0.1:2222 "),
                Connection(address: "127.0.0.1", user: "wrldjump", port: 2222)
            ),
            (HostDraft(address: "db:2222", port: "2222"), Connection(address: "db", port: 2222)),
            (HostDraft(address: "ubuntu@db", user: "ubuntu"), Connection(address: "db", user: "ubuntu")),
            (HostDraft(address: "root@[fe80::1]:2222"), Connection(address: "fe80::1", user: "root", port: 2222)),
            // An identity provider's login holds an @ of its own; the host follows the last.
            (HostDraft(address: "r@corp.example@bastion"), Connection(address: "bastion", user: "r@corp.example")),
        ]
        for (draft, connection) in cases {
            #expect(try draft.host().source == .wrld(connection), "\(draft)")
        }
        // A blank name takes the address without its user or port.
        #expect(try HostDraft(address: "ubuntu@db:2222").host().name == "db")
    }

    @Test func anIPv6AddressIsTakenBareOrInBrackets() throws {
        #expect(try HostDraft(address: "fe80::1").host().connection?.address == "fe80::1")
        #expect(try HostDraft(address: "fe80::22").host().connection?.address == "fe80::22")
        #expect(try HostDraft(address: " [2001:db8::7] ").host().connection?.address == "2001:db8::7")
    }
}
