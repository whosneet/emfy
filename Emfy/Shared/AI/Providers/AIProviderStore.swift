import Foundation
import Observation

// MARK: - Configured-provider store (A2b)
//
// The @Observable store behind Settings ▸ AI: the list of configured providers, the
// selected engine, and the third-party auto-titling opt-in. Provider configs (no
// secrets) persist in UserDefaults; keys live only in the Keychain and consent in
// its own store, both reached through `AIProviderService` so the consent gate is
// never bypassed. Injected into the SwiftUI environment on both platforms; tests
// construct one with throwaway defaults and in-memory key/consent stores.

@MainActor
@Observable
final class AIProviderStore {
    /// The shared app instance (standard defaults, real Keychain and consent store).
    static let shared = AIProviderStore()

    @ObservationIgnored private let defaults: UserDefaults
    /// The consent-gated router every send goes through.
    @ObservationIgnored let service: AIProviderService
    @ObservationIgnored private let keyStore: AIKeyStore
    @ObservationIgnored private let consentStore: AIConsentStore
    @ObservationIgnored private let sessionFactory: @Sendable () -> URLSession

    /// The configured providers, in display order. Persisted as JSON (no secrets).
    private(set) var providers: [AIProviderConfig] {
        didSet { persistProviders() }
    }
    /// The selected engine id: `AIEngineSelection.appleID` or a provider's id.
    var selectedEngineID: String {
        didSet { defaults.set(selectedEngineID, forKey: Keys.selectedEngine) }
    }
    /// Whether background auto titles/tags may be generated with the selected provider.
    /// OFF by default: silently sending every recent drawing off-device is a privacy
    /// risk, so it is a separate explicit opt-in with its own consent category.
    var generateTitlesWithProvider: Bool {
        didSet { defaults.set(generateTitlesWithProvider, forKey: Keys.generateTitlesWithProvider) }
    }

    init(
        defaults: UserDefaults = .standard,
        keyStore: AIKeyStore = KeychainKeyStore(),
        consentStore: AIConsentStore? = nil,
        sessionFactory: @escaping @Sendable () -> URLSession = { AITransport.makeSession() }
    ) {
        self.defaults = defaults
        self.keyStore = keyStore
        let consent = consentStore ?? AIConsentStore(defaults: defaults)
        self.consentStore = consent
        self.sessionFactory = sessionFactory
        self.service = AIProviderService(keyStore: keyStore, consentStore: consent, sessionFactory: sessionFactory)
        self.providers = Self.loadProviders(defaults)
        self.selectedEngineID = defaults.string(forKey: Keys.selectedEngine) ?? AIEngineSelection.appleID
        self.generateTitlesWithProvider = defaults.bool(forKey: Keys.generateTitlesWithProvider)
    }

    // MARK: Provider CRUD

    /// Adds a provider and, if a non-empty key was entered, saves it to the Keychain.
    /// Throws a Keychain failure BEFORE the provider is recorded, so a failed key write
    /// never leaves a keyless provider the editor claimed was saved (S-7).
    func addProvider(_ config: AIProviderConfig, key: String) throws {
        try keyStore.setKey(key, for: config.id)
        providers.append(config)
    }

    /// Replaces a provider's config (name, base URL, model) in place. Consent AND the
    /// stored key are bound to the (kind, scheme, host, port) the user approved; if any
    /// of those changes, both the drawing data and the key would otherwise reach a
    /// different endpoint, so consent is revoked AND the stored key is deleted — the
    /// user must allow the new endpoint and re-enter its key (S-2). The caller
    /// re-saves a freshly typed key after this returns.
    func updateProvider(_ config: AIProviderConfig) throws {
        guard let index = providers.firstIndex(where: { $0.id == config.id }) else { return }
        if !Self.consentSurvivesEdit(from: providers[index], to: config) {
            service.revokeConsent(config.id)
            try keyStore.setKey("", for: config.id)   // delete the old-endpoint key (S-7)
        }
        providers[index] = config
    }

    /// Whether an edit keeps the existing consent and key: only when the provider kind
    /// and the full endpoint (scheme, host, port, each case-insensitive) are all
    /// unchanged. Pure, so the policy is unit-tested and the editor can warn before
    /// saving (S-2).
    nonisolated static func consentSurvivesEdit(from old: AIProviderConfig, to new: AIProviderConfig) -> Bool {
        old.kind == new.kind && sameEndpoint(old.baseURL, new.baseURL)
    }

    /// Whether two base URLs name the same endpoint: scheme, host (case-insensitive)
    /// and port all equal. A changed scheme or port re-targets where the key and
    /// drawing data go just as a changed host does (S-2).
    nonisolated static func sameEndpoint(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased()
            && a.port == b.port
    }

    /// Removes a provider entirely: its config, its key AND its consent (core API).
    func removeProvider(_ providerID: String) {
        try? service.removeProvider(providerID)
        providers.removeAll { $0.id == providerID }
        if selectedEngineID == providerID { selectedEngineID = AIEngineSelection.appleID }
    }

    /// The config for a provider id, if configured.
    func provider(id: String) -> AIProviderConfig? { providers.first { $0.id == id } }

    // MARK: Keys

    /// Replaces a provider's stored key (empty deletes it). The value is never read
    /// back into the UI. Throws a Keychain failure so the editor never shows "saved"
    /// when the write failed (S-7).
    func setKey(_ key: String, for providerID: String) throws {
        try keyStore.setKey(key, for: providerID)
    }

