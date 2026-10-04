import Foundation
import SSHKit
import Testing

@testable import DeathRaceApp

@Suite("The Keychain and Touch ID")
struct KeychainTests {
    /// macos.yml sets this, with a throwaway keychain as the default: your own is never
    /// touched by a test run on your Mac.
    static let touchesTheKeychain = ProcessInfo.processInfo.environment["DEATHRACE_KEYCHAIN_TESTS"] == "1"

    @Test(.enabled(if: touchesTheKeychain)) func aSecretIsSavedReadReplacedAndDeleted() async throws {
        let store = KeychainSecretStore(service: "Death Race for Code tests \(UUID().uuidString)")
        let ref = SecretRef(.hostPassword, "h-test")
        defer { try? store.delete(ref) }
        #expect(!store.contains(ref))
        #expect(try await store.read(ref) == nil)

        try store.write("first", for: ref, label: "Password for test")
        #expect(store.contains(ref))
        #expect(try await store.read(ref) == "first")
        try store.write("second", for: ref, label: "Password for test")
        #expect(try await store.read(ref) == "second")
        // Each kind of secret is its own item.
        #expect(!store.contains(SecretRef(.keyPassphrase, "h-test")))

        try store.delete(ref)
        #expect(!store.contains(ref))
        try store.delete(ref)
    }

    @Test func accountsNameTheKindAndTheID() {
        let store = KeychainSecretStore()
        #expect(store.service == "Death Race for Code")
        #expect(store.account(for: SecretRef(.hostPassword, "h3f2a9c41")) == "password:h3f2a9c41")
        #expect(
            store.account(for: SecretRef(.keyPassphrase, "/Users/r/.ssh/id_ed25519"))
                == "passphrase:/Users/r/.ssh/id_ed25519")
    }

    @Test func askingWhetherTouchIDCanBeUsedShowsNothing() {
        // On a CI machine with no passcode this is false; either way it returns at once.
        _ = DeviceOwnerPresence.isAvailable
    }
}
