import Foundation
import PTYKit
import Testing

@testable import SSHKit

/// sc_auth and ssh-keygen -K as far as Death Race sees them: identities sc_auth makes, and
/// the handle and .pub files ssh-keygen writes for each into the folder it runs in.
final class FakeKeyTools: ProcessRunner {
    private let state: Locked<(identities: [String], made: Int, refuse: String?, extra: Int)>

    /// `identities` are the base64 parts of keys already there. `refuse` makes sc_auth fail
    /// with that line; `extra` makes it add that many more identities than asked (another
    /// app making one at the same time).
    init(identities: [String] = [], refuse: String? = nil, extra: Int = 0) {
        state = Locked((identities, 0, refuse, extra))
    }

    func run(_ command: Command) async throws -> ChildResult {
        switch command.arguments.first {
        case SecureEnclaveKeys.scAuth:
            return state.withLock { state in
                if let refuse = state.refuse { return .failing(refuse + "\n") }
                for _ in 0...state.extra {
                    state.made += 1
                    state.identities.append("AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAI\(state.made)")
                }
                return .printing("")
            }
        case SecureEnclaveKeys.sshKeygen:
            let folder = try #require(command.workingDirectory)
            #expect(command.environment["SSH_ASKPASS_REQUIRE"] == "never")
            #expect(command.input == Array("\n".utf8))
            let identities = state.withLock { $0.identities }
            guard !identities.isEmpty else { return .failing("No keys to download\n") }
            for (index, blob) in identities.enumerated() {
                let name = folder + "/id_ecdsa_sk_rk_\(index)"
                try "handle \(blob)".write(toFile: name, atomically: true, encoding: .utf8)
                try "sk-ecdsa-sha2-nistp256@openssh.com \(blob) ssh:\n".write(
                    toFile: name + ".pub", atomically: true, encoding: .utf8)
            }
            return .printing("")
        default:
            return .failing("unexpected \(command.arguments)\n")
        }
    }

    var identities: [String] { state.withLock { $0.identities } }
}

@Suite("Secure Enclave keys")
struct SecureEnclaveKeysTests {
    let folder: String

    init() throws {
        folder = try shortTemporaryFolder()
    }

    func keys(_ tools: FakeKeyTools) -> SecureEnclaveKeys {
        let scratch = folder + "/scratch"
        return SecureEnclaveKeys(
            runner: tools, environment: ["PATH": "/usr/bin:/bin"], keysFolder: folder + "/keys",
            scratch: {
                let made = scratch + "-" + UUID().uuidString
                try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
                return made
            })
    }

    @Test func theNewKeyIsTheOneThatWasntThereBefore() async throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let tools = FakeKeyTools(identities: ["AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIold"])
        let created = try await keys(tools).create(label: "Death Race", fileName: "k1a2b3c4d")
        #expect(created.handle == folder + "/keys/k1a2b3c4d")
        #expect(
            created.publicKey == "sk-ecdsa-sha2-nistp256@openssh.com AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAI1 Death Race")
        #expect(
            try String(contentsOfFile: created.handle, encoding: .utf8)
                == "handle AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAI1")
        let mode = try FileManager.default.attributesOfItem(atPath: created.handle)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try String(contentsOfFile: created.handle + ".pub", encoding: .utf8) == created.publicKey + "\n")
        // No copies of handles stay in the scratch folders.
        let left = try FileManager.default.contentsOfDirectory(atPath: folder)
        #expect(left == ["keys"])
    }

    @Test func theFirstKeyEverWorksToo() async throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let created = try await keys(FakeKeyTools()).create(label: "Death Race", fileName: "k1")
        #expect(created.publicKey.hasSuffix("AAAAI1 Death Race"))
    }

    @Test func aRefusalOrAnUnclearResultSaysSo() async throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        await #expect(throws: SecureEnclaveKeys.Failure.notCreated("The user canceled the operation.")) {
            try await keys(FakeKeyTools(refuse: "The user canceled the operation.")).create(
                label: "Death Race", fileName: "k1")
        }
        // Two new keys at once: which one is ours can't be told.
        await #expect(throws: SecureEnclaveKeys.Failure.notFound) {
            try await keys(FakeKeyTools(extra: 1)).create(label: "Death Race", fileName: "k1")
        }
    }

    // MARK: - authorized_keys

    @Test func theInstallCommandIsTheSameToEveryShell() throws {
        let command = try AuthorizedKeys.installCommand(
            for: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample r@mac.local")
        #expect(
            command
                == "sh -c 'umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && { grep -qF \"AAAAC3NzaC1lZDI1NTE5AAAAIExample\" ~/.ssh/authorized_keys || echo \"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample r@mac.local\" >> ~/.ssh/authorized_keys; }'"
        )
        // A comment a shell could read as more loses those characters.
        let odd = try AuthorizedKeys.installCommand(
            for: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample it's $(rm -rf ~) `x` \"q\" \\ éclair")
        #expect(odd.contains("echo \"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample its rm -rf x q clair\""))
        #expect(!odd.dropFirst(7).dropLast().contains("'"))
        #expect(!odd.contains("\\"))
    }

    @Test func onlyAPublicKeyLineIsInstalled() {
        for line in [
            "", "ssh-ed25519", "ssh-ed25519 short", "ssh-ed25519 AAAA'injected'AAAAAAAAAAAA",
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5;rm", "ssh-$(id) AAAAC3NzaC1lZDI1NTE5AAAAIExample",
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExamplé",
        ] {
            #expect(throws: AuthorizedKeys.Failure.notAKey, "\(line)") { try AuthorizedKeys.installCommand(for: line) }
        }
    }
}