    /// Whether a key is stored for a provider (so the UI can show "Key saved ✓"
    /// without ever revealing the key).
    func hasKey(for providerID: String) -> Bool {
        ((try? keyStore.key(for: providerID)) ?? nil)?.isEmpty == false
    }

    // MARK: Consent

    func isConsentGranted(_ providerID: String) -> Bool { consentStore.isGranted(providerID) }

    func grantConsent(_ providerID: String, purpose: AIConsentPurpose) {
        consentStore.grant(providerID, purpose: purpose)
    }

    func revokeConsent(_ providerID: String) { service.revokeConsent(providerID) }

    func hasTitlesConsent(_ providerID: String) -> Bool {
        consentStore.hasCategory(providerID, .titles)
    }

    // MARK: Engine selection

    func engineOptions(onDeviceAvailable: Bool) -> [AIEngineOption] {
        AIEngineSelection.options(providers: providers, onDeviceAvailable: onDeviceAvailable)
    }

    func shouldShowAISurface(onDeviceAvailable: Bool) -> Bool {
        AIEngineSelection.shouldShowAISurface(providers: providers, onDeviceAvailable: onDeviceAvailable)
    }

    func resolvedEngine(onDeviceAvailable: Bool) -> AIEngineChoice? {
        AIEngineSelection.resolve(selectedID: selectedEngineID, providers: providers, onDeviceAvailable: onDeviceAvailable)
    }

    /// The provider that would generate background titles/tags, or nil. Requires the
    /// opt-in ON, the selected engine to be a provider, and that provider's own
    /// titling consent category to be granted (A2b: the third-party titling gate).
    func titlesProvider(onDeviceAvailable: Bool) -> AIProviderConfig? {
        guard generateTitlesWithProvider,
              case .provider(let config)? = resolvedEngine(onDeviceAvailable: onDeviceAvailable),
              hasTitlesConsent(config.id) else { return nil }
        return config
    }

    // MARK: Network (Settings actions)

    /// Loads the provider's model list for the picker. A key only ever flows to an
    /// endpoint it was entered for (S-2): the editor's freshly typed `explicitKey`
    /// goes to whatever endpoint is shown, but the STORED key is reused only when the
    /// saved provider still names the SAME endpoint as `config`. Otherwise an empty
    /// key is sent — which succeeds for a loopback/local host and throws `.missingKey`
    /// for a host that needs one — so a key saved for the old host never leaks to a
    /// newly-typed Base URL. Throws a typed `ProviderError` on failure.
    func loadModels(for config: AIProviderConfig, explicitKey: String? = nil) async throws -> [String] {
        let key: String
        if let explicitKey {
            key = explicitKey
        } else if let stored = provider(id: config.id),
                  Self.sameEndpoint(stored.baseURL, config.baseURL) {
            key = (((try? keyStore.key(for: config.id)) ?? nil) ?? "")
        } else {
            key = ""
        }
        return try await AIModelCatalog.fetch(config: config, key: key, session: sessionFactory())
    }

    /// Runs a tiny Test-connection request through the consent-gated core (a no-drawing
    /// "Reply with OK" prompt). Returns nil on success or the typed error — including
    /// `.consentRequired` when the provider hasn't been allowed, which the UI turns into
    /// the consent screen. The provider must be configured with a stored key first.
    func testConnection(config: AIProviderConfig) async -> ProviderError? {
        do {
            let stream = try service.stream(config: config, request: AIProviderRequestBuilder.testConnection(model: config.model))
            for try await _ in stream {}
            return nil
        } catch let error as ProviderError {
            return error
        } catch is CancellationError {
            return nil
        } catch {
            return .transport("\(error)")
        }
    }

    // MARK: Persistence

    private func persistProviders() {
        if let data = try? JSONEncoder().encode(providers) {
            defaults.set(data, forKey: Keys.providers)
        }
    }

    static func loadProviders(_ defaults: UserDefaults) -> [AIProviderConfig] {
        guard let data = defaults.data(forKey: Keys.providers) else { return [] }
        return decodeProviders(data)
    }

    /// Decodes the persisted provider list element by element (C2), so a single bad
    /// config — a malformed entry or one whose `AIProviderKind` this build doesn't
    /// know (e.g. one written by a newer version) — is skipped rather than wiping
    /// every configured provider. Pure, so the per-item tolerance is unit-tested.
    nonisolated static func decodeProviders(_ data: Data) -> [AIProviderConfig] {
        let decoder = JSONDecoder()
        // Decode each element on its own: an unknown `kind` or a missing field fails
        // only that element, and the surrounding good configs are preserved.
        if let wrappers = try? decoder.decode([FailableProvider].self, from: data) {
            return wrappers.compactMap(\.config)
        }
        // The top level wasn't even an array (truncated/corrupt blob): start empty
        // rather than trap. The stored keys and consent are untouched.
        return []
    }

    /// Decodes an `AIProviderConfig` or, on failure, nothing — so one malformed or
    /// unknown-kind element never fails the whole array (C2).
    private struct FailableProvider: Decodable {
        let config: AIProviderConfig?
        init(from decoder: Decoder) throws {
            config = try? decoder.singleValueContainer().decode(AIProviderConfig.self)
        }
    }

    private enum Keys {
        static let providers = "settings.ai.providers"
        static let selectedEngine = "settings.ai.selectedEngine"
        static let generateTitlesWithProvider = "settings.ai.generateTitlesWithProvider"
    }
}
