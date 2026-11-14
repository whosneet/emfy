import Foundation
import Security

// MARK: - API key storage (A2a)
//
// API keys live ONLY in the Keychain (CLAUDE.md §8 / A2a brief): a generic
// password per provider id, device-only, never synced, never in UserDefaults,
// never logged, never in a crash or diagnostic report. `AIKeyStore` is a narrow
// seam over SecItem so tests round-trip without touching the real Keychain and
// without any real key.

/// A store for per-provider API keys. The only place a key is ever held at rest.
protocol AIKeyStore: Sendable {
    /// Stores (or replaces) the key for a provider id. An empty string deletes it.
    func setKey(_ key: String, for providerID: String) throws
    /// The stored key for a provider id, or nil if none.
    func key(for providerID: String) throws -> String?
    /// Deletes the key for a provider id (no error if absent).
    func deleteKey(for providerID: String) throws
}

/// A failure from the Keychain, carrying the OSStatus but never the key.
struct KeychainError: Error, Equatable {
    var status: OSStatus
}

/// The real store: `kSecClassGenericPassword`, device-only, not synchronised.
struct KeychainKeyStore: AIKeyStore {
    /// The shared service name for every Emfy AI key.
    static let service = "com.avneetsingh.emfy.ai"

    /// The item query. On macOS it selects the modern data-protection keychain
    /// (`kSecUseDataProtectionKeychain`), which gives API keys file-protection semantics
    /// instead of the legacy file-based keychain (S3); `dataProtection: false` reproduces
    /// the pre-S3 query so an existing key can be read and migrated. On iOS the
    /// data-protection keychain is always used, so the attribute is omitted.
    private func baseQuery(for providerID: String, dataProtection: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: providerID,
        ]
        #if os(macOS)
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return query
    }

    func setKey(_ key: String, for providerID: String) throws {
        if key.isEmpty {
            try deleteKey(for: providerID)
            return
        }
        guard let data = key.data(using: .utf8) else { throw KeychainError(status: errSecParam) }
        #if os(macOS)
        // Clear any pre-S3 legacy-keychain copy so a later read never resolves to a stale
        // key there (best effort; the data-protection item below is the source of truth).
        SecItemDelete(baseQuery(for: providerID, dataProtection: false) as CFDictionary)
        #endif
        // Atomic update-or-add (ST6): update the existing data-protection item IN PLACE,
        // and only add when there is none. The old delete-then-add left a window where a
        // failed add would wipe the key with nothing written back; an update that fails
        // leaves the previous key intact and throws, which the UI surfaces (S-7).
        let query = baseQuery(for: providerID)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError(status: updateStatus) }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    func key(for providerID: String) throws -> String? {
        if let key = try copyKey(for: providerID, dataProtection: true) { return key }
        #if os(macOS)
        // Migrate a key written by a pre-S3 build into the legacy keychain: read it, then
        // rewrite it into the data-protection keychain so later reads find it there (S3).
        if let legacy = try copyKey(for: providerID, dataProtection: false) {
            try? setKey(legacy, for: providerID)
            return legacy
        }
        #endif
        return nil
    }

    private func copyKey(for providerID: String, dataProtection: Bool) throws -> String? {
        var query = baseQuery(for: providerID, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return key
    }

    func deleteKey(for providerID: String) throws {
        let status = SecItemDelete(baseQuery(for: providerID) as CFDictionary)
        #if os(macOS)
        // Also clear any pre-S3 legacy-keychain copy (best effort).
        SecItemDelete(baseQuery(for: providerID, dataProtection: false) as CFDictionary)
        #endif
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

/// An in-memory key store for tests (the SecItem seam). Never used in the app.
final class InMemoryKeyStore: AIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: String] = [:]

    init() {}

    func setKey(_ key: String, for providerID: String) throws {
        lock.lock(); defer { lock.unlock() }
        if key.isEmpty { store[providerID] = nil } else { store[providerID] = key }
    }

    func key(for providerID: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return store[providerID]
    }

    func deleteKey(for providerID: String) throws {
        lock.lock(); defer { lock.unlock() }
        store[providerID] = nil
    }
}
