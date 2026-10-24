import Foundation
import Testing

@testable import Vault

@Suite("Quick connect")
struct QuickConnectTests {
    /// The connection quick connect would save for `text`, or nil when it reads something else.
    private func connection(_ text: String) -> Connection? {
        guard case .success(let draft) = QuickConnect.draft(text) else { return nil }
        return try? draft.host().connection
    }

    @Test func itReadsAnSshCommandAsAShellWould() {
        let cases: [(String, Connection)] = [
            // Termius's own example, and ssh's: the port after the server or before it.
            ("ssh wrldjump@127.0.0.1 -p 2222", Connection(address: "127.0.0.1", user: "wrldjump", port: 2222)),
            ("ssh -p 2222 wrldjump@127.0.0.1", Connection(address: "127.0.0.1", user: "wrldjump", port: 2222)),
            ("ssh -p2222 -l wrldjump 127.0.0.1", Connection(address: "127.0.0.1", user: "wrldjump", port: 2222)),
            ("  ssh   nas.local  ", Connection(address: "nas.local")),
            ("ssh ubuntu@db:2222", Connection(address: "db", user: "ubuntu", port: 2222)),
            ("ssh ssh://ubuntu@db:2222/", Connection(address: "db", user: "ubuntu", port: 2222)),
            (
                "ssh -i /keys/ec2.pem ec2-user@10.0.0.9",
                Connection(address: "10.0.0.9", user: "ec2-user", identity: .keyFile("/keys/ec2.pem"))
            ),
            ("ssh root@fe80::1", Connection(address: "fe80::1", user: "root")),
            // Without the word ssh: one word, with a user or ssh:// in it.
            ("ubuntu@db", Connection(address: "db", user: "ubuntu")),
            ("ssh://db:2222", Connection(address: "db", port: 2222)),
        ]
        for (text, expected) in cases {
            #expect(connection(text) == expected, "\(text)")
        }
    }

    @Test func aKeyFileInHomeIsFoundThere() throws {
        let read = try #require(connection("ssh -i ~/.ssh/id_ed25519 db"))
        #expect(read.identity == .keyFile(NSHomeDirectory() + "/.ssh/id_ed25519"))
    }

    /// Anything else is a search, as it always was.
    @Test func otherQueriesAreLeftToSearch() {
        for text in ["", "ssh", "ssh   ", "prod-api", "split right", "ssh-agent", "sshd", "new tab"] {
            #expect(QuickConnect.draft(text) == nil, "\(text)")
        }
    }

    @Test func whatItCantTakeIsSaid() {
        let cases: [(String, QuickConnect.Problem)] = [
            ("ssh -L 8080:localhost:80 db", .option("-L")),
            ("ssh -v db", .option("-v")),
            ("ssh db -p", .missingValue("-p")),
            ("ssh -l", .missingValue("-l")),
            ("ssh db uptime", .command),
            ("ssh -p 2222", .draft(.noAddress)),
            ("ssh db -p 99999", .draft(.port)),
            ("ssh -l bob alice@db", .draft(.userInAddress)),
            ("ssh -p 22 db:2222", .draft(.portInAddress)),
            ("ssh 'db'", .draft(.address)),
            ("ssh db;reboot", .draft(.address)),
            ("o'brien@db", .draft(.user)),
        ]
        for (text, problem) in cases {
            #expect(QuickConnect.draft(text) == .failure(problem), "\(text)")
        }
        #expect(QuickConnect.Problem.option("-L").sentence.contains("-L"))
        #expect(QuickConnect.Problem.missingValue("-p").sentence == "-p needs the port after it.")
        #expect(QuickConnect.Problem.draft(.port).sentence == HostDraft.Problem.port.sentence)
    }

    @Test func aPlaceReadsAsSshWouldTakeIt() {
        #expect(QuickConnect.place(Connection(address: "db")) == "db")
        #expect(QuickConnect.place(Connection(address: "db", user: "ubuntu", port: 2222)) == "ubuntu@db:2222")
        #expect(QuickConnect.place(Connection(address: "fe80::1", port: 22)) == "[fe80::1]:22")
        #expect(QuickConnect.place(Connection(address: "fe80::1")) == "fe80::1")
    }

    /// Typing a host WRLD has opens that host instead of saving it again.
    @Test func aHostWRLDHasIsOpenedNotSavedAgain() throws {
        let api = WRLDHost(
            id: HostID(rawValue: "h1"), name: "prod-api",
            source: .wrld(Connection(address: "10.0.4.21", user: "ubuntu", port: 2222)))
        let nas = WRLDHost(id: HostID(rawValue: "h2"), name: "nas", source: .sshConfig(alias: "nas-999"))
        let behind = WRLDHost(
            id: HostID(rawValue: "h3"), name: "inner",
            source: .wrld(Connection(address: "10.0.9.9", jumpHostID: HostID(rawValue: "h1"))))
        let ci = WRLDHost(id: HostID(rawValue: "h4"), name: "ci", source: .wrld(Connection(address: "ci.example.com")))
        // As quick connect saves one: named after its address.
        let jump = WRLDHost(
            id: HostID(rawValue: "h5"), name: "127.0.0.1",
            source: .wrld(Connection(address: "127.0.0.1", user: "wrldjump", port: 2222)))
        let vault = Vault(hosts: [api, nas, behind, ci, jump])
        func found(_ text: String) throws -> HostRef? {
            guard case .success(let draft) = try #require(QuickConnect.draft(text)) else {
                Issue.record("\(text) didn't read")
                return nil
            }
            return QuickConnect.existing(for: draft, in: vault, aliases: ["nas-999", "pi"])
        }
        #expect(try found("ssh ubuntu@10.0.4.21 -p 2222") == .vault(api.id))
        #expect(try found("ubuntu@10.0.4.21:2222") == .vault(api.id))
        #expect(try found("ssh ubuntu@10.0.4.21 -p2222") == .vault(api.id))
        // Host names don't care about case.
        #expect(try found("ssh CI.Example.com") == .vault(ci.id))
        // A different user or port is a different way in.
        #expect(try found("ssh root@10.0.4.21 -p 2222") == nil)
        #expect(try found("ssh ubuntu@10.0.4.21") == nil)
        // Its name, or an alias, WRLD's or only ~/.ssh/config's.
        #expect(try found("ssh prod-api") == .vault(api.id))
        #expect(try found("ssh nas-999") == .vault(nas.id))
        #expect(try found("ssh pi") == .sshConfig(alias: "pi"))
        #expect(try found("ssh root@pi") == nil)
        // Reached through a jump host, it isn't the same as reached directly.
        #expect(try found("ssh 10.0.9.9") == nil)
        // A name that is only its address doesn't stand for the user and port saved with it.
        #expect(try found("ssh wrldjump@127.0.0.1 -p 2222") == .vault(jump.id))
        #expect(try found("ssh 127.0.0.1") == nil)
    }
}
