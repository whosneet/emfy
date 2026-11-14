import Foundation
import FoundationModels

// MARK: - Session factory and friendly errors (A1a; OS-27 errors F1)
//
// One place that builds a grounded `LanguageModelSession` (system instructions +
// the read-only tools) and turns Foundation Models errors — including guardrail
// refusals — into short, friendly messages. Gated to macOS 26 / iOS 26; the UI
// reaches it only inside an `#available` check.
//
// Error types across OS versions (verified against the Xcode 27 FoundationModels
// swiftinterface):
//   - macOS 26 / iOS 26 throw `LanguageModelSession.GenerationError`.
//   - macOS 27 / iOS 27 deprecate it in favour of the top-level
//     `LanguageModelError` (a `@nonexhaustive` enum with `contextSizeExceeded`,
//     `rateLimited`, `guardrailViolation`, `refusal`, `unsupportedLanguageOrLocale`,
//     `timeout`, …). The running OS throws the newer type, so on macOS 27 the old
//     `GenerationError`-only handling fell through to the generic message (F1).
// Both are handled below so the refusal, guardrail and context-size cases map to
// the SAME user messages (and so `isRefusal` catches both, keeping the shared
// on-device refusal message in Edit/Translate/Generate).

@available(macOS 26, iOS 26, *)
enum DrawingAIEngine {

    /// A session grounded in Emfy's instructions and the drawing's read-only tools.
    /// A fresh session per drawing keeps one drawing's text out of another's answers.
    static func makeSession(toolData: DrawingAIToolData) -> LanguageModelSession {
        LanguageModelSession(
            tools: DrawingAITools.all(data: toolData),
            instructions: DrawingAIPrompt.instructions
        )
    }

    /// Whether on-device AI can actually run right now (same gate the UI uses).
    static var isModelAvailable: Bool {
        DrawingAIAvailability.current().isAvailable
    }

    /// A short, friendly message for any generation failure, including guardrail
    /// refusals. Cancellations map to an empty string (the caller treats a stop as
    /// no error).
    static func friendlyMessage(for error: Error) -> String {
        if error is CancellationError { return "" }
        if let message = Classification.of(error)?.message { return message }
        return genericFailure
    }

    /// Whether an error is a guardrail refusal (the model declining), so callers can
    /// log the injection-probe outcome distinctly and Edit/Translate/Generate return
    /// the shared on-device refusal message.
    static func isRefusal(_ error: Error) -> Bool {
        Classification.of(error) == .refusal
    }

    /// Whether `error` came from the on-device model at all (either error type), so
    /// callers can distinguish it from a provider error without matching the
    /// deprecated `GenerationError` directly (F1).
    static func isOnDeviceError(_ error: Error) -> Bool {
        Classification.of(error) != nil
    }

    /// Whether `error` is the on-device model running out of context window, so the
    /// Ask flow can start a fresh session and recover (F2).
    static func isContextOverflow(_ error: Error) -> Bool {
        Classification.of(error) == .contextOverflow
    }

    // MARK: - Classification (one mapping, both error types)

    /// The handful of on-device failure kinds Emfy maps to a user message. One
    /// classifier covers both `GenerationError` (26) and `LanguageModelError`
    /// (27+), so the two share identical messages and refusal/overflow detection.
    private enum Classification {
        case refusal
        case contextOverflow
        case rateLimited
        case unsupportedLanguage
        case other

        var message: String {
            switch self {
            case .refusal:
                return "The on-device model declined to answer that one. Try asking a different way."
            case .contextOverflow:
                return "This drawing has too much text for the on-device model to take in at once. Try asking about part of it."
            case .rateLimited:
                return "The on-device model is busy right now. Try again in a moment."
            case .unsupportedLanguage:
                return "The on-device model doesn’t support this language yet."
            case .other:
                return genericFailure
            }
        }

        /// Classifies `error`, or nil when it is not an on-device model error.
        static func of(_ error: Error) -> Classification? {
            if let generation = error as? LanguageModelSession.GenerationError {
                switch generation {
                case .guardrailViolation, .refusal: return .refusal
                case .exceededContextWindowSize: return .contextOverflow
                case .rateLimited: return .rateLimited
                case .unsupportedLanguageOrLocale: return .unsupportedLanguage
                default: return .other
                }
            }
            if #available(macOS 27, iOS 27, *), let modern = error as? LanguageModelError {
                switch modern {
                case .guardrailViolation, .refusal: return .refusal
                case .contextSizeExceeded: return .contextOverflow
                case .rateLimited: return .rateLimited
                case .unsupportedLanguageOrLocale: return .unsupportedLanguage
                default: return .other
                }
            }
            return nil
        }
    }

    static let genericFailure = "Something went wrong with the on-device model. Please try again."

    /// Shown in Describe, Explain and Summarise when the on-device model finishes a turn
    /// with no text at all (FM-8), so the result isn't a silent blank "done".
    static let emptyAnswer = "The model didn’t return an answer."
}
