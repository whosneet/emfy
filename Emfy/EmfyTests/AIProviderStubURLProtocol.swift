import Foundation

// A2a test harness: a URLProtocol stub so provider tests never touch the network
// and never use a real key. It captures each outgoing request (URL, method,
// headers, and body — read from the body stream URLSession substitutes for
// httpBody) and replies with a scripted status, headers and SSE body chunks.
// Thread-safe statics (the system instantiates URLProtocol off the test thread).

struct StubResponse: Sendable {
    var statusCode: Int
    var headers: [String: String]
    /// Body delivered as one or more chunks (to exercise chunk-boundary parsing).
    var chunks: [Data]

    init(statusCode: Int = 200, headers: [String: String] = [:], body: Data = Data(), chunks: [Data]? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.chunks = chunks ?? [body]
    }
}

struct CapturedRequest: Sendable {
    var url: URL?
    var method: String?
    var headers: [String: String]
    var body: Data
}

// A per-host handler registry keyed by the request URL's host, so tests running
// in parallel (Swift Testing's default) never clobber each other: each test uses
// a unique host via `StubURLProtocol.uniqueHost()`.
final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest, Int) -> StubResponse] = [:]
    nonisolated(unsafe) private static var capturedByKey: [String: [CapturedRequest]] = [:]
    nonisolated(unsafe) private static var attemptsByKey: [String: Int] = [:]

    /// A unique host for one test's registration.
    static func uniqueHost() -> String { "t-\(UUID().uuidString.prefix(12).lowercased()).test" }

    /// Registers a handler for a host and clears its prior state.
    static func register(host: String, _ handler: @escaping @Sendable (URLRequest, Int) -> StubResponse) {
        lock.lock(); defer { lock.unlock() }
        handlers[host] = handler
        capturedByKey[host] = []
        attemptsByKey[host] = 0
    }

    static func unregister(host: String) {
        lock.lock(); defer { lock.unlock() }
        handlers[host] = nil
        capturedByKey[host] = nil
        attemptsByKey[host] = nil
    }

    static func captured(host: String) -> [CapturedRequest] {
        lock.lock(); defer { lock.unlock() }
        return capturedByKey[host] ?? []
    }

    static func attemptCount(host: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return attemptsByKey[host] ?? 0
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        lock.lock(); defer { lock.unlock() }
        return handlers[host] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (handler, attempt) = Self.recordAndNext(for: request)
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let stub = handler(request, attempt)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://invalid")!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks where !chunk.isEmpty {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func recordAndNext(for request: URLRequest) -> (handler: (@Sendable (URLRequest, Int) -> StubResponse)?, attempt: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let host = request.url?.host else { return (nil, 0) }
        let attempt = attemptsByKey[host] ?? 0
        attemptsByKey[host] = attempt + 1
        capturedByKey[host, default: []].append(CapturedRequest(
            url: request.url,
            method: request.httpMethod,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.bodyData(from: request)
        ))
        return (handlers[host], attempt)
    }

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 8192
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - SSE wire builders

enum AIStubWire {
    /// Anthropic/named-event SSE: `event: name\n data: json\n\n`.
    static func sse(_ events: [(event: String?, data: String)]) -> Data {
        var text = ""
        for event in events {
            if let name = event.event { text += "event: \(name)\n" }
            text += "data: \(event.data)\n\n"
        }
        return Data(text.utf8)
    }

    /// A minimal Anthropic text answer ending in `end_turn`.
    static func anthropicText(_ pieces: [String], stopReason: String = "end_turn") -> Data {
        var events: [(String?, String)] = [
            ("message_start", #"{"type":"message_start","message":{"id":"m","role":"assistant"}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
        ]
        for piece in pieces {
            events.append(("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(piece)"}}"#))
        }
        events.append(("content_block_stop", #"{"type":"content_block_stop","index":0}"#))
        events.append(("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"\#(stopReason)"},"usage":{}}"#))
        events.append(("message_stop", #"{"type":"message_stop"}"#))
        return sse(events)
    }

    /// An Anthropic turn that calls one tool, then stops with `tool_use`.
    static func anthropicToolUse(id: String, name: String, inputJSON: String) -> Data {
        // Split the input JSON across two input_json_delta fragments.
        let mid = inputJSON.index(inputJSON.startIndex, offsetBy: inputJSON.count / 2)
        let first = String(inputJSON[inputJSON.startIndex..<mid])
        let second = String(inputJSON[mid...])
        return sse([
            ("message_start", #"{"type":"message_start","message":{"id":"m","role":"assistant"}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":\#(jsonString(first))}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":\#(jsonString(second))}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
    }

    static func anthropicError(type: String, message: String) -> Data {
        Data(#"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#.utf8)
    }

    /// OpenAI chunked stream: `data: {json}\n\n` … ending with `data: [DONE]`.
    static func openAIText(_ pieces: [String], finishReason: String = "stop") -> Data {
        var events: [(String?, String)] = []
        for piece in pieces {
            events.append((nil, #"{"choices":[{"index":0,"delta":{"content":"\#(piece)"},"finish_reason":null}]}"#))
        }
        events.append((nil, #"{"choices":[{"index":0,"delta":{},"finish_reason":"\#(finishReason)"}]}"#))
        events.append((nil, "[DONE]"))
        return sse(events)
    }

    /// An OpenAI turn that streams one tool call in argument fragments, then stops
    /// with `tool_calls`.
    static func openAIToolCall(id: String, name: String, argumentFragments: [String]) -> Data {
        var events: [(String?, String)] = [
            (nil, #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"\#(id)","type":"function","function":{"name":"\#(name)","arguments":""}}]},"finish_reason":null}]}"#),
        ]
        for fragment in argumentFragments {
            events.append((nil, #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":\#(jsonString(fragment))}}]},"finish_reason":null}]}"#))
        }
        events.append((nil, #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#))
        events.append((nil, "[DONE]"))
        return sse(events)
    }

    /// JSON-encodes a string (with quotes) for safe embedding in a larger JSON.
    static func jsonString(_ raw: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [raw], options: [])
        var text = String(decoding: data, as: UTF8.self)
        text.removeFirst() // [
        text.removeLast()  // ]
        return text
    }
}
