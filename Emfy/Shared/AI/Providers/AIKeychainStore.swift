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

    private func baseQuery(for providerID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: providerID,
        ]
    }

    func setKey(_ key: String, for providerID: String) throws {
        if key.isEmpty {
            try deleteKey(for: providerID)
            return
        }
        guard let data = key.data(using: .utf8) else { throw KeychainError(status: errSecParam) }
        // Replace: delete any existing item, then add a fresh one with the
        // device-only, after-first-unlock accessibility the brief requires.
        SecItemDelete(baseQuery(for: providerID) as CFDictionary)
        var add = baseQuery(for: providerID)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func key(for providerID: String) throws -> String? {
        var query = baseQuery(for: providerID)
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
