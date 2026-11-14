import Foundation

// MARK: - The consent-gated provider router (A2a)
//
// The single send path A2b routes through. It enforces the consent gate IN THE
// CORE: every send first asks `AIConsentStore.authorize`, which yields an
// `AIConsentGrant` only when consent is recorded. Without a grant it throws
// `.consentRequired`; and because a client's `stream` cannot be called without a
// grant (whose initialiser is file-private to `AIConsentStore`), the gate cannot
// be bypassed. The router also owns provider removal (delete key + consent) and
// consent revocation. No drawing bytes or images ever pass through — only the
// bounded, fenced request the caller built.

struct AIProviderService: Sendable {
    var keyStore: AIKeyStore
    var consentStore: AIConsentStore
    /// Builds the URLSession for a send; injectable so tests supply a stub.
    var sessionFactory: @Sendable () -> URLSession
    var backoff: AIBackoff

    init(
        keyStore: AIKeyStore = KeychainKeyStore(),
        consentStore: AIConsentStore = AIConsentStore(),
        sessionFactory: @escaping @Sendable () -> URLSession = { AITransport.makeSession() },
        backoff: AIBackoff = AIBackoff()
    ) {
        self.keyStore = keyStore
        self.consentStore = consentStore
        self.sessionFactory = sessionFactory
        self.backoff = backoff
    }

    /// Streams an answer for a configured provider. Throws `.consentRequired`
    /// before anything leaves the device when consent is absent.
    func stream(config: AIProviderConfig, request: AIProviderRequest) throws -> AsyncThrowingStream<AIProviderEvent, Error> {
        // Enforce consent PER PURPOSE (S-4): the request lists the categories it
        // actually sends, and the gate requires all of them to be covered by the
        // recorded grant — not merely that some consent exists.
        guard let grant = consentStore.authorize(config.id, requiring: request.requiredCategories) else {
            throw ProviderError.consentRequired(providerID: config.id)
        }
        let key = (try? keyStore.key(for: config.id)).flatMap { $0 } ?? ""
        let session = sessionFactory()
        let client = makeClient(config: config, key: key, session: session)
        return client.stream(request, grant: grant)
    }

    private func makeClient(config: AIProviderConfig, key: String, session: URLSession) -> any AIProviderClient {
        switch config.kind {
        case .anthropic:
            return AnthropicClient(config: config, apiKey: key, session: session, backoff: backoff)
        case .openAI, .openAICompatible:
            return OpenAIClient(config: config, apiKey: key, session: session, backoff: backoff)
        }
    }

    /// Removes a provider entirely: deletes its key AND its consent.
    func removeProvider(_ providerID: String) throws {
        try keyStore.deleteKey(for: providerID)
        consentStore.revoke(providerID)
    }

    /// Revokes consent for a provider (the key stays until the provider is removed).
    func revokeConsent(_ providerID: String) {
        consentStore.revoke(providerID)
    }
}

// MARK: - Request building (shared fencing with the on-device path)
//
// Builds the provider request from the same bounded context and the same
// data-fencing prompts the Foundation Models path uses (`DrawingAIPrompt`), with
// the same four read-only tools. This is why the provider path inherits the
// injection defence unchanged: untrusted drawing text stays inside the
// `<drawing-content>` markers, and the refusal rule is in the system instructions.

enum AIProviderRequestBuilder {
    /// An Ask turn grounded in the drawing (first turn: carries the fenced data).
    static func ask(question: String, bundle: DrawingAIContextProvider.Bundle, model: String, streaming: Bool = true) -> AIProviderRequest {
        AIProviderRequest(
            system: DrawingAIPrompt.instructions,
            userPrompt: DrawingAIPrompt.askPrompt(question: question, context: bundle.context),
            tools: AIProviderTools.all(data: bundle.toolData),
            model: model,
            streaming: streaming,
            // Ask sends the drawing data AND the user's question (S-4).
            requiredCategories: [.drawingText, .formatAndPage, .recordCounts, .question]
        )
    }

    /// A Describe turn grounded in the drawing.
    static func describe(bundle: DrawingAIContextProvider.Bundle, model: String, streaming: Bool = true) -> AIProviderRequest {
        AIProviderRequest(
            system: DrawingAIPrompt.instructions,
            userPrompt: DrawingAIPrompt.describePrompt(for: bundle.context),
            tools: AIProviderTools.all(data: bundle.toolData),
            model: model,
            streaming: streaming,
            // Describe sends the drawing data but no question (S-4).
            requiredCategories: [.drawingText, .formatAndPage, .recordCounts]
        )
    }
}
