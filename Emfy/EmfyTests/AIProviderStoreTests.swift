import Foundation
import Testing

// A2b: the configured-provider store — defaults, persistence, remove-deletes-key-and-
// consent, and the third-party titling gate (off by default, needs its own consent).

@MainActor
@Suite struct AIProviderStoreTests {

    private func make() -> (AIProviderStore, UserDefaults, InMemoryKeyStore) {
        let defaults = UserDefaults(suiteName: "store-" + UUID().uuidString)!
        let keys = InMemoryKeyStore()
        let store = AIProviderStore(defaults: defaults, keyStore: keys, consentStore: AIConsentStore(defaults: defaults), sessionFactory: { AITransport.makeSession(protocolClasses: [StubURLProtocol.self]) })
        return (store, defaults, keys)
    }

    private func config(_ id: String = "p1", _ name: String = "Claude") -> AIProviderConfig {
        AIProviderConfig(id: id, kind: .anthropic, displayName: name, baseURL: URL(string: "https://api.anthropic.com")!, model: "claude-opus-5-5")
    }

    @Test func thirdPartyTitlesOffByDefault() {
        let (store, _, _) = make()
        #expect(store.generateTitlesWithProvider == false)
        #expect(store.selectedEngineID == AIEngineSelection.appleID)
        #expect(store.providers.isEmpty)
    }

    @Test func addStoresKeyInKeychainNotConfig() throws {
        let (store, _, keys) = make()
        try store.addProvider(config(), key: "sk-secret-abc")
        #expect(store.providers.count == 1)
        #expect(store.hasKey(for: "p1"))
        #expect(try keys.key(for: "p1") == "sk-secret-abc")
        // The persisted config JSON carries no key.
        #expect(store.provider(id: "p1") != nil)
    }

    @Test func removeDeletesKeyAndConsent() throws {
        let (store, _, keys) = make()
        try store.addProvider(config(), key: "sk-secret")
        store.grantConsent("p1", purpose: .drawingData)
        #expect(store.isConsentGranted("p1"))
        store.selectedEngineID = "p1"

        store.removeProvider("p1")
        #expect(store.providers.isEmpty)
        #expect(try keys.key(for: "p1") == nil)       // key gone
        #expect(store.isConsentGranted("p1") == false) // consent gone
        #expect(store.selectedEngineID == AIEngineSelection.appleID) // selection reset
    }

    // S-2: consent AND the stored key are bound to the (kind, scheme, host, port) the
    // user approved. Editing a provider's endpoint must drop consent AND delete the key,
    // so neither drawing data nor the key reaches a new endpoint under the old grant; a
    // cosmetic edit (name/model, same endpoint) keeps both.
    @Test func editingTheHostRevokesConsentAndDeletesKeyButACosmeticEditKeepsThem() throws {
        let (store, _, keys) = make()
        let compat = AIProviderConfig(id: "c1", kind: .openAICompatible, displayName: "Local", baseURL: URL(string: "https://host-a.example/v1")!, model: "m")
        try store.addProvider(compat, key: "k")
        store.grantConsent("c1", purpose: .drawingData)
        #expect(store.isConsentGranted("c1"))
        #expect(store.hasKey(for: "c1"))

        // A name/model change on the same endpoint keeps consent and the key.
        var cosmetic = compat
        cosmetic.displayName = "Renamed"
        cosmetic.model = "m2"
        try store.updateProvider(cosmetic)
        #expect(store.isConsentGranted("c1"))
        #expect(store.hasKey(for: "c1"))

        // Changing the host drops consent AND deletes the key (S-2).
        var moved = cosmetic
        moved.baseURL = URL(string: "https://host-b.example/v1")!
        try store.updateProvider(moved)
        #expect(store.isConsentGranted("c1") == false)
        #expect(store.hasKey(for: "c1") == false)
        #expect(try keys.key(for: "c1") == nil)
    }

