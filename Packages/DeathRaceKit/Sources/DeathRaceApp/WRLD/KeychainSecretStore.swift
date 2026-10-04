import Foundation
import SSHKit
import Security

/// Saved passwords and passphrases, as generic passwords in your login keychain.
///
/// Not the data-protection keychain: that needs the restricted keychain-access-groups
/// entitlement and a provisioning profile. An item in the login keychain trusts the app that
/// saved it, by its signature, so Death Race reads its own items without asking and any
/// other app is asked first. Death Race itself asks for Touch ID before it uses one
/// (`DeviceOwnerPresence`).
///
/// The trust survives rebuilds only when bundle.sh signs with the same Apple Development
/// identity: an ad-hoc signature changes with every build, and macOS then asks before each
/// read.
public struct KeychainSecretStore: SecretStore {
    public static let standardService = "Death Race for Code"
    /// Every item's service; tests use one of their own.
    public let service: String

    public init(service: String = Self.standardService) {
        self.service = service
    }

    /// "password:h3f2a9c41" or "passphrase:/Users/r/.ssh/id_ed25519".
    func account(for ref: SecretRef) -> String { "\(ref.kind.rawValue):\(ref.id)" }

    private func query(for ref: SecretRef) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: ref),
            kSecUseDataProtectionKeychain as String: false,
        ]
    }

    public func contains(_ ref: SecretRef) -> Bool {
        var query = query(for: ref)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Attributes only: reading them never asks.
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Runs on a thread of its own: macOS may hold the read while it asks you to allow it.
    public func read(_ ref: SecretRef) async throws -> String? {
        var query = query(for: ref)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        let request = KeychainQuery(query)
        let (status, data) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var result: CFTypeRef?
                let status = SecItemCopyMatching(request.dictionary as CFDictionary, &result)
                continuation.resume(returning: (status, result as? Data))
            }
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return data.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Saves `secret`, replacing what was saved for `ref`. `label` is what Keychain Access
    /// shows: "Password for prod-api".
    ///
    /// Deletes any existing item first, then adds, so the item is created with *our* access
    /// control. Updating in place would keep the access control an item already had — and if
    /// another app running as this user pre-created one with the same service and account and
    /// a permissive list, our password would be readable by it. When the existing item can't
    /// be deleted (it's one we don't control), fall back to updating in place rather than
    /// prompting.
    public func write(_ secret: String, for ref: SecretRef, label: String) throws {
        let data = Data(secret.utf8)
        var item = query(for: ref)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = label
        item[kSecAttrDescription as String] = "Death Race for Code"
        let deleted = SecItemDelete(query(for: ref) as CFDictionary)
        if deleted == errSecSuccess || deleted == errSecItemNotFound {
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        } else {
            let changes: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
            let status = SecItemUpdate(query(for: ref) as CFDictionary, changes as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    }

    public func delete(_ ref: SecretRef) throws {
        let status = SecItemDelete(query(for: ref) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// A query handed to the thread that runs it; built and read only there and here.
private struct KeychainQuery: @unchecked Sendable {
    let dictionary: [String: Any]

    init(_ dictionary: [String: Any]) { self.dictionary = dictionary }
}

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public let status: OSStatus

    public var description: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "The Keychain said \(status)."
    }
}
