import EMFRender
import Foundation
import Testing

// A2a: the OpenAI / OpenAI-compatible Chat Completions client over the stub —
// streamed text, the tool_calls fragment loop ending in [DONE], the request
// shape (function tools, bearer auth), and the local-endpoint empty-key path.

@Suite struct OpenAIProviderTests {

    private func toolData(lines: [String]) -> DrawingAIToolData {
        let info = DrawingInfo(format: "Enhanced Metafile", pageSizeMM: nil, recordCount: lines.count, hasText: !lines.isEmpty, hasPictures: false)
        return DrawingAIToolData(textLines: lines, info: info, recordKinds: [])
    }

    private func request(model: String = "gpt-test", lines: [String] = ["hello world"]) -> AIProviderRequest {
        AIProviderRequest(
            system: DrawingAIPrompt.instructions,
            userPrompt: "The user asks: what is this?",
            tools: AIProviderTools.all(data: toolData(lines: lines)),
            model: model
        )
    }

    private func makeClient(baseURL: String, kind: AIProviderKind = .openAI, key: String = "sk-openai") -> (OpenAIClient, AIConsentGrant) {
        let config = AIProviderConfig(id: "o", kind: kind, displayName: "OpenAI", baseURL: URL(string: baseURL)!, model: "gpt-test")
        let session = AITransport.makeSession(protocolClasses: [StubURLProtocol.self])
        let client = OpenAIClient(config: config, apiKey: key, session: session, backoff: AIBackoff(sleep: { _ in }))
        let defaults = UserDefaults(suiteName: "t-" + UUID().uuidString)!
        let consent = AIConsentStore(defaults: defaults)
        consent.grant("o", categories: ["text"])
        return (client, consent.authorize("o")!)
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

    @Test func streamsTextAndSendsFunctionToolsAndBearer() async throws {
        let host = StubURLProtocol.uniqueHost()
        let (client, grant) = makeClient(baseURL: "https://\(host)/v1", key: "sk-xyz")
        StubURLProtocol.register(host: host) { _, _ in
            StubResponse(statusCode: 200, headers: [:], body: AIStubWire.openAIText(["Hi ", "there."]))
        }
        defer { StubURLProtocol.unregister(host: host) }
        let events = try await collect(client.stream(request(), grant: grant))
        let text = events.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        #expect(text == "Hi there.")

        let headers = StubURLProtocol.captured(host: host).first?.headers ?? [:]
        #expect(headers["Authorization"] == "Bearer sk-xyz")
        let body = try bodyJSON(host: host)
        #expect(body["model"] as? String == "gpt-test")
        #expect(body["stream"] as? Bool == true)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.allSatisfy { ($0["type"] as? String) == "function" })
        let function = try #require(tools.first?["function"] as? [String: Any])
        #expect(function["name"] != nil)
        #expect(function["parameters"] != nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "system")
    }

    @Test func runsToolCallLoopFromFragmentsEndingInDone() async throws {
        let host = StubURLProtocol.uniqueHost()
        let (client, grant) = makeClient(baseURL: "https://\(host)/v1")
        StubURLProtocol.register(host: host) { _, attempt in
            if attempt == 0 {
                return StubResponse(statusCode: 200, headers: [:], body: AIStubWire.openAIToolCall(id: "call-1", name: "findText", argumentFragments: ["{\"que", "ry\":\"wor", "ld\"}"]))
            }
            return StubResponse(statusCode: 200, headers: [:], body: AIStubWire.openAIText(["Found it."]))
        }
        defer { StubURLProtocol.unregister(host: host) }
        let events = try await collect(client.stream(request(lines: ["hello world"]), grant: grant))
        #expect(events.contains(.toolUsed("Find text")))
        let text = events.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        #expect(text == "Found it.")
        #expect(StubURLProtocol.attemptCount(host: host) == 2)

        // Second request carries the assistant tool_calls turn and a tool message.
        let body = try bodyJSON(host: host, at: 1)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { ($0["role"] as? String) == "assistant" })
        let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
        #expect(calls.first?["id"] as? String == "call-1")
        let toolMessage = try #require(messages.first { ($0["role"] as? String) == "tool" })
        #expect(toolMessage["tool_call_id"] as? String == "call-1")
    }

    @Test func contentFilterFinishYieldsRefusal() async throws {
        let host = StubURLProtocol.uniqueHost()
        let (client, grant) = makeClient(baseURL: "https://\(host)/v1")
        StubURLProtocol.register(host: host) { _, _ in
            StubResponse(statusCode: 200, headers: [:], body: AIStubWire.openAIText([], finishReason: "content_filter"))
        }
        defer { StubURLProtocol.unregister(host: host) }
        let events = try await collect(client.stream(request(), grant: grant))
        #expect(events.contains(.refusal))
    }

    @Test func localEndpointAllowsEmptyKeyAndOmitsAuthorization() async throws {
        // A loopback host over http with no key is permitted (Ollama / LM Studio).
        let (client, grant) = makeClient(baseURL: "http://localhost:11434/v1", kind: .openAICompatible, key: "")
        StubURLProtocol.register(host: "localhost") { _, _ in
            StubResponse(statusCode: 200, headers: [:], body: AIStubWire.openAIText(["ok"]))
        }
        defer { StubURLProtocol.unregister(host: "localhost") }
        let events = try await collect(client.stream(request(), grant: grant))
        let text = events.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        #expect(text == "ok")
        let headers = StubURLProtocol.captured(host: "localhost").first?.headers ?? [:]
        #expect(headers["Authorization"] == nil)
    }

    @Test func remoteEndpointRequiresKey() async throws {
        let host = StubURLProtocol.uniqueHost()
        let (client, grant) = makeClient(baseURL: "https://\(host)/v1", key: "")
        // No registration needed: it must fail before any request.
        await #expect(throws: ProviderError.missingKey) {
            _ = try await collect(client.stream(request(), grant: grant))
        }
    }
}
