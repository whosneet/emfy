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
    /// Selects the new provider when nothing meaningful was selected before.
    func addProvider(_ config: AIProviderConfig, key: String) {
        try? keyStore.setKey(key, for: config.id)
        providers.append(config)
    }

    /// Replaces a provider's config (name, base URL, model) in place.
    func updateProvider(_ config: AIProviderConfig) {
        guard let index = providers.firstIndex(where: { $0.id == config.id }) else { return }
        providers[index] = config
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
    /// back into the UI.
    func setKey(_ key: String, for providerID: String) {
        try? keyStore.setKey(key, for: providerID)
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

    /// Loads the provider's model list for the picker (needs no consent — no drawing
    /// data). Throws a typed `ProviderError` on failure.
    func loadModels(for config: AIProviderConfig) async throws -> [String] {
        let key = ((try? keyStore.key(for: config.id)) ?? nil) ?? ""
        return try await AIModelCatalog.fetch(config: config, key: key, session: sessionFactory())
    }

    // MARK: Persistence

    private func persistProviders() {
        if let data = try? JSONEncoder().encode(providers) {
            defaults.set(data, forKey: Keys.providers)
        }
    }

    private static func loadProviders(_ defaults: UserDefaults) -> [AIProviderConfig] {
        guard let data = defaults.data(forKey: Keys.providers),
              let decoded = try? JSONDecoder().decode([AIProviderConfig].self, from: data) else {
            return []
        }
        return decoded
    }

    private enum Keys {
        static let providers = "settings.ai.providers"
        static let selectedEngine = "settings.ai.selectedEngine"
        static let generateTitlesWithProvider = "settings.ai.generateTitlesWithProvider"
    }
}
