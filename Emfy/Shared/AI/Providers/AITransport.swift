import Foundation

// MARK: - Transport safety (A2a)
//
// HTTPS is required for every non-local host. Plain http:// is allowed ONLY for
// loopback hosts (127.0.0.1, ::1, localhost) so Ollama / LM Studio work. An
// ephemeral URLSession carries no cookies or caches, has timeouts, and the SSE
// reader enforces a hard response-size cap. The session's protocol classes are
// injectable so tests stub the network with `URLProtocol` and never make a real
// call.

enum AITransport {

    /// The loopback hosts plain http:// is permitted for.
    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        if h == "127.0.0.1" || h == "::1" || h == "[::1]" { return true }
        if h.hasPrefix("127.") { return true }
        return false
    }

    /// Rejects a plain-http URL to a non-loopback host. HTTPS always passes.
    static func validate(_ url: URL) throws {
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "https" { return }
        if scheme == "http", let host = url.host, isLoopback(host) { return }
        throw ProviderError.insecureURL
    }

    /// An ephemeral session: no cookies, no cache, with timeouts. `protocolClasses`
    /// lets tests inject a `URLProtocol` stub.
    static func makeSession(
        protocolClasses: [AnyClass]? = nil,
        requestTimeout: TimeInterval = 60,
        resourceTimeout: TimeInterval = 300
    ) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        if let protocolClasses { config.protocolClasses = protocolClasses }
        return URLSession(configuration: config)
    }

    /// Reads an SSE byte stream, enforcing the size cap, and calls `onEvent` for
    /// each complete event. Line splitting (LF/CR/CRLF) lives in `SSEParser`, fed
    /// one raw byte at a time; a trailing event is flushed at end of stream.
    static func forEachSSEEvent(
        in bytes: URLSession.AsyncBytes,
        cap: Int = AIProviderLimits.maxResponseBytes,
        _ onEvent: (SSEEvent) async throws -> Void
    ) async throws {
        var parser = SSEParser()
        var total = 0
        for try await byte in bytes {
            total += 1
            if total > cap { throw ProviderError.transport("response too large") }
            if let event = parser.consume(byte: byte) { try await onEvent(event) }
        }
        if let event = parser.finish() { try await onEvent(event) }
    }

    /// Reads a (capped) error/non-stream body as text.
    static func readBody(_ bytes: URLSession.AsyncBytes, cap: Int = AIProviderLimits.maxResponseBytes) async throws -> String {
        var buffer: [UInt8] = []
        var total = 0
        for try await byte in bytes {
            total += 1
            if total > cap { break }
            buffer.append(byte)
        }
        return decode(buffer)
    }

    private static func decode(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Shared request/retry (both wire formats)

    /// Sends a request, returning a 200 streaming body, or throwing a typed error.
    /// Retries 429/529/5xx and connection failures up to `maxRetries`, honouring
    /// `retry-after`. Both Anthropic and OpenAI error bodies share the
    /// `{"error":{"message":…,"type":…}}` shape, so one parser serves both.
    static func sendWithRetry(
        session: URLSession,
        request: URLRequest,
        backoff: AIBackoff,
        maxRetries: Int
    ) async throws -> (HTTPURLResponse, URLSession.AsyncBytes) {
        var attempt = 0
        while true {
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ProviderError.transport("no response")
                }
                if http.statusCode == 200 { return (http, bytes) }
                let bodyText = try await readBody(bytes)
                let parsed = parseError(bodyText)
                let error = ProviderError.from(status: http.statusCode, errorType: parsed.type, message: parsed.message)
                if error.isRetryable, attempt < maxRetries {
                    await backoff.sleep(backoff.delay(attempt: attempt, retryAfter: retryAfter(http)))
                    attempt += 1
                    continue
                }
                throw error
            } catch let error as ProviderError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt < maxRetries {
                    await backoff.sleep(backoff.delay(attempt: attempt, retryAfter: nil))
                    attempt += 1
                    continue
                }
                throw ProviderError.transport(error.localizedDescription)
            }
        }
    }

    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "retry-after"),
              let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return seconds
    }

    /// Parses `{"error":{"type":…,"message":…}}` (Anthropic wraps this under a
    /// top-level `"type":"error"`; OpenAI uses the same `error` object).
    static func parseError(_ body: String) -> (type: String?, message: String?) {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else {
            return (nil, nil)
        }
        return (error["type"] as? String, error["message"] as? String)
    }
}

/// How long to wait before a retry. Injectable so tests record the delay rather
/// than sleeping (no real network, no real waiting).
struct AIBackoff: Sendable {
    /// Sleeps for a duration. Defaults to `Task.sleep`.
    var sleep: @Sendable (TimeInterval) async -> Void

    init(sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }) {
        self.sleep = sleep
    }

    /// The delay for attempt `n` (0-based): honour the server's `retry-after` when
    /// present, else exponential backoff (0.5s, 1s, 2s) capped at 8s.
    func delay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter, retryAfter > 0 { return min(retryAfter, 30) }
        return min(0.5 * pow(2, Double(attempt)), 8)
    }
}
