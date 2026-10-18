import Foundation
import Security

/// Errors surfaced by `AcoustIDKeyStore` for genuine Keychain failures —
/// anything other than "no item found," which `load()` represents as `nil`
/// rather than an error.
public enum AcoustIDKeyStoreError: LocalizedError, Equatable {
    /// A `SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete` call returned a
    /// non-success, non-"not found" `OSStatus`. Carries the raw status so
    /// operators can look it up (e.g. `errSecMissingEntitlement`).
    case keychain(OSStatus)
    /// The item was found but its value could not be decoded as UTF-8.
    case invalidEncoding

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            "The Keychain could not access the AcoustID key: \((SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)")."
        case .invalidEncoding:
            "The AcoustID key saved in the Keychain is not readable text. Enter the key again."
        }
    }
}

/// Stores the user's AcoustID API key in the macOS login Keychain as a
/// generic-password item, keyed by `service`. The key is a secret and MUST
/// live only here — never in SQLite, the event log, UserDefaults, or logs.
///
/// `save` upserts non-destructively (update-existing, add-if-missing) so
/// calling it twice never fails with `errSecDuplicateItem` and a failed
/// replacement never destroys the key that was already working. `load`
/// returns `nil` only when no item exists; any other non-success status is
/// a real failure and is thrown, never silently treated as "no key" —
/// hence `load`'s `throws -> String?` signature rather than a plain
/// `-> String?`.
public struct AcoustIDKeyStore: Sendable {
    private let service: String

    public init(service: String = "com.crateagent.acoustid") {
        self.service = service
    }

    public func save(_ key: String) throws {
        guard let keyData = key.data(using: .utf8) else {
            throw AcoustIDKeyStoreError.invalidEncoding
        }

        // Non-destructive upsert: try to update the existing item's value
        // in place first. Only when there is no existing item do we add a
        // new one. Deleting before the new value is confirmed written
        // would leave the user with NO key at all if the add/update step
        // then failed for any reason (a transient Keychain error, a
        // permissions prompt dismissal, etc.) — this way the prior,
        // working key survives any failure of this call.
        let updateStatus = SecItemUpdate(query() as CFDictionary, [kSecValueData as String: keyData] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw AcoustIDKeyStoreError.keychain(updateStatus)
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
