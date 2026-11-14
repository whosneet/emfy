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

// MARK: - SecItem seam

/// A seam over the four `SecItem*` C functions so a test can simulate any
/// `OSStatus` — in particular `errSecMissingEntitlement` (-34018), which the
/// Developer ID / DMG build gets from the data-protection keychain because it
/// carries no keychain-access-group or application-identifier entitlement —
/// without a real Keychain and without a real key.
protocol SecItemPerforming: Sendable {
    func add(_ attributes: CFDictionary) -> OSStatus
    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

/// The production seam: the real `SecItem*` functions.
struct SystemSecItem: SecItemPerforming {
    func add(_ attributes: CFDictionary) -> OSStatus { SecItemAdd(attributes, nil) }
    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemCopyMatching(query, result)
    }
    func delete(_ query: CFDictionary) -> OSStatus { SecItemDelete(query) }
}

/// Remembers, for the lifetime of the process, that the macOS data-protection
/// keychain is unusable on this build: a Developer ID / DMG binary has no
/// keychain-access-group / application-identifier entitlement, so every
/// data-protection `SecItem` call returns `errSecMissingEntitlement` (-34018).
/// Once that is seen, operations go straight to the legacy file-based keychain
/// instead of paying for the failing call every time. Injectable so tests get a
/// fresh, isolated instance; the app shares one process-wide flag via `.shared`.
final class KeychainBackendState: @unchecked Sendable {
    static let shared = KeychainBackendState()
    private let lock = NSLock()
    private var unavailable = false

    var dataProtectionUnavailable: Bool {
        get { lock.lock(); defer { lock.unlock() }; return unavailable }
        set { lock.lock(); defer { lock.unlock() }; unavailable = newValue }
    }
}

// MARK: - Keychain store

/// The real store: `kSecClassGenericPassword`, device-only, not synchronised.
///
/// macOS has two keychains. The modern **data-protection** keychain
/// (`kSecUseDataProtectionKeychain`) gives file-protection semantics and takes
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, but it requires a
/// keychain entitlement the Developer ID / DMG build does not have; there it
/// returns -34018 (C6c2). The **legacy** file-based keychain needs no
/// entitlement; its items live in the login keychain, which unlocks at login
/// and is device-local (a generic password is never synced without
/// `kSecAttrSynchronizable`), so it ignores `kSecAttrAccessible`. We prefer
/// data-protection and fall back to legacy on -34018, remembering the fallback
/// for the process. iOS has only the data-protection keychain and is unchanged.
struct KeychainKeyStore: AIKeyStore {
    /// The shared service name for every Emfy AI key.
    static let service = "com.avneetsingh.emfy.ai"

    private let secItem: SecItemPerforming
    private let backendState: KeychainBackendState

    init(secItem: SecItemPerforming = SystemSecItem(),
         backendState: KeychainBackendState = .shared) {
        self.secItem = secItem
        self.backendState = backendState
    }

    /// The two macOS keychains. On iOS only `.dataProtection` is ever used.
    private enum Backend {
        case dataProtection
        case legacy
    }

    private enum ReadResult {
        case found(String)
        case notFound
        case failure(OSStatus)
    }

