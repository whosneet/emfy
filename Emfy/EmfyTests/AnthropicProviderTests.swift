import EMFRender
import Foundation
import Testing

// A2a: the Anthropic Messages client over the URLProtocol stub — exact headers
// and body, a streamed text answer, the tool_use → tool_result loop (full
// assistant turn preserved, results in ONE user message, iteration cap), invalid
// tool input, refusal, and typed errors with retries honouring retry-after.

@Suite struct AnthropicProviderTests {

    // MARK: Helpers

    private func toolData(lines: [String]) -> DrawingAIToolData {
        let info = DrawingInfo(format: "Enhanced Metafile", pageSizeMM: nil, recordCount: lines.count, hasText: !lines.isEmpty, hasPictures: false)
        return DrawingAIToolData(textLines: lines, info: info, recordKinds: [])
    }

    private func request(model: String, lines: [String] = ["hello world"]) -> AIProviderRequest {
        AIProviderRequest(
            system: DrawingAIPrompt.instructions,
            userPrompt: "The user asks: what is this?",
            tools: AIProviderTools.all(data: toolData(lines: lines)),
            model: model
        )
    }

    private func makeClient(host: String, key: String = "sk-test-key", backoff: AIBackoff = AIBackoff(sleep: { _ in })) -> (AnthropicClient, AIConsentGrant) {
        let config = AIProviderConfig(id: "a", kind: .anthropic, displayName: "Claude", baseURL: URL(string: "https://\(host)")!, model: AIProviderPresets.anthropicDefaultModel)
        let session = AITransport.makeSession(protocolClasses: [StubURLProtocol.self])
        let client = AnthropicClient(config: config, apiKey: key, session: session, backoff: backoff)
        let defaults = UserDefaults(suiteName: "t-" + UUID().uuidString)!
        let consent = AIConsentStore(defaults: defaults)
        consent.grant("a", categories: ["text"])
        return (client, consent.authorize("a")!)
    }

    private func collect(_ stream: AsyncThrowingStream<AIProviderEvent, Error>) async throws -> [AIProviderEvent] {
        var out: [AIProviderEvent] = []
        for try await event in stream { out.append(event) }
        return out
    }

