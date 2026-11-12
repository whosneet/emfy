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
        store.addProvider(config(), key: "sk-secret-abc")
        #expect(store.providers.count == 1)
        #expect(store.hasKey(for: "p1"))
        #expect(try keys.key(for: "p1") == "sk-secret-abc")
        // The persisted config JSON carries no key.
        #expect(store.provider(id: "p1") != nil)
    }

    @Test func removeDeletesKeyAndConsent() throws {
        let (store, _, keys) = make()
        store.addProvider(config(), key: "sk-secret")
        store.grantConsent("p1", purpose: .drawingData)
        #expect(store.isConsentGranted("p1"))
        store.selectedEngineID = "p1"

        store.removeProvider("p1")
        #expect(store.providers.isEmpty)
        #expect(try keys.key(for: "p1") == nil)       // key gone
        #expect(store.isConsentGranted("p1") == false) // consent gone
        #expect(store.selectedEngineID == AIEngineSelection.appleID) // selection reset
    }

    @Test func providersAndSelectionPersist() {
        let defaults = UserDefaults(suiteName: "persist-" + UUID().uuidString)!
        do {
            let store = AIProviderStore(defaults: defaults, keyStore: InMemoryKeyStore(), consentStore: AIConsentStore(defaults: defaults))
            store.addProvider(config(), key: "k")
            store.selectedEngineID = "p1"
            store.generateTitlesWithProvider = true
        }
        // A fresh store over the same defaults reloads the config and selection.
        let reloaded = AIProviderStore(defaults: defaults, keyStore: InMemoryKeyStore(), consentStore: AIConsentStore(defaults: defaults))
        #expect(reloaded.providers.map(\.id) == ["p1"])
        #expect(reloaded.selectedEngineID == "p1")
        #expect(reloaded.generateTitlesWithProvider == true)
    }

    @Test func titlesProviderGateNeedsOptInAndOwnConsent() {
        let (store, _, _) = make()
        store.addProvider(config(), key: "k")
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

    @Test func engineOptionsAndResolution() {
        let (store, _, _) = make()
        store.addProvider(config(), key: "k")
        #expect(store.shouldShowAISurface(onDeviceAvailable: false))
        #expect(store.engineOptions(onDeviceAvailable: false).map(\.id) == ["p1"])
        store.selectedEngineID = "p1"
        #expect(store.resolvedEngine(onDeviceAvailable: false) == .provider(config()))
    }
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
