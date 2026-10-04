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
}