    private func baseQuery(for providerID: String, backend: Backend) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: providerID,
        ]
        #if os(macOS)
        if backend == .dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return query
    }

    /// Write attributes for a backend. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
    /// only means anything to the data-protection keychain; the legacy keychain
    /// ignores it (its login-keychain, at-login, device-local protection is the
    /// closest equivalent), so it is omitted there to keep the query clean.
    private func writeAttributes(data: Data, backend: Backend) -> [String: Any] {
        var attributes: [String: Any] = [kSecValueData as String: data]
        if backend == .dataProtection {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return attributes
    }

    // MARK: Backend selection with -34018 fallback

    /// Runs a write/delete op against the preferred backend, falling back to the
    /// legacy keychain on macOS when the data-protection keychain reports -34018.
    /// Returns the op's status and the backend that produced it.
    private func withBackend(_ op: (Backend) -> OSStatus) -> (status: OSStatus, backend: Backend) {
        #if os(macOS)
        if !backendState.dataProtectionUnavailable {
            let status = op(.dataProtection)
            if status != errSecMissingEntitlement { return (status, .dataProtection) }
            backendState.dataProtectionUnavailable = true
        }
        return (op(.legacy), .legacy)
        #else
        return (op(.dataProtection), .dataProtection)
        #endif
    }

    private func set(_ data: Data, for providerID: String, backend: Backend) -> OSStatus {
        // Atomic update-or-add (ST6): update the existing item IN PLACE, and only
        // add when there is none. A delete-then-add would leave a window where a
        // failed add wipes the key with nothing written back; an in-place update
        // that fails leaves the previous key intact and throws (surfaced, S-7).
        let query = baseQuery(for: providerID, backend: backend)
        let attributes = writeAttributes(data: data, backend: backend)
        let updateStatus = secItem.update(query as CFDictionary, attributes as CFDictionary)
        if updateStatus != errSecItemNotFound { return updateStatus }

        var add = query
        add.merge(attributes) { _, new in new }
        return secItem.add(add as CFDictionary)
    }

    private func copyKey(for providerID: String, backend: Backend) -> ReadResult {
        var query = baseQuery(for: providerID, backend: backend)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = secItem.copyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess else { return .failure(status) }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            return .failure(errSecDecode)
        }
        return .found(key)
    }

    // MARK: AIKeyStore

    func setKey(_ key: String, for providerID: String) throws {
        if key.isEmpty {
            try deleteKey(for: providerID)
            return
        }
        guard let data = key.data(using: .utf8) else { throw KeychainError(status: errSecParam) }

        let result = withBackend { set(data, for: providerID, backend: $0) }
        guard result.status == errSecSuccess else { throw KeychainError(status: result.status) }

        #if os(macOS)
        // Best-effort: clear any copy in the OTHER keychain (a pre-S3 legacy copy,
        // or a cross-build move) so a later read on either build never resolves to
        // a stale key. -34018 and "not found" are expected and ignored.
        let other: Backend = result.backend == .dataProtection ? .legacy : .dataProtection
        _ = secItem.delete(baseQuery(for: providerID, backend: other) as CFDictionary)
        #endif
    }

    func key(for providerID: String) throws -> String? {
        #if os(macOS)
        if !backendState.dataProtectionUnavailable {
            switch copyKey(for: providerID, backend: .dataProtection) {
            case .found(let key): return key
            case .notFound: break
            case .failure(let status) where status == errSecMissingEntitlement:
                backendState.dataProtectionUnavailable = true
            case .failure(let status): throw KeychainError(status: status)
            }
        }
        // The legacy keychain: the fallback backend, or a pre-S3 copy.
        switch copyKey(for: providerID, backend: .legacy) {
        case .found(let key):
            // Migrate into the data-protection keychain when it is available, so
            // later reads find it there; a no-op when it is unavailable.
            if !backendState.dataProtectionUnavailable { try? setKey(key, for: providerID) }
            return key
        case .notFound: return nil
        case .failure(let status): throw KeychainError(status: status)
        }
        #else
        switch copyKey(for: providerID, backend: .dataProtection) {
        case .found(let key): return key
        case .notFound: return nil
        case .failure(let status): throw KeychainError(status: status)
        }
        #endif
    }

    func deleteKey(for providerID: String) throws {
        #if os(macOS)
        // Delete from both keychains so no stale copy survives. -34018 flips the
        // process flag; "not found" is fine; any other status is a real failure.
        var hardError: OSStatus?
        for backend in [Backend.dataProtection, Backend.legacy] {
            if backend == .dataProtection && backendState.dataProtectionUnavailable { continue }
            let status = secItem.delete(baseQuery(for: providerID, backend: backend) as CFDictionary)
            if backend == .dataProtection && status == errSecMissingEntitlement {
                backendState.dataProtectionUnavailable = true
                continue
            }
            if status != errSecSuccess && status != errSecItemNotFound { hardError = status }
        }
        if let hardError { throw KeychainError(status: hardError) }
        #else
        let status = secItem.delete(baseQuery(for: providerID, backend: .dataProtection) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
        #endif
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
