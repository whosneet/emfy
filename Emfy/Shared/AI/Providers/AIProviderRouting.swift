import Foundation

// MARK: - Routing Describe / Ask / Explain to the selected engine (A2b)
//
// Small, testable glue between the AI view models and the provider core: the consent
// preflight (so a provider send presents the consent screen instead of failing
// silently), the engine footnote label, and the stream consumer that turns
// `AIProviderEvent`s into the same incremental text/tool updates the on-device path
// produces. The on-device path is untouched; only the provider branch runs through
// here.

/// The footnote label for an answer: which engine produced it.
enum AIEngineLabel {
    static func text(for engine: AIEngineChoice) -> String {
        switch engine {
        case .onDevice:
            return "On-device · Apple Intelligence"
        case .provider(let config):
            return "via \(config.displayName) · \(config.model)"
        }
    }
}

/// The consent preflight. A provider send is only ready when consent is recorded;
/// otherwise the caller presents the consent screen (never a silent failure).
enum AIProviderPreflight {
    enum Outcome: Equatable {
        case ready
        /// Consent is required for this provider before the drawing can be sent.
        case needsConsent(AIProviderConfig)
    }

    static func check(engine: AIEngineChoice, consentGranted: (String) -> Bool) -> Outcome {
        switch engine {
        case .onDevice:
            return .ready
        case .provider(let config):
            return consentGranted(config.id) ? .ready : .needsConsent(config)
        }
    }
}

/// Consumes a provider stream on the main actor, delivering the accumulated text and
/// the tool display names, and returning whether the model refused. Throws the typed
/// `ProviderError` (including `.consentRequired`) so the caller maps it to a friendly
/// message or the consent screen.
enum DrawingAIProviderRun {
    @MainActor
    static func stream(
        service: AIProviderService,
        config: AIProviderConfig,
        request: AIProviderRequest,
        onText: @escaping @MainActor (String) -> Void,
        onTool: @escaping @MainActor (String) -> Void
    ) async throws -> Bool {
        let stream = try service.stream(config: config, request: request)
        var accumulated = ""
        var refused = false
        for try await event in stream {
            switch event {
            case .text(let piece):
                accumulated += piece
                onText(accumulated)
            case .toolUsed(let name):
                onTool(name)
            case .refusal:
                refused = true
            }
        }
        return refused
    }
}

// MARK: - Request builders for the provider path

extension AIProviderRequestBuilder {
    /// An Explain-what's-missing turn: grounded ONLY in the diagnostics items (no
    /// drawing text), with no tools, mirroring the on-device Explain session.
    static func explain(items: [String], model: String, streaming: Bool = true) -> AIProviderRequest {
        AIProviderRequest(
            system: DrawingAIPrompt.structuredInstructions,
            userPrompt: DrawingAIPrompt.explainMissingPrompt(items: items),
            tools: [],
            model: model,
            streaming: streaming
        )
    }

    /// A Test-connection turn: a trivial no-drawing prompt. Still routed through the
    /// consent-gated core, so Test connection needs consent like any other send.
    static func testConnection(model: String) -> AIProviderRequest {
        AIProviderRequest(
            system: "You are a connection test. Reply with exactly: OK",
            userPrompt: "Reply with OK",
            tools: [],
            model: model,
            streaming: true
        )
    }
}
