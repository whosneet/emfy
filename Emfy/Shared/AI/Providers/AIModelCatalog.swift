import Foundation

// MARK: - "Load models" — the provider's model list (A2b)
//
// A single GET to a provider's model-list endpoint so the Settings model picker can
// offer the models an account actually has, instead of a hard-coded list. Anthropic
// and OpenAI (and every OpenAI-compatible endpoint) both answer with a JSON object
// whose `data` array holds `{ "id": … }` entries, so ONE parser serves both; only
// the path and the auth headers differ. This lists model identifiers only — no
// drawing data leaves the device, so (unlike Test connection) it needs no consent.
// The user types a free-text model instead whenever an endpoint has no list.

enum AIModelCatalog {

    /// The model-list endpoint for a provider kind.
    /// Anthropic: `{base}/v1/models`; OpenAI/compatible: `{base}/models`.
    static func endpoint(for config: AIProviderConfig) -> URL {
        switch config.kind {
        case .anthropic:
            return config.baseURL.appendingPathComponent("v1/models")
        case .openAI, .openAICompatible:
            return config.baseURL.appendingPathComponent("models")
        }
    }

    /// Parses a `/models` response body into model identifiers, in the order the
    /// provider returned them. Robust to either shape and to junk: a non-object body,
    /// a missing `data` array, or entries without a string `id` yield an empty list
    /// rather than throwing.
    static func parseModelIDs(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [Any] else {
            return []
        }
        var ids: [String] = []
        for case let entry as [String: Any] in entries {
            if let id = entry["id"] as? String, !id.isEmpty {
                ids.append(id)
            }
        }
        return ids
    }

    /// Fetches the model list for a configured provider. HTTPS is required except for
    /// loopback hosts (local servers). A non-200 maps to a typed `ProviderError`; the
    /// body is read through the shared size cap. The `session` is injectable so tests
    /// stub the network and never make a real call or use a real key.
    static func fetch(config: AIProviderConfig, key: String, session: URLSession) async throws -> [String] {
        let url = endpoint(for: config)
        try AITransport.validate(url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        switch config.kind {
        case .anthropic:
            guard !key.isEmpty else { throw ProviderError.missingKey }
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(AIProviderPresets.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        case .openAI, .openAICompatible:
            // A key is required unless the endpoint is a loopback (local) host.
            if key.isEmpty, let host = url.host, !AITransport.isLoopback(host) {
                throw ProviderError.missingKey
            }
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.transport("no response")
        }
        let body = try await AITransport.readBody(bytes)
        guard http.statusCode == 200 else {
            let parsed = AITransport.parseError(body)
            throw ProviderError.from(status: http.statusCode, errorType: parsed.type, message: parsed.message)
        }
        guard let data = body.data(using: .utf8) else { return [] }
        return parseModelIDs(data)
    }
}
