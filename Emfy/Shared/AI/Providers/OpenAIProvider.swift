import Foundation

// MARK: - OpenAI / OpenAI-compatible Chat Completions client (A2a)
//
// Raw HTTP to POST {baseURL}/chat/completions (no SDK). Works for OpenAI,
// OpenRouter, Ollama and LM Studio (the key is optional for local endpoints).
// Streaming `data: {…}` chunks with `choices[0].delta.content` text and
// `delta.tool_calls[i].function.arguments` fragments, ending with `data: [DONE]`.
// Tool results go back as `{role:"tool", tool_call_id, content}` messages, with
// the same bounded tool loop and the same typed errors/retries as the Anthropic
// path.

struct OpenAIClient: AIProviderClient {
    let config: AIProviderConfig
    let apiKey: String
    let session: URLSession
    var backoff = AIBackoff()
    var maxRetries = 2

    private var endpoint: URL { config.baseURL.appendingPathComponent("chat/completions") }

    func stream(_ request: AIProviderRequest, grant: AIConsentGrant) -> AsyncThrowingStream<AIProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(request, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: AIProviderRequest, continuation: AsyncThrowingStream<AIProviderEvent, Error>.Continuation) async throws {
        try AITransport.validate(endpoint)
        // A key is required unless the endpoint is a loopback (local) host.
        if apiKey.isEmpty, let host = endpoint.host, !AITransport.isLoopback(host) {
            throw ProviderError.missingKey
        }

        let toolsByName = Dictionary(uniqueKeysWithValues: request.tools.map { ($0.name, $0) })
        var messages: [[String: Any]] = [
            ["role": "system", "content": request.system],
            ["role": "user", "content": request.userPrompt],
        ]
        var emittedTools = Set<String>()

        for _ in 0 ..< AIProviderLimits.maxToolIterations {
            try Task.checkCancellation()
            let body = requestBody(for: request, messages: messages)
            let urlRequest = try makeURLRequest(body: body)

            let (_, bytes) = try await AITransport.sendWithRetry(session: session, request: urlRequest, backoff: backoff, maxRetries: maxRetries)
            var assembler = ChatAssembler()

            try await AITransport.forEachSSEEvent(in: bytes) { event in
                try Task.checkCancellation()
                let payload = event.data.trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]" else { return }
                if let text = assembler.ingest(data: payload) {
                    continuation.yield(.text(text))
                }
            }

            if assembler.finishReason == "content_filter" {
                continuation.yield(.refusal)
                return
            }

            messages.append(assembler.assistantMessage())

            guard assembler.finishReason == "tool_calls", !assembler.toolCalls.isEmpty else {
                return // "stop", "length" → done
            }

            for call in assembler.toolCalls {
                let outcome = await runTool(call, toolsByName: toolsByName)
                if let tool = toolsByName[call.name], emittedTools.insert(tool.displayName).inserted {
                    continuation.yield(.toolUsed(tool.displayName))
                }
                messages.append([
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": outcome.content,
                ])
            }
        }
        throw ProviderError.toolLoopExhausted
    }

    private func runTool(_ call: ChatAssembler.ToolCall, toolsByName: [String: AIProviderTool]) async -> AIToolOutcome {
        guard let tool = toolsByName[call.name] else {
            return .error("Unknown tool “\(call.name)”.")
        }
        guard let input = JSONValue.parseObject(call.arguments) else {
            return .error("The tool input was not valid JSON.")
        }
        guard tool.validate(input) else {
            return .error("The tool input was missing a required value.")
        }
        return await tool.run(input)
    }

    // MARK: Request building

    private func requestBody(for request: AIProviderRequest, messages: [[String: Any]]) -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "stream": request.streaming,
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema.anyValue,
                    ],
                ]
            }
        }
        return body
    }

    private func makeURLRequest(body: [String: Any]) throws -> URLRequest {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw ProviderError.encodingFailed
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

// MARK: - Chat Completions stream assembler

private struct ChatAssembler {
    struct ToolCall { var id: String; var name: String; var arguments: String }

    private var text = ""
    private var calls: [Int: ToolCall] = [:]
    private var callOrder: [Int] = []
    private(set) var finishReason: String?

    /// Feeds one `data:` chunk's JSON; returns a text delta to emit, if any.
    mutating func ingest(data: String) -> String? {
        guard let object = JSONValue.parseObject(data),
              case .array(let choices)? = object["choices"],
              let first = choices.first?.objectValue else {
            return nil
        }
        if let reason = first["finish_reason"]?.stringValue { finishReason = reason }
        guard let delta = first["delta"]?.objectValue else { return nil }

        var emitted: String?
        if let content = delta["content"]?.stringValue, !content.isEmpty {
            text += content
            emitted = content
        }
        if case .array(let toolCalls)? = delta["tool_calls"] {
            for case .object(let call) in toolCalls {
                ingestToolCall(call)
            }
        }
        return emitted
    }

    private mutating func ingestToolCall(_ call: [String: JSONValue]) {
        let index = call["index"]?.intValue ?? callOrder.count
        if calls[index] == nil {
            calls[index] = ToolCall(id: "", name: "", arguments: "")
            callOrder.append(index)
        }
        if let id = call["id"]?.stringValue, !id.isEmpty { calls[index]?.id = id }
        if let function = call["function"]?.objectValue {
            if let name = function["name"]?.stringValue, !name.isEmpty { calls[index]?.name = name }
            if let args = function["arguments"]?.stringValue { calls[index]?.arguments += args }
        }
    }

    var toolCalls: [ToolCall] { callOrder.compactMap { calls[$0] } }

    /// The assistant turn to replay: its text and any tool calls.
    func assistantMessage() -> [String: Any] {
        var message: [String: Any] = ["role": "assistant"]
        message["content"] = text.isEmpty ? NSNull() : text
        let orderedCalls = toolCalls
        if !orderedCalls.isEmpty {
            message["tool_calls"] = orderedCalls.map { call -> [String: Any] in
                [
                    "id": call.id,
                    "type": "function",
                    "function": ["name": call.name, "arguments": call.arguments],
                ]
            }
        }
        return message
    }
}
