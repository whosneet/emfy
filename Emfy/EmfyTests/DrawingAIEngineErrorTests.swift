import Foundation
import FoundationModels
import Testing

// F1: the on-device error mapping must cover BOTH error types — the deprecated
// `LanguageModelSession.GenerationError` (macOS 26 / iOS 26) and the newer
// top-level `LanguageModelError` (macOS 27 / iOS 27). On macOS 27 the model throws
// the newer type, so these tests construct `LanguageModelError` values (their
// subtypes have public inits) and assert the refusal, guardrail and context-size
// cases map to the SAME user messages, that refusals are detected (so Edit /
// Translate / Generate return the shared on-device refusal message), and that a
// context overflow is recognised (so Ask can recover — F2).

@Suite("DrawingAIEngine on-device error mapping (F1)")
struct DrawingAIEngineErrorTests {

    @available(macOS 27, iOS 27, *)
    @Test("LanguageModelError refusal and guardrail are detected and share one message")
    func modernRefusalMapping() {
        let refusal = LanguageModelError.refusal(.init(explanation: "x", debugDescription: "x"))
        let guardrail = LanguageModelError.guardrailViolation(.init(debugDescription: "x"))

        #expect(DrawingAIEngine.isRefusal(refusal))
        #expect(DrawingAIEngine.isRefusal(guardrail))
        #expect(DrawingAIEngine.isOnDeviceError(refusal))
        #expect(DrawingAIEngine.isOnDeviceError(guardrail))
        // Both map to the same friendly message (the shared on-device refusal case).
        let expected = DrawingAIEngine.friendlyMessage(for: refusal)
        #expect(!expected.isEmpty && expected != DrawingAIEngine.genericFailure)
        #expect(DrawingAIEngine.friendlyMessage(for: guardrail) == expected)
        #expect(!DrawingAIEngine.isContextOverflow(refusal))
    }

    @available(macOS 27, iOS 27, *)
    @Test("LanguageModelError context overflow is recognised for Ask recovery")
    func modernContextOverflowMapping() {
        let overflow = LanguageModelError.contextSizeExceeded(
            .init(contextSize: 4096, tokenCount: 5000, debugDescription: "x"))
        #expect(DrawingAIEngine.isContextOverflow(overflow))
        #expect(DrawingAIEngine.isOnDeviceError(overflow))
        #expect(!DrawingAIEngine.isRefusal(overflow))
        let message = DrawingAIEngine.friendlyMessage(for: overflow)
        #expect(message != DrawingAIEngine.genericFailure)
        #expect(message.localizedCaseInsensitiveContains("too much text"))
    }

    @available(macOS 27, iOS 27, *)
    @Test("LanguageModelError rate-limit and unsupported-language get their own messages")
    func modernOtherMappings() {
        let rate = LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "x"))
        #expect(DrawingAIEngine.isOnDeviceError(rate))
        #expect(!DrawingAIEngine.isRefusal(rate))
        #expect(DrawingAIEngine.friendlyMessage(for: rate).localizedCaseInsensitiveContains("busy"))

        let language = LanguageModelError.unsupportedLanguageOrLocale(
            .init(languageCode: Locale.LanguageCode("xx"), debugDescription: "x"))
        #expect(DrawingAIEngine.friendlyMessage(for: language).localizedCaseInsensitiveContains("language"))
    }

    @available(macOS 26, iOS 26, *)
    @Test("A cancellation maps to an empty message and a non-model error to the generic one")
    func cancellationAndNonModelError() {
        #expect(DrawingAIEngine.friendlyMessage(for: CancellationError()).isEmpty)
        struct Other: Error {}
        #expect(!DrawingAIEngine.isOnDeviceError(Other()))
        #expect(!DrawingAIEngine.isRefusal(Other()))
        #expect(!DrawingAIEngine.isContextOverflow(Other()))
        #expect(DrawingAIEngine.friendlyMessage(for: Other()) == DrawingAIEngine.genericFailure)
    }
}
