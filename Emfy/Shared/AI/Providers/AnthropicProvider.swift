import Foundation

// MARK: - Anthropic Messages API client (A2a)
//
// Raw HTTP to POST /v1/messages (no SDK). Verified against Anthropic's current
// reference (A2a brief): anthropic-version 2026-10-21; required max_tokens; no
// temperature / prefill / disabled-thinking / forced tool_choice; the server-side
// refusal fallback for the default opus model; the SSE event set; a bounded
// tool loop that preserves the full assistant turn and returns all tool_results in
// ONE user message; typed errors with 429/529 retries honouring retry-after. It
// ALWAYS checks stop_reason before trusting content, and maps "refusal" to a
// friendly decline.

struct AnthropicClient: AIProviderClient {
    let config: AIProviderConfig
    let apiKey: String
    let session: URLSession
    var backoff = AIBackoff()
    var maxRetries = 2

    private var endpoint: URL { config.baseURL.appendingPathComponent("v1/messages") }

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

    // MARK: Tool loop

    private func run(_ request: AIProviderRequest, continuation: AsyncThrowingStream<AIProviderEvent, Error>.Continuation) async throws {
        try AITransport.validate(endpoint)
        guard !apiKey.isEmpty else { throw ProviderError.missingKey }

        let toolsByName = Dictionary(uniqueKeysWithValues: request.tools.map { ($0.name, $0) })
        var messages: [[String: Any]] = [["role": "user", "content": request.userPrompt]]
        var emittedTools = Set<String>()

        for _ in 0 ..< AIProviderLimits.maxToolIterations {
            try Task.checkCancellation()
            let body = requestBody(for: request, messages: messages)
            let urlRequest = try makeURLRequest(body: body, model: request.model)

            let (_, bytes) = try await AITransport.sendWithRetry(session: session, request: urlRequest, backoff: backoff, maxRetries: maxRetries)
            var assembler = BlockAssembler()
            var streamError: ProviderError?

            try await AITransport.forEachSSEEvent(in: bytes) { event in
                try Task.checkCancellation()
                switch event.event {
                case "error":
                    streamError = Self.parseStreamError(event.data)
                case "content_block_start", "content_block_delta", "content_block_stop", "message_delta":
                    if let text = assembler.ingest(event: event.event ?? "", data: event.data) {
                        continuation.yield(.text(text))
                    }
                default:
                    break // message_start, message_stop, ping
                }
            }

            if let streamError { throw streamError }

            // Always check stop_reason before trusting the content.
            if assembler.stopReason == "refusal" {
                continuation.yield(.refusal)
                return
            }

            // Preserve the FULL assistant turn (text, thinking and tool_use blocks).
            messages.append(["role": "assistant", "content": assembler.assistantContent()])

            guard assembler.stopReason == "tool_use", !assembler.toolUses.isEmpty else {
                return // end_turn, max_tokens, stop_sequence → done
            }

            // Run every requested tool, returning all results in ONE user message.
            var results: [[String: Any]] = []
            for use in assembler.toolUses {
                let outcome = await runTool(use, toolsByName: toolsByName)
                if let tool = toolsByName[use.name], emittedTools.insert(tool.displayName).inserted {
                    continuation.yield(.toolUsed(tool.displayName))
                }
                var block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": use.id,
                    "content": outcome.content,
                ]
                if outcome.isError { block["is_error"] = true }
                results.append(block)
            }
            messages.append(["role": "user", "content": results])
        }
        throw ProviderError.toolLoopExhausted
    }

    private func runTool(_ use: BlockAssembler.ToolUse, toolsByName: [String: AIProviderTool]) async -> AIToolOutcome {
        guard let tool = toolsByName[use.name] else {
            return .error("Unknown tool “\(use.name)”.")
        }
        guard let input = JSONValue.parseObject(use.inputJSON) else {
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
            "max_tokens": request.streaming ? AIProviderLimits.streamingMaxTokens : AIProviderLimits.nonStreamingMaxTokens,
            "system": request.system,
            "messages": messages,
            "stream": request.streaming,
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool -> [String: Any] in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.inputSchema.anyValue,
                ]
            }
        }
        // Server-side refusal fallback for the default opus model only.
        if request.model == AIProviderPresets.anthropicFallbackModel {
            body["fallbacks"] = "default"
        }
        return body
    }

    private func makeURLRequest(body: [String: Any], model: String) throws -> URLRequest {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw ProviderError.encodingFailed
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(AIProviderPresets.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if model == AIProviderPresets.anthropicFallbackModel {
            request.setValue(AIProviderPresets.anthropicFallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        return request
    }

    static func parseStreamError(_ data: String) -> ProviderError {
        let parsed = AITransport.parseError(data)
        return .other(parsed.message ?? parsed.type ?? "stream error")
    }
}

// MARK: - Streaming block assembler
//
// Rebuilds the assistant turn from the SSE events so it can be replayed unchanged
// on the next iteration (required for Anthropic's tool loop), and surfaces text
// deltas and the finished tool_use calls.

private struct BlockAssembler {
    struct ToolUse { var id: String; var name: String; var inputJSON: String }

    private enum Kind { case text, toolUse, thinking, redactedThinking, unknown }
    private struct Block {
        var kind: Kind
        var text = ""
        var toolID = ""
        var toolName = ""
        var inputBuffer = ""
        var signature = ""
        var redactedData = ""
    }

    private var blocks: [Int: Block] = [:]
    private var order: [Int] = []
    private(set) var stopReason: String?

    /// Feeds one content/message event; returns a text delta to emit, if any.
    mutating func ingest(event: String, data: String) -> String? {
        guard let object = JSONValue.parseObject(data) else { return nil }
        switch event {
        case "content_block_start":
            guard let index = object["index"]?.intValue, let block = object["content_block"]?.objectValue else { return nil }
            start(index: index, block: block)
            return nil
        case "content_block_delta":
            guard let index = object["index"]?.intValue, let delta = object["delta"]?.objectValue else { return nil }
            return applyDelta(index: index, delta: delta)
        case "content_block_stop":
            return nil
        case "message_delta":
            if let delta = object["delta"]?.objectValue, let reason = delta["stop_reason"]?.stringValue {
                stopReason = reason
            }
            return nil
        default:
            return nil
        }
    }

    private mutating func start(index: Int, block: [String: JSONValue]) {
        if blocks[index] == nil { order.append(index) }
        let type = block["type"]?.stringValue
        switch type {
        case "text":
            blocks[index] = Block(kind: .text, text: block["text"]?.stringValue ?? "")
        case "tool_use":
            blocks[index] = Block(kind: .toolUse, toolID: block["id"]?.stringValue ?? "", toolName: block["name"]?.stringValue ?? "")
        case "thinking":
            blocks[index] = Block(kind: .thinking, text: block["thinking"]?.stringValue ?? "")
        case "redacted_thinking":
            blocks[index] = Block(kind: .redactedThinking, redactedData: block["data"]?.stringValue ?? "")
        default:
            blocks[index] = Block(kind: .unknown)
        }
    }

    private mutating func applyDelta(index: Int, delta: [String: JSONValue]) -> String? {
        guard blocks[index] != nil else { return nil }
        switch delta["type"]?.stringValue {
        case "text_delta":
            let piece = delta["text"]?.stringValue ?? ""
            blocks[index]?.text += piece
            return piece.isEmpty ? nil : piece
        case "input_json_delta":
            blocks[index]?.inputBuffer += delta["partial_json"]?.stringValue ?? ""
            return nil
        case "thinking_delta":
            blocks[index]?.text += delta["thinking"]?.stringValue ?? ""
            return nil
        case "signature_delta":
            blocks[index]?.signature += delta["signature"]?.stringValue ?? ""
            return nil
        default:
            return nil
        }
    }

    /// The finished tool_use calls, in order.
    var toolUses: [ToolUse] {
        order.compactMap { index in
            guard let block = blocks[index], block.kind == .toolUse else { return nil }
            return ToolUse(id: block.toolID, name: block.toolName, inputJSON: block.inputBuffer)
        }
    }

    /// The assistant turn's content blocks, replayable unchanged next iteration.
    func assistantContent() -> [[String: Any]] {
        order.compactMap { index -> [String: Any]? in
            guard let block = blocks[index] else { return nil }
            switch block.kind {
            case .text:
                return ["type": "text", "text": block.text]
            case .toolUse:
                let input = JSONValue.parseObject(block.inputBuffer) ?? [:]
                return ["type": "tool_use", "id": block.toolID, "name": block.toolName, "input": JSONValue.object(input).anyValue]
            case .thinking:
                return ["type": "thinking", "thinking": block.text, "signature": block.signature]
            case .redactedThinking:
                return ["type": "redacted_thinking", "data": block.redactedData]
            case .unknown:
                return nil
            }
        }
    }
}
