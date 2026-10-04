import Foundation
import PTYKit
import Testing

@testable import SSHKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@Suite("Known hosts")
struct KnownHostsTests {
    static let keygen = access(KnownHosts.sshKeygen, X_OK) == 0
    static let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOEo6mvdbyKZDHXQGb7/OOZxNZl2dA3dJHf9E6yhu/5d"
    static let fingerprint = "SHA256:b9rtUahbU9QirWWFIitYkbDDHuvCHU6+OXSxJmDlylA"

    @Test func aListingIsReadLineByLine() {
        // As OpenSSH 9.6's ssh-keygen -l -f prints a plain file and a hashed one.
        let listing = """
            256 SHA256:b9rtUahbU9QirWWFIitYkbDDHuvCHU6+OXSxJmDlylA github.com,140.82.121.4 (ED25519)
            2048 SHA256:WFuZ8nLVIxRUj2cu5qLO23kU29O/Kq+SXtrKnSCioc4 [10.0.4.21]:2222 (RSA)
            256 SHA256:b9rtUahbU9QirWWFIitYkbDDHuvCHU6+OXSxJmDlylA |1|A7Du/PU+JLBQyKp/sE9S+80SRKI=|COQPR/z1a8x= (ED25519)
            not a key line
            """
        let entries = KnownHosts.parse(listing: listing)
        #expect(entries.count == 3)
        #expect(entries[0].hosts == ["github.com", "140.82.121.4"])
        #expect(entries[0].title == "github.com, 140.82.121.4")
        #expect(entries[0].type == "ED25519")
        #expect(entries[0].bits == 256)
        #expect(entries[0].fingerprint == Self.fingerprint)
        #expect(entries[1].hosts == ["[10.0.4.21]:2222"])
        #expect(entries[2].isHashed)
        #expect(entries[2].title == "A hashed name")
        #expect(Set(entries.map(\.id)).count == 3)
    }

    @Test func aLookupSaysWhichLine() {
        let found = """
            # Host [10.0.4.21]:2222 found: line 3
            [10.0.4.21]:2222 RSA SHA256:WFuZ8nLVIxRUj2cu5qLO23kU29O/Kq+SXtrKnSCioc4
            """
        #expect(
            KnownHosts.parse(found: found) == [
                .init(
                    hosts: ["[10.0.4.21]:2222"], type: "RSA",
                    fingerprint: "SHA256:WFuZ8nLVIxRUj2cu5qLO23kU29O/Kq+SXtrKnSCioc4", line: 3)
            ])
        #expect(KnownHosts.name(host: "10.0.4.21", port: 2222) == "[10.0.4.21]:2222")
        #expect(KnownHosts.name(host: "nas.local", port: 22) == "nas.local")
        #expect(KnownHosts.name(host: "nas.local", port: nil) == "nas.local")
    }

    @Test(.enabled(if: keygen)) func realSshKeygenListsFindsAndForgets() async throws {
        let folder = NSTemporaryDirectory() + "known-hosts-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/known_hosts"
        try Data("github.com,140.82.121.4 \(Self.key)\n[10.0.4.21]:2222 \(Self.key)\n".utf8)
            .write(to: URL(fileURLWithPath: path))
        let runner = SystemProcessRunner()
        let environment = ProcessInfo.processInfo.environment

        let all = await KnownHosts.list(path: path, runner: runner, environment: environment)
        #expect(all.map(\.hosts) == [["github.com", "140.82.121.4"], ["[10.0.4.21]:2222"]])
        #expect(all.allSatisfy { $0.fingerprint == Self.fingerprint })

        let found = await KnownHosts.find("[10.0.4.21]:2222", path: path, runner: runner, environment: environment)
        #expect(found.map(\.line) == [2])
        #expect(found.map(\.type) == ["ED25519"])

        try await KnownHosts.forget("github.com", path: path, runner: runner, environment: environment)
        let left = await KnownHosts.list(path: path, runner: runner, environment: environment)
        #expect(left.map(\.hosts) == [["[10.0.4.21]:2222"]])
        // A name it doesn't hold is no failure; something that isn't a name is refused.
        try await KnownHosts.forget("nothere", path: path, runner: runner, environment: environment)
        await #expect(throws: KnownHosts.Failure.self) {
            try await KnownHosts.forget("-f", path: path, runner: runner, environment: environment)
        }
        #expect(await KnownHosts.list(path: folder + "/none", runner: runner, environment: environment).isEmpty)
    }
}
