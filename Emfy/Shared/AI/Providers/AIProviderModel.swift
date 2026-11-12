import Foundation

// MARK: - AI provider model (A2a)
//
// The value types that describe a configured cloud/local AI provider: the kind
// (Anthropic Messages, OpenAI Chat Completions, or any OpenAI-compatible
// endpoint), and a per-provider configuration. Keys are NEVER stored here — they
// live only in the Keychain (`AIKeyStore`). A `Config` is safe to log, persist in
// UserDefaults, or include in a diagnostic; it carries no secret.
//
// This slice (A2a) is the in-house HTTP core only; Settings, the consent UI and
// the Describe/Ask routing come in A2b. No third-party SDKs — Swift has no
// official Anthropic/OpenAI SDK, and CLAUDE.md forbids dependencies.

/// Which wire protocol a provider speaks.
enum AIProviderKind: String, Codable, Sendable, CaseIterable {
    /// Anthropic Messages API (`/v1/messages`, `x-api-key`).
    case anthropic
    /// OpenAI Chat Completions (`/v1/chat/completions`, `Authorization: Bearer`).
    case openAI
    /// Any OpenAI-compatible Chat Completions endpoint (Ollama, LM Studio,
    /// OpenRouter, a localhost server). Same wire format as `openAI`; a distinct
    /// kind so the UI can default the base URL and allow an empty key for local
    /// hosts.
    case openAICompatible
}

/// A configured provider the user can send to. No API key field — the key is held
/// in the Keychain, keyed by `id`.
struct AIProviderConfig: Codable, Sendable, Equatable, Identifiable {
    /// A stable identifier, the Keychain account and the consent key.
    var id: String
    var kind: AIProviderKind
    /// The user-facing name ("Claude", "My Ollama", …).
    var displayName: String
    /// The API base URL. For Anthropic this is the fixed messages host; for the
    /// OpenAI kinds it is the endpoint root the path is appended to.
    var baseURL: URL
    /// The model identifier to request.
    var model: String

    init(id: String = UUID().uuidString, kind: AIProviderKind, displayName: String, baseURL: URL, model: String) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.baseURL = baseURL
        self.model = model
    }
}

// MARK: - Presets

/// Verified endpoints and model identifiers (A2a brief, from Anthropic's and
/// OpenAI's current references). Exact IDs, no date suffixes.
enum AIProviderPresets {

    // Anthropic.
    static let anthropicBaseURL = URL(string: "https://api.anthropic.com")!
    static let anthropicVersion = "2026-10-21"
    /// The server-side refusal-fallback beta, sent only for the default opus model.
    static let anthropicFallbackBeta = "server-side-fallback-2026-07-01"
    /// The default Anthropic model.
    static let anthropicDefaultModel = "claude-opus-5-5"
    /// Offered alternatives plus a free-text field in A2b.
    static let anthropicModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
    /// The model that gets the server-side refusal fallback.
    static let anthropicFallbackModel = "claude-opus-5-5"

    // OpenAI and compatible base URLs.
    static let openAIBaseURL = URL(string: "https://api.openai.com/v1")!
    static let openRouterBaseURL = URL(string: "https://openrouter.ai/api/v1")!
    static let ollamaBaseURL = URL(string: "http://localhost:11434/v1")!
    static let lmStudioBaseURL = URL(string: "http://localhost:1234/v1")!
}