    private func bodyJSON(host: String, at index: Int = 0) throws -> [String: Any] {
        let captured = StubURLProtocol.captured(host: host)
        let body = try #require(captured.indices.contains(index) ? captured[index].body : nil)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: Headers & body

    @Test func opusRequestHasExactHeadersAndBody() async throws {
        let host = StubURLProtocol.uniqueHost()
        let (client, grant) = makeClient(host: host, key: "sk-abc")
        StubURLProtocol.register(host: host) { _, _ in
            StubResponse(statusCode: 200, headers: [:], body: AIStubWire.anthropicText(["hi"]))
        }
        defer { StubURLProtocol.unregister(host: host) }
        _ = try await collect(client.stream(request(model: "claude-opus-5-5"), grant: grant))

        // URLSession canonicalises standard header names (content-type →
        // Content-Type); custom headers keep their case. Look up case-insensitively.
        let rawHeaders = StubURLProtocol.captured(host: host).first?.headers ?? [:]
        let headers = Dictionary(uniqueKeysWithValues: rawHeaders.map { ($0.key.lowercased(), $0.value) })
        #expect(headers["x-api-key"] == "sk-abc")
        #expect(headers["anthropic-version"] == "2026-10-21")
        #expect(headers["content-type"] == "application/json")
        #expect(headers["anthropic-beta"] == "server-side-fallback-2026-07-01")

        let body = try bodyJSON(host: host)
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["max_tokens"] as? Int == 64000)
        #expect(body["stream"] as? Bool == true)
        #expect(body["system"] as? String == DrawingAIPrompt.instructions)
        #expect(body["fallbacks"] as? String == "default")
        // Forbidden fields never appear.
        #expect(body["temperature"] == nil)
        #expect(body["top_p"] == nil)
        #expect(body["top_k"] == nil)
        #expect(body["thinking"] == nil)
        #expect(body["tool_choice"] == nil)
        // Tools carry a JSON-Schema object input.
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 4)
        let findText = try #require(tools.first { ($0["name"] as? String) == "findText" })
        let schema = try #require(findText["input_schema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect((schema["required"] as? [String]) == ["query"])
    }

    @Test func nonOpusModelOmitsFallbackAndBeta() async throws {
        let host = StubURLProtocol.uniqueHost()
        let (client, grant) = makeClient(host: host)
        StubURLProtocol.register(host: host) { _, _ in
            StubResponse(statusCode: 200, headers: [:], body: AIStubWire.anthropicText(["hi"]))
        }
        defer { StubURLProtocol.unregister(host: host) }
        _ = try await collect(client.stream(request(model: "claude-sonnet-5-5"), grant: grant))

        let headers = StubURLProtocol.captured(host: host).first?.headers ?? [:]
        #expect(headers["anthropic-beta"] == nil)
        let body = try bodyJSON(host: host)
        #expect(body["fallbacks"] == nil)
        #expect(body["model"] as? String == "claude-sonnet-5-5")
    }

    // MARK: Streaming text

    @Test func streamsTextDeltas() async throws {
        let host = StubURLProtocol.uniqueHost()
        let (client, grant) = makeClient(host: host)
        StubURLProtocol.register(host: host) { _, _ in
            StubResponse(statusCode: 200, headers: [:], body: AIStubWire.anthropicText(["Hello, ", "world."]))
        }
        defer { StubURLProtocol.unregister(host: host) }
        let events = try await collect(client.stream(request(model: "claude-opus-5-5"), grant: grant))
        let text = events.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        #expect(text == "Hello, world.")
        #expect(!events.contains(.refusal))
    }

    // MARK: Tool loop

    @Test func runsToolLoopAndPreservesAssistantTurnInOneResultMessage() async throws {
        let host = StubURLProtocol.uniqueHost()
        let (client, grant) = makeClient(host: host)
        StubURLProtocol.register(host: host) { _, attempt in
            if attempt == 0 {
                return StubResponse(statusCode: 200, headers: [:], body: AIStubWire.anthropicToolUse(id: "tool-1", name: "findText", inputJSON: #"{"query":"world"}"#))
            }
            return StubResponse(statusCode: 200, headers: [:], body: AIStubWire.anthropicText(["Found it."]))
        }
        defer { StubURLProtocol.unregister(host: host) }
        let events = try await collect(client.stream(request(model: "claude-opus-5-5", lines: ["hello world"]), grant: grant))

        #expect(events.contains(.toolUsed("Find text")))
        let text = events.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        #expect(text == "Found it.")
        #expect(StubURLProtocol.attemptCount(host: host) == 2)

        // Second request: user, assistant(tool_use), user(tool_result) — results in
        // ONE user message, assistant content preserved.
        let body = try bodyJSON(host: host, at: 1)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[1]["role"] as? String == "assistant")
        let assistantContent = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistantContent.contains { ($0["type"] as? String) == "tool_use" && ($0["id"] as? String) == "tool-1" })
        #expect(messages[2]["role"] as? String == "user")
        let results = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(results.count == 1)
        #expect(results[0]["type"] as? String == "tool_result")
        #expect(results[0]["tool_use_id"] as? String == "tool-1")
        #expect(results[0]["is_error"] == nil)
    }

    @Test func toolLoopIsCappedAtSixIterations() async throws {
        let host = StubURLProtocol.uniqueHost()
        let (client, grant) = makeClient(host: host)
        StubURLProtocol.register(host: host) { _, _ in
            StubResponse(statusCode: 200, headers: [:], body: AIStubWire.anthropicToolUse(id: "t", name: "findText", inputJSON: #"{"query":"x"}"#))
        }
        defer { StubURLProtocol.unregister(host: host) }
        await #expect(throws: ProviderError.toolLoopExhausted) {
            _ = try await collect(client.stream(request(model: "claude-opus-5-5"), grant: grant))
        }
        #expect(StubURLProtocol.attemptCount(host: host) == 6)
    }

    @Test func invalidToolInputReturnsIsError() async throws {
        let host = StubURLProtocol.uniqueHost()
        let (client, grant) = makeClient(host: host)
        StubURLProtocol.register(host: host) { _, attempt in
            if attempt == 0 {
                // findText with no query → validation fails → is_error result.
                return StubResponse(statusCode: 200, headers: [:], body: AIStubWire.anthropicToolUse(id: "t1", name: "findText", inputJSON: "{}"))
            }
            return StubResponse(statusCode: 200, headers: [:], body: AIStubWire.anthropicText(["done"]))
        }
        defer { StubURLProtocol.unregister(host: host) }
        _ = try await collect(client.stream(request(model: "claude-opus-5-5"), grant: grant))

        let body = try bodyJSON(host: host, at: 1)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let results = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(results[0]["is_error"] as? Bool == true)
    }

    // MARK: Refusal

    @Test func refusalStopReasonYieldsRefusal() async throws {
        let host = StubURLProtocol.uniqueHost()
        let (client, grant) = makeClient(host: host)
        StubURLProtocol.register(host: host) { _, _ in
            StubResponse(statusCode: 200, headers: [:], body: AIStubWire.anthropicText([], stopReason: "refusal"))
        }
        defer { StubURLProtocol.unregister(host: host) }
        let events = try await collect(client.stream(request(model: "claude-opus-5-5"), grant: grant))
        #expect(events.contains(.refusal))
    }

    // MARK: Errors & retries

    @Test func rateLimitRetriesHonouringRetryAfterThenSucceeds() async throws {
        let host = StubURLProtocol.uniqueHost()
        let recorder = DelayRecorder()
        let backoff = AIBackoff(sleep: { recorder.record($0) })
        let (client, grant) = makeClient(host: host, backoff: backoff)
        StubURLProtocol.register(host: host) { _, attempt in
            if attempt == 0 {
                return StubResponse(statusCode: 429, headers: ["retry-after": "2"], body: AIStubWire.anthropicError(type: "rate_limit_error", message: "slow down"))
            }
            return StubResponse(statusCode: 200, headers: [:], body: AIStubWire.anthropicText(["recovered"]))
        }
        defer { StubURLProtocol.unregister(host: host) }
        let events = try await collect(client.stream(request(model: "claude-opus-5-5"), grant: grant))
        let text = events.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        #expect(text == "recovered")
        #expect(StubURLProtocol.attemptCount(host: host) == 2)
        #expect(recorder.values == [2])
    }

    @Test func overloadedRetriesThenGivesUp() async throws {
        let host = StubURLProtocol.uniqueHost()
        let (client, grant) = makeClient(host: host)
        StubURLProtocol.register(host: host) { _, _ in
            StubResponse(statusCode: 529, headers: [:], body: AIStubWire.anthropicError(type: "overloaded_error", message: "overloaded"))
        }
        defer { StubURLProtocol.unregister(host: host) }
        await #expect(throws: ProviderError.overloaded) {
            _ = try await collect(client.stream(request(model: "claude-opus-5-5"), grant: grant))
        }
        // 1 initial + 2 retries.
        #expect(StubURLProtocol.attemptCount(host: host) == 3)
    }

    @Test func authErrorIsNotRetried() async throws {
        let host = StubURLProtocol.uniqueHost()
        let (client, grant) = makeClient(host: host)
        StubURLProtocol.register(host: host) { _, _ in
            StubResponse(statusCode: 401, headers: [:], body: AIStubWire.anthropicError(type: "authentication_error", message: "bad key"))
        }
        defer { StubURLProtocol.unregister(host: host) }
        await #expect(throws: ProviderError.authentication) {
            _ = try await collect(client.stream(request(model: "claude-opus-5-5"), grant: grant))
        }
        #expect(StubURLProtocol.attemptCount(host: host) == 1)
    }
}

/// Records backoff sleep durations without sleeping.
final class DelayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TimeInterval] = []
    func record(_ value: TimeInterval) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return storage }
}