    @Test func consentSurvivesEditPolicy() {
        let a = AIProviderConfig(id: "x", kind: .openAICompatible, displayName: "A", baseURL: URL(string: "https://H.Example/v1")!, model: "m")
        var differentHost = a; differentHost.baseURL = URL(string: "https://host.example/v1")!
        #expect(!AIProviderStore.consentSurvivesEdit(from: a, to: differentHost))
        var caseOnly = a; caseOnly.baseURL = URL(string: "https://h.example/v1")!   // host differs only by case
        #expect(AIProviderStore.consentSurvivesEdit(from: a, to: caseOnly))
        var kindChange = a; kindChange.kind = .openAI
        #expect(!AIProviderStore.consentSurvivesEdit(from: a, to: kindChange))
        // S-2: a changed SCHEME or PORT also breaks the endpoint, so consent/key drop.
        var schemeChange = a; schemeChange.baseURL = URL(string: "http://h.example/v1")!
        #expect(!AIProviderStore.consentSurvivesEdit(from: a, to: schemeChange))
        var portChange = a; portChange.baseURL = URL(string: "https://h.example:8443/v1")!
        #expect(!AIProviderStore.consentSurvivesEdit(from: a, to: portChange))
        // Same scheme/host/port, different path → same endpoint, consent survives.
        var pathOnly = a; pathOnly.baseURL = URL(string: "https://h.example/v2")!
        #expect(AIProviderStore.consentSurvivesEdit(from: a, to: pathOnly))
    }

    @Test func providersAndSelectionPersist() throws {
        let defaults = UserDefaults(suiteName: "persist-" + UUID().uuidString)!
        do {
            let store = AIProviderStore(defaults: defaults, keyStore: InMemoryKeyStore(), consentStore: AIConsentStore(defaults: defaults))
            try store.addProvider(config(), key: "k")
            store.selectedEngineID = "p1"
            store.generateTitlesWithProvider = true
        }
        // A fresh store over the same defaults reloads the config and selection.
        let reloaded = AIProviderStore(defaults: defaults, keyStore: InMemoryKeyStore(), consentStore: AIConsentStore(defaults: defaults))
        #expect(reloaded.providers.map(\.id) == ["p1"])
        #expect(reloaded.selectedEngineID == "p1")
        #expect(reloaded.generateTitlesWithProvider == true)
    }

    @Test func titlesProviderGateNeedsOptInAndOwnConsent() throws {
        let (store, _, _) = make()
        try store.addProvider(config(), key: "k")
        store.selectedEngineID = "p1"
        // Off by default → no titling provider.
        #expect(store.titlesProvider(onDeviceAvailable: false) == nil)
        // Opt-in on, but only drawing-data consent → still no titling (own category missing).
        store.generateTitlesWithProvider = true
        store.grantConsent("p1", purpose: .drawingData)
        #expect(store.titlesProvider(onDeviceAvailable: false) == nil)
        // Titling consent granted → the provider is used for titles.
        store.grantConsent("p1", purpose: .titles)
        #expect(store.titlesProvider(onDeviceAvailable: false)?.id == "p1")
    }

