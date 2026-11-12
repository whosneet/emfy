import Foundation
import Testing

// A2b: the "Load models" call — parsing both provider shapes, the right endpoint and
// auth headers per kind, and typed errors. Stubbed; no real network, no real key.

@Suite struct AIModelCatalogTests {

    private func stubSession() -> URLSession {
        AITransport.makeSession(protocolClasses: [StubURLProtocol.self])
    }

    // MARK: Parsing

    @Test func parsesAnthropicModelsShape() {
        // Anthropic /v1/models: { "data": [ { "type":"model", "id":"…", "display_name":"…" } ], … }
        let json = #"""
        {"data":[{"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5"},
                 {"type":"model","id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5"}],
         "has_more":false}
        """#
        let ids = AIModelCatalog.parseModelIDs(Data(json.utf8))
        #expect(ids == ["claude-opus-5-5", "claude-haiku-5-5"])
    }

    @Test func parsesOpenAIModelsShape() {
        // OpenAI /models: { "object":"list", "data":[ { "id":"…", "object":"model" } ] }
        let json = #"""
        {"object":"list","data":[{"id":"gpt-5","object":"model","owned_by":"openai"},
                                 {"id":"gpt-5-mini","object":"model","owned_by":"openai"}]}
        """#
        let ids = AIModelCatalog.parseModelIDs(Data(json.utf8))
        #expect(ids == ["gpt-5", "gpt-5-mini"])
    }

    @Test func toleratesJunkAndMissingData() {
        #expect(AIModelCatalog.parseModelIDs(Data("not json".utf8)).isEmpty)
        #expect(AIModelCatalog.parseModelIDs(Data("[1,2,3]".utf8)).isEmpty)
        #expect(AIModelCatalog.parseModelIDs(Data(#"{"data":[{"name":"no-id"}]}"#.utf8)).isEmpty)
    }

    // MARK: Endpoint

    @Test func endpointPerKind() {
        let anthropic = AIProviderConfig(kind: .anthropic, displayName: "A", baseURL: URL(string: "https://api.anthropic.com")!, model: "m")
        #expect(AIModelCatalog.endpoint(for: anthropic).absoluteString == "https://api.anthropic.com/v1/models")
        let compat = AIProviderConfig(kind: .openAICompatible, displayName: "O", baseURL: URL(string: "https://openrouter.ai/api/v1")!, model: "m")
        #expect(AIModelCatalog.endpoint(for: compat).absoluteString == "https://openrouter.ai/api/v1/models")
    }

    // MARK: Fetch (stubbed)

    @Test func fetchSendsAnthropicHeadersAndParses() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.register(host: host) { _, _ in
            StubResponse(statusCode: 200, headers: ["Content-Type": "application/json"],
                         body: Data(#"{"data":[{"id":"claude-opus-5-5"}]}"#.utf8))
        }
        defer { StubURLProtocol.unregister(host: host) }
        let config = AIProviderConfig(kind: .anthropic, displayName: "Claude", baseURL: URL(string: "https://\(host)")!, model: "m")
        let ids = try await AIModelCatalog.fetch(config: config, key: "sk-secret", session: stubSession())
        #expect(ids == ["claude-opus-5-5"])
        let captured = StubURLProtocol.captured(host: host).first
        #expect(captured?.method == "GET")
        #expect(captured?.url?.path == "/v1/models")
        #expect(captured?.headers["x-api-key"] == "sk-secret")
        #expect(captured?.headers["anthropic-version"] == AIProviderPresets.anthropicVersion)
    }

    @Test func fetchSendsOpenAIBearerHeader() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.register(host: host) { _, _ in
            StubResponse(statusCode: 200, body: Data(#"{"data":[{"id":"gpt-5"}]}"#.utf8))
        }
        defer { StubURLProtocol.unregister(host: host) }
        let config = AIProviderConfig(kind: .openAI, displayName: "OpenAI", baseURL: URL(string: "https://\(host)/v1")!, model: "m")
        let ids = try await AIModelCatalog.fetch(config: config, key: "sk-oai", session: stubSession())
        #expect(ids == ["gpt-5"])
        #expect(StubURLProtocol.captured(host: host).first?.headers["Authorization"] == "Bearer sk-oai")
    }

    @Test func fetchMapsHTTPErrorToTypedError() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.register(host: host) { _, _ in
            StubResponse(statusCode: 401, body: Data(#"{"error":{"type":"authentication_error","message":"bad key"}}"#.utf8))
        }
        defer { StubURLProtocol.unregister(host: host) }
        let config = AIProviderConfig(kind: .anthropic, displayName: "Claude", baseURL: URL(string: "https://\(host)")!, model: "m")
        await #expect(throws: ProviderError.authentication) {
            _ = try await AIModelCatalog.fetch(config: config, key: "sk", session: stubSession())
        }
    }

    @Test func anthropicFetchWithoutKeyThrowsMissingKey() async {
        let config = AIProviderConfig(kind: .anthropic, displayName: "Claude", baseURL: URL(string: "https://api.anthropic.com")!, model: "m")
        await #expect(throws: ProviderError.missingKey) {
            _ = try await AIModelCatalog.fetch(config: config, key: "", session: stubSession())
        }
    }
}
