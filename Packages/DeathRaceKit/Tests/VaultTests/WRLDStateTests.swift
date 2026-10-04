import Foundation
import Testing

@testable import Vault

@Suite("What WRLD learns as it's used")
struct WRLDStateTests {
    func folder() -> String {
        let path = NSTemporaryDirectory() + "wrld-state-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test func hostsAreKeptByIdOrConfigName() {
        let id = HostID(rawValue: "h0000abcd")
        #expect(WRLDState.key(for: .vault(id)) == "h0000abcd")
        #expect(WRLDState.key(for: .sshConfig(alias: "nas-999")) == "alias:nas-999")
        var state = WRLDState()
        let seen = Date(timeIntervalSince1970: 1_790_000_000)
        state.update(.vault(id)) { $0.lastConnected = seen }
        state.update(.vault(id)) { $0.os = "Ubuntu 24.04" }
        #expect(state.facts(.vault(id)) == WRLDState.HostFacts(lastConnected: seen, os: "Ubuntu 24.04"))
        #expect(state.facts(.sshConfig(alias: "other")) == WRLDState.HostFacts())
        state.used(SnippetID(rawValue: "s1"))
        state.used(SnippetID(rawValue: "s1"))
        #expect(state.uses(of: SnippetID(rawValue: "s1")) == 2)
        #expect(state.uses(of: SnippetID(rawValue: "s2")) == 0)
    }

    @Test func aHostThatDidntAnswerIsSilent() {
        let checked = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(!WRLDState.HostFacts().isSilent)
        #expect(!WRLDState.HostFacts(latency: 18, latencyCheckedAt: checked).isSilent)
        #expect(WRLDState.HostFacts(latencyCheckedAt: checked).isSilent)
    }

    @Test func itRoundTripsAndForgivesABadFile() throws {
        let path = folder() + "/state.json"
        let store = WRLDStateStore(path: path)
        #expect(store.load() == WRLDState())
        var state = WRLDState(dismissedImports: ["old-box"])
        state.update(.sshConfig(alias: "nas-999")) {
            $0.latency = 4
            $0.latencyCheckedAt = Date(timeIntervalSince1970: 1_790_000_123)
        }
        try store.save(state)
        #expect(store.load() == state)
        var info = stat()
        #expect(stat(path, &info) == 0 && info.st_mode & 0o777 == 0o600)

        // A cache: what can't be read is the same as nothing.
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: path))
        #expect(store.load() == WRLDState())
    }

    @Test func aNewerBuildsFileIsLeftAlone() throws {
        let path = folder() + "/state.json"
        let newer = #"{"version": 9, "hosts": {}, "snippetUses": {"s1": 5}}"#
        try Data(newer.utf8).write(to: URL(fileURLWithPath: path))
        let store = WRLDStateStore(path: path)
        #expect(store.load() == WRLDState())
        try store.save(WRLDState(snippetUses: ["s1": 1]))
        #expect(String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self) == newer)
    }
}