    // S-2: "Load models" must never send a key saved for one endpoint to a different
    // one. With no explicit key typed and the draft pointing at a new host, the stored
    // key is withheld; an empty key for a non-loopback host fails with .missingKey before
    // any request, so the key cannot leak to the new host.
    @Test func loadModelsWithholdsAStoredKeyFromADifferentEndpoint() async throws {
        let (store, _, _) = make()
        let a = AIProviderConfig(id: "c1", kind: .openAICompatible, displayName: "A",
                                 baseURL: URL(string: "https://host-a.example/v1")!, model: "m")
        try store.addProvider(a, key: "secret-A")
        var moved = a
        moved.baseURL = URL(string: "https://host-b.example/v1")!
        await #expect(throws: ProviderError.missingKey) {
            _ = try await store.loadModels(for: moved, explicitKey: nil)
        }
    }

    // S-7: a Keychain write failure must PROPAGATE out of the store (no `try?`), so the
    // editor can surface it and never claim the key was saved.
    @Test func keyWriteFailurePropagates() {
        let defaults = UserDefaults(suiteName: "fail-" + UUID().uuidString)!
        let store = AIProviderStore(defaults: defaults, keyStore: FailingKeyStore(),
                                    consentStore: AIConsentStore(defaults: defaults))
        #expect(throws: (any Error).self) { try store.addProvider(config(), key: "k") }
        #expect(throws: (any Error).self) { try store.setKey("k", for: "p1") }
    }

    // C2: a single bad provider config — malformed, or one whose `kind` this build
    // doesn't recognise (written by a newer version) — must be skipped on load, never
    // wipe every configured provider.
    @Test func oneBadProviderConfigDoesNotWipeTheList() {
        let good = #"{"id":"g","kind":"anthropic","displayName":"Claude","baseURL":"https://api.anthropic.com","model":"m"}"#
        let unknownKind = #"{"id":"u","kind":"gemini","displayName":"Future","baseURL":"https://x.example","model":"m"}"#
        let malformed = #"{"id":"m","displayName":"NoKind"}"#
        let json = "[\(good),\(unknownKind),\(malformed)]"
        let configs = AIProviderStore.decodeProviders(Data(json.utf8))
        #expect(configs.map(\.id) == ["g"])   // the good one survives; the unknown/malformed are dropped
    }

    @Test func decodeProvidersTolerateATruncatedBlob() {
        #expect(AIProviderStore.decodeProviders(Data("not json".utf8)).isEmpty)
        #expect(AIProviderStore.decodeProviders(Data("{".utf8)).isEmpty)
    }

    @Test func loadProvidersSkipsABadEntryFromDefaults() {
        let defaults = UserDefaults(suiteName: "c2-" + UUID().uuidString)!
        let good = #"{"id":"g","kind":"openAI","displayName":"GPT","baseURL":"https://api.openai.com/v1","model":"m"}"#
        let unknownKind = #"{"id":"u","kind":"gemini","displayName":"Future","baseURL":"https://x.example","model":"m"}"#
        defaults.set(Data("[\(unknownKind),\(good)]".utf8), forKey: "settings.ai.providers")
        #expect(AIProviderStore.loadProviders(defaults).map(\.id) == ["g"])
    }

    @Test func engineOptionsAndResolution() throws {
        let (store, _, _) = make()
        try store.addProvider(config(), key: "k")
        #expect(store.shouldShowAISurface(onDeviceAvailable: false))
        #expect(store.engineOptions(onDeviceAvailable: false).map(\.id) == ["p1"])
        store.selectedEngineID = "p1"
        #expect(store.resolvedEngine(onDeviceAvailable: false) == .provider(config()))
    }
}

/// A key store whose every write fails, to prove the store propagates the error (S-7).
private struct FailingKeyStore: AIKeyStore {
    struct Failure: Error {}
    func setKey(_ key: String, for providerID: String) throws { throw Failure() }
    func key(for providerID: String) throws -> String? { nil }
    func deleteKey(for providerID: String) throws { throw Failure() }
}

// The provider title/tags JSON reply parser (A2b), tolerant of prose and fences.
@Suite struct DrawingTitleTagsJSONTests {
    @Test func parsesCleanJSON() {
        let parsed = DrawingTitleTagsJSON.parse(#"{"title": "Office Floor Plan", "tags": ["floorplan", "layout"]}"#)
        #expect(parsed?.title == "Office Floor Plan")
        #expect(parsed?.tags == ["floorplan", "layout"])
    }

    @Test func parsesJSONWrappedInProseOrFences() {
        let reply = "Here you go:\n```json\n{\"title\": \"March Invoice\", \"tags\": [\"invoice\", \"finance\"]}\n```"
        let parsed = DrawingTitleTagsJSON.parse(reply)
        #expect(parsed?.title == "March Invoice")
        #expect(parsed?.tags == ["invoice", "finance"])
    }

    @Test func returnsNilWithoutATitle() {
        #expect(DrawingTitleTagsJSON.parse("no json here") == nil)
        #expect(DrawingTitleTagsJSON.parse(#"{"tags": ["x"]}"#) == nil)
    }
}
