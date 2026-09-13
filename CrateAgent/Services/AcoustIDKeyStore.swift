import Foundation
import Security

/// Errors surfaced by `AcoustIDKeyStore` for genuine Keychain failures —
/// anything other than "no item found," which `load()` represents as `nil`
/// rather than an error.
public enum AcoustIDKeyStoreError: Error, Equatable {
    /// A `SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete` call returned a
    /// non-success, non-"not found" `OSStatus`. Carries the raw status so
    /// operators can look it up (e.g. `errSecMissingEntitlement`).
    case keychain(OSStatus)
    /// The item was found but its value could not be decoded as UTF-8.
    case invalidEncoding
}

/// Stores the user's AcoustID API key in the macOS login Keychain as a
/// generic-password item, keyed by `service`. The key is a secret and MUST
/// live only here — never in SQLite, the event log, UserDefaults, or logs.
///
/// `save` upserts (delete-then-add) so calling it twice never fails with
/// `errSecDuplicateItem`. `load` returns `nil` only when no item exists;
/// any other non-success status is a real failure and is thrown, never
/// silently treated as "no key" — hence `load`'s `throws -> String?`
/// signature rather than a plain `-> String?`.
public struct AcoustIDKeyStore {
    private let service: String

    public init(service: String = "com.crateagent.acoustid") {
        self.service = service
    }

    public func save(_ key: String) throws {
        guard let keyData = key.data(using: .utf8) else {
            throw AcoustIDKeyStoreError.invalidEncoding
        }

        // Upsert via delete-then-add: SecItemAdd fails with
        // errSecDuplicateItem if an item for this service already exists,
        // so a plain "save" call must always succeed regardless of
        // whether a previous key is already stored.
        let deleteStatus = SecItemDelete(query() as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw AcoustIDKeyStoreError.keychain(deleteStatus)
        }

        var addQuery = query()
        addQuery[kSecValueData as String] = keyData
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AcoustIDKeyStoreError.keychain(addStatus)
        }
    }

    public func load() throws -> String? {
        var readQuery = query()
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
        guard status != errSecItemNotFound else {
            return nil
        }
        guard status == errSecSuccess else {
            throw AcoustIDKeyStoreError.keychain(status)
        }

        guard let keyData = result as? Data, let key = String(data: keyData, encoding: .utf8) else {
            throw AcoustIDKeyStoreError.invalidEncoding
        }
        return key
    }

    public func delete() throws {
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AcoustIDKeyStoreError.keychain(status)
        }
    }

    private func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }
}
