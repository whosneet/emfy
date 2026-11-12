import Foundation
import FoundationModels

// MARK: - Session factory and friendly errors (A1a)
//
// One place that builds a grounded `LanguageModelSession` (system instructions +
// the read-only tools) and turns Foundation Models errors — including guardrail
// refusals — into short, friendly messages. Gated to macOS 26 / iOS 26; the UI
// reaches it only inside an `#available` check.

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
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .guardrailViolation, .refusal:
                return "The on-device model declined to answer that one. Try asking a different way."
            case .exceededContextWindowSize:
                return "This drawing has too much text for the on-device model to take in at once. Try asking about part of it."
            case .rateLimited:
                return "The on-device model is busy right now. Try again in a moment."
            case .unsupportedLanguageOrLocale:
                return "The on-device model doesn’t support this language yet."
            default:
                return genericFailure
            }
        }
        return genericFailure
    }

    /// Whether an error is a guardrail refusal (the model declining), so callers can
    /// log the injection-probe outcome distinctly.
    static func isRefusal(_ error: Error) -> Bool {
        guard let generation = error as? LanguageModelSession.GenerationError else { return false }
        switch generation {
        case .guardrailViolation, .refusal:
            return true
        default:
            return false
        }
    }

    private static let genericFailure = "Something went wrong with the on-device model. Please try again."
}
