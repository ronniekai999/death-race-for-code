import Foundation
import PTYKit
import Testing
import Vault

@testable import SSHKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@Suite("Checking hosts by itself, and when it may")
struct HostChecksTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func legend(_ address: String, jump: HostID? = nil) -> WRLDHost {
        WRLDHost(name: "box", source: .wrld(Connection(address: address, jumpHostID: jump)), isLegend: true)
    }

    func due(_ host: WRLDHost, _ facts: WRLDState.HostFacts = .init(), visible: Bool = true, changed: Date? = nil)
        -> Bool
    {
        HostChecks.latencyIsDue(
            host, facts: facts, enabled: true, visible: visible, networkChangedAt: changed, now: now)
    }

    @Test func onlyLegendsWRLDReachesDirectlyAndOnlyWhileShown() {
        #expect(due(legend("10.0.4.21.example.com")))
        #expect(!due(legend("prod.example.com"), visible: false))
        #expect(
            !HostChecks.latencyIsDue(
                legend("prod.example.com"), facts: .init(), enabled: false, visible: true, networkChangedAt: nil,
                now: now))
        var plain = legend("prod.example.com")
        plain.isLegend = false
        #expect(!due(plain))
        #expect(!due(legend("prod.example.com", jump: HostID(rawValue: "h1"))))
        #expect(!due(WRLDHost(name: "nas-999", source: .sshConfig(alias: "nas-999"), isLegend: true)))
    }

    @Test func aLANHostWaitsUntilYouConnected() {
        #expect(!due(legend("192.168.12.2")))
        #expect(!due(legend("nas.local")))
        #expect(due(legend("192.168.12.2"), .init(lastConnected: now.addingTimeInterval(-86_400))))
    }

    @Test func fiveMinutesApartUnlessTheNetworkChanged() {
        let host = legend("prod.example.com")
        let recent = WRLDState.HostFacts(latency: 18, latencyCheckedAt: now.addingTimeInterval(-60))
        #expect(!due(host, recent))
        #expect(due(host, recent, changed: now.addingTimeInterval(-10)))
        #expect(!due(host, recent, changed: now.addingTimeInterval(-600)))
        #expect(due(host, WRLDState.HostFacts(latency: 18, latencyCheckedAt: now.addingTimeInterval(-301))))
    }

    @Test func theOSIsReadAfterASessionAtMostWeekly() {
        #expect(!HostChecks.osIsDue(facts: .init(), enabled: true, now: now))
        let connected = WRLDState.HostFacts(lastConnected: now)
        #expect(HostChecks.osIsDue(facts: connected, enabled: true, now: now))
        #expect(!HostChecks.osIsDue(facts: connected, enabled: false, now: now))
        var read = connected
        read.osReadAt = now.addingTimeInterval(-86_400)
        #expect(!HostChecks.osIsDue(facts: read, enabled: true, now: now))
        read.osReadAt = now.addingTimeInterval(-8 * 86_400)
        #expect(HostChecks.osIsDue(facts: read, enabled: true, now: now))
    }

    @Test func aListeningPortAnswersAndAClosedOneDoesnt() async throws {
        #if canImport(Darwin)
            let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0 && listen(fd, 4) == 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))

        let answer = await HostChecks.latency(host: "127.0.0.1", port: port, allowLocal: false)
        guard case .answered(let milliseconds) = answer else {
            Issue.record("expected an answer, got \(answer)")
            return
        }
        #expect((1...2_000).contains(milliseconds))
        close(fd)
        #expect(await HostChecks.latency(host: "127.0.0.1", port: port, allowLocal: false) == .silent)
    }

    @Test func aLANAddressIsNotTouchedWithoutLeave() async {
        // Skipped before any packet goes out, so no timeout is waited for.
        let start = Date()
        #expect(await HostChecks.latency(host: "10.255.255.1", port: 22, allowLocal: false) == .skipped)
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func theOSIsReadThroughTheMaster() async {
        let command = ["-F", "/x/ssh_config", "-T", "-o", "BatchMode=yes", "deathrace-prod-api", "cat /etc/os-release"]
        let runner = ScriptedRunner([
            command: .printing("NAME=\"Ubuntu\"\nVERSION_ID=\"24.04\"\nPRETTY_NAME=\"Ubuntu 24.04.1 LTS\"\n")
        ])
        let os = await HostChecks.readOS(
            alias: "deathrace-prod-api", config: "/x/ssh_config", runner: runner, environment: [:])
        #expect(os == "Ubuntu 24.04")
        #expect(
            await HostChecks.readOS(alias: "elsewhere", config: "/x/ssh_config", runner: runner, environment: [:])
                == nil)
    }
}
