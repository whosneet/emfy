import Foundation

// MARK: - Unified provider client (A2a)
//
// The one protocol A2b routes Describe/Ask/titles through, whatever the provider.
// It takes the SAME bounded, data-fenced prompt the on-device path uses
// (`DrawingAIPrompt`) and the SAME four read-only tools (`AIProviderTools`),
// mapped to each wire format. It streams text and reports which tools ran. Nothing
// beyond the bounded context is ever sent: no file bytes, no images — the request
// carries only the fenced `system`/`userPrompt` strings and the tool definitions.

/// A tiny JSON value for tool input/output and for request bodies that mix shapes.
/// Parsed from the wire with `JSONSerialization`; never string-matched.
indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Wraps a Foundation JSON object (`Any` from `JSONSerialization`).
    init(any: Any) {
        switch any {
        case let n as NSNumber:
            // `JSONSerialization` returns booleans as CFBoolean-backed NSNumbers;
            // distinguish them from real numbers by the CF type id.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map(JSONValue.init(any:)))
        case let o as [String: Any]:
            self = .object(o.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    /// Converts to a Foundation object for `JSONSerialization`.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    var intValue: Int? { if case .number(let n) = self { return Int(n) } else { return nil } }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }

    /// Parses a JSON object string into `[String: JSONValue]`, or nil if it isn't a
    /// JSON object. Robust to empty/whitespace input (tool calls with no arguments).
    static func parseObject(_ json: String) -> [String: JSONValue]? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else {
            return nil
        }
        return object.mapValues(JSONValue.init(any:))
    }
}

/// The result of running a tool: a text payload and whether it is an error (which
/// is reported back to the model so it can recover).
struct AIToolOutcome: Sendable, Equatable {
    var content: String
    var isError: Bool

    static func ok(_ content: String) -> AIToolOutcome { .init(content: content, isError: false) }
    static func error(_ content: String) -> AIToolOutcome { .init(content: content, isError: true) }
}

/// A read-only tool as the provider path sees it: a wire name, a display name (for
/// the "Used:" footnote), a description, a JSON-Schema input object, and a runner
/// that answers from the drawing's bounded snapshot. Mirrors the on-device tools'
/// semantics (`DrawingAITools`).
struct AIProviderTool: Sendable {
    let name: String
    let displayName: String
    let description: String
    /// The JSON-Schema object: `{ "type": "object", "properties": …, "required": … }`.
    let inputSchema: JSONValue
    let run: @Sendable ([String: JSONValue]) async -> AIToolOutcome

    /// Validates parsed tool input against this tool's schema: every `required`
    /// property must be present. Invalid input is rejected before the tool runs so
    /// the model gets an `is_error` result instead of a bad call.
    func validate(_ input: [String: JSONValue]) -> Bool {
        guard case .object(let schema) = inputSchema else { return true }
        guard case .array(let required)? = schema["required"] else { return true }
        for case .string(let key) in required where input[key] == nil {
            return false
        }
        return true
    }
}

/// A single send: the fenced system instructions, the fenced user prompt, the
/// tools, and the model. One turn; the client runs the internal tool loop.
struct AIProviderRequest: Sendable {
    var system: String
    var userPrompt: String
    var tools: [AIProviderTool]
    var model: String
    /// Whether to stream (SSE). The viewer always streams; false is for a one-shot.
    var streaming: Bool

    init(system: String, userPrompt: String, tools: [AIProviderTool], model: String, streaming: Bool = true) {
        self.system = system
        self.userPrompt = userPrompt
        self.tools = tools
        self.model = model
        self.streaming = streaming
    }
}

/// What the client streams back to A2b.
enum AIProviderEvent: Sendable, Equatable {
    /// An incremental text delta of the assistant's answer.
    case text(String)
    /// A tool was run; the value is its display name (for the "Used:" footnote).
    case toolUsed(String)
    /// The model declined the request.
    case refusal
}

/// The unified client every provider implements. A2b builds one via
/// `AIProviderService` (which enforces consent) and consumes the stream.
protocol AIProviderClient: Sendable {
    /// Streams the answer for a request. Requires an `AIConsentGrant`, which only
    /// `AIConsentStore.authorize` can mint — so a client cannot be driven without
    /// recorded consent.
    func stream(_ request: AIProviderRequest, grant: AIConsentGrant) -> AsyncThrowingStream<AIProviderEvent, Error>
}

/// The maximum tool-loop iterations, shared by both wire formats (A2a brief).
enum AIProviderLimits {
    static let maxToolIterations = 6
    /// The response size cap (bytes) — a hostile or runaway stream is cut off.
    static let maxResponseBytes = 8 * 1024 * 1024
    /// `max_tokens` when streaming / not streaming (Anthropic requires it).
    static let streamingMaxTokens = 64000
    static let nonStreamingMaxTokens = 16000
}
