import Foundation

// MARK: - Typed provider errors (A2a)
//
// Every provider failure maps to one `ProviderError` with a short, friendly
// message. Errors NEVER carry the API key or drawing content. The messages are
// user-facing (shown in A2b), so they stay plain and blameless.

enum ProviderError: Error, Equatable, Sendable {
    /// Consent has not been granted for this provider id; the send is refused by
    /// the core before anything leaves the device.
    case consentRequired(providerID: String)
    /// The base URL is plain `http://` for a non-loopback host (HTTPS required).
    case insecureURL
    /// The host is a LAN / private-network destination and this is iOS, where LAN
    /// AI is not allowed (owner decision; S-8).
    case lanBlocked
    /// No API key is configured for a provider that needs one.
    case missingKey
    /// The request body couldn't be built.
    case encodingFailed
    /// 400 invalid request.
    case invalidRequest(String)
    /// 401 authentication failure (bad or missing key).
    case authentication
    /// 402 billing problem.
    case billing
    /// 403 permission denied.
    case permission
    /// 404 not found (wrong endpoint or model).
    case notFound
    /// 429 rate limited (retryable).
    case rateLimited
    /// 5xx server error (500 etc.).
    case server(Int)
    /// 529 overloaded (retryable).
    case overloaded
    /// The model declined the request (Anthropic `stop_reason == "refusal"`, or an
    /// OpenAI content filter).
    case refusal
    /// The response exceeded the size cap, or the connection failed.
    case transport(String)
    /// The tool loop hit its iteration cap without finishing.
    case toolLoopExhausted
    /// Anything else, with a short reason.
    case other(String)

    /// Whether a retry (with backoff) is worthwhile: 429, 529, 5xx and connection
    /// failures are; the rest are not.
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .server, .transport:
            return true
        default:
            return false
        }
    }

    /// A short, friendly, key-free message for the user.
    var friendlyMessage: String {
        switch self {
        case .consentRequired:
            return "Allow this provider before sending the drawing to it."
        case .insecureURL:
            return "This provider's address isn't secure. Use an https:// address, or a local endpoint."
        case .lanBlocked:
            return "Local-network AI providers aren't available on iPhone or iPad. Use a provider with an https:// address."
        case .missingKey:
            return "Add an API key for this provider in Settings."
        case .encodingFailed:
            return "Emfy couldn't prepare the request. Please try again."
        case .invalidRequest:
            return "The provider rejected the request. Check the model name and settings."
        case .authentication:
            return "The API key was rejected. Check it in Settings."
        case .billing:
            return "The provider reported a billing problem with this account."
        case .permission:
            return "This account isn't allowed to use that model."
        case .notFound:
            return "The provider or model wasn't found. Check the address and model."
        case .rateLimited:
            return "The provider is rate-limiting right now. Try again shortly."
        case .server:
            return "The provider had a server error. Try again shortly."
        case .overloaded:
            return "The provider is overloaded right now. Try again shortly."
        case .refusal:
            return "The provider declined this request."
        case .transport:
            return "Emfy couldn't reach the provider. Check your connection and the address."
        case .toolLoopExhausted:
            return "The assistant took too many steps. Try asking a simpler question."
        case .other:
            return "Something went wrong with the provider. Please try again."
        }
    }

    /// Maps an HTTP status (and an optional provider error-type string) to a typed
    /// error. Used for both wire formats.
    static func from(status: Int, errorType: String? = nil, message: String? = nil) -> ProviderError {
        switch status {
        case 400: return .invalidRequest(message ?? "")
        case 401: return .authentication
        case 402: return .billing
        case 403: return .permission
        case 404: return .notFound
        case 408, 409: return .transport("request \(status)")
        case 429: return .rateLimited
        case 529: return .overloaded
        case 500...599: return .server(status)
        default: return .other("HTTP \(status)")
        }
    }
}
