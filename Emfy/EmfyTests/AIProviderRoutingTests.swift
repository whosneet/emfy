import Foundation
import Testing

// A2b: the routing glue — the consent preflight (a provider send with no consent asks
// for the consent screen, never fails silently), the engine footnote label, and the
// provider stream consumer.

@Suite struct AIProviderRoutingTests {

    private func config(_ id: String = "p1", _ name: String = "Anthropic", model: String = "claude-opus-5-5") -> AIProviderConfig {
        AIProviderConfig(id: id, kind: .anthropic, displayName: name, baseURL: URL(string: "https://api.anthropic.com")!, model: model)
    }

    // MARK: Preflight

    @Test func onDeviceNeverNeedsConsent() {
        #expect(AIProviderPreflight.check(engine: .onDevice, consentGranted: { _ in false }) == .ready)
    }

    @Test func providerWithoutConsentNeedsTheSheet() {
        let c = config()
        let outcome = AIProviderPreflight.check(engine: .provider(c), consentGranted: { _ in false })
        #expect(outcome == .needsConsent(c))
    }

    @Test func providerWithConsentIsReady() {
        let c = config()
        #expect(AIProviderPreflight.check(engine: .provider(c), consentGranted: { $0 == "p1" }) == .ready)
    }

    // MARK: Footnote label

    @Test func engineLabelForProviderNamesNameAndModel() {
        #expect(AIEngineLabel.text(for: .provider(config("p1", "Anthropic", model: "claude-opus-5-5"))) == "via Anthropic · claude-opus-5-5")
        #expect(AIEngineLabel.text(for: .onDevice).contains("On-device"))
    }

    // MARK: Request builders

    @Test func explainRequestHasNoTools() {
        let request = AIProviderRequestBuilder.explain(items: ["A record was skipped."], model: "m")
        #expect(request.tools.isEmpty)
        #expect(request.system == DrawingAIPrompt.structuredInstructions)
    }

    @Test func testConnectionRequestIsTrivial() {
        let request = AIProviderRequestBuilder.testConnection(model: "m")
        #expect(request.tools.isEmpty)
        #expect(request.userPrompt.contains("OK"))
    }

    // MARK: Provider stream consumer

    @MainActor
    @Test func streamAccumulatesTextAndReportsTools() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.register(host: host) { _, _ in
            StubResponse(statusCode: 200, body: AIStubWire.anthropicText(["Hel", "lo"]))
        }
        defer { StubURLProtocol.unregister(host: host) }
        let defaults = UserDefaults(suiteName: "route-" + UUID().uuidString)!
        let consent = AIConsentStore(defaults: defaults)
        let c = config("p1", "Claude")
        let config2 = AIProviderConfig(id: c.id, kind: .anthropic, displayName: c.displayName, baseURL: URL(string: "https://\(host)")!, model: c.model)
        consent.grant(config2.id, purpose: .drawingData)
        let keys = InMemoryKeyStore(); try keys.setKey("sk-x", for: config2.id)
        let service = AIProviderService(keyStore: keys, consentStore: consent, sessionFactory: { AITransport.makeSession(protocolClasses: [StubURLProtocol.self]) }, backoff: AIBackoff(sleep: { _ in }))
        var last = ""
        let refused = try await DrawingAIProviderRun.stream(
            service: service, config: config2,
            request: AIProviderRequest(system: "s", userPrompt: "u", tools: [], model: config2.model),
            onText: { last = $0 }, onTool: { _ in })
        #expect(refused == false)
        #expect(last == "Hello")
    }

    @MainActor
    @Test func streamThrowsConsentRequiredWithoutConsent() async {
        let c = config()
        let defaults = UserDefaults(suiteName: "route2-" + UUID().uuidString)!
        let service = AIProviderService(keyStore: InMemoryKeyStore(), consentStore: AIConsentStore(defaults: defaults), sessionFactory: { AITransport.makeSession(protocolClasses: [StubURLProtocol.self]) })
        await #expect(throws: ProviderError.consentRequired(providerID: c.id)) {
            _ = try await DrawingAIProviderRun.stream(
                service: service, config: c,
                request: AIProviderRequest(system: "s", userPrompt: "u", tools: [], model: c.model),
                onText: { _ in }, onTool: { _ in })
        }
    }
}
