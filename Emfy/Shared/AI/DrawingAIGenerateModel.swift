import CoreGraphics
import EMFEdit
import Foundation
import FoundationModels
import Observation

// MARK: - Generate a drawing from a description (X2d)
//
// The "New Drawing from Description…" view-model: the user types a description and (optionally)
// picks a page; the model is told to output ONLY a GenerationPlan. The raw output goes
// sanitiser → strict decode → validator → scene builder (the SAME SceneFactory creation calls
// the E3 tools use). On success the user sees a preview render and a short summary ("12 shapes,
// 3 text labels"); only an explicit Create opens it as a NEW, unsaved, editable document — no
// file is written until then. A decode or validation failure creates nothing and shows a clear
// message; an on-device guardrail refusal shows the shared plain refusal message (docs/v3-plan
// §11.1). The model call is injected (`producer`) so tests drive the whole flow with a stub.

/// Produces the raw model reply (expected to contain a GenerationPlan JSON object) for a
/// description over the chosen engine, with a page hint. Injected so tests stub it.
typealias DrawingGenerationProducer = @MainActor (_ description: String, _ pageHint: String, _ engine: AIEngineChoice) async throws -> String

@MainActor
@Observable
final class DrawingAIGenerateModel {

    /// A validated, previewed drawing awaiting the user's confirm.
    struct Preview: Identifiable {
        let id = UUID()
        var image: CGImage
        /// A short human summary ("12 shapes, 3 text labels").
        var summary: String
        /// The exported EMF bytes to open on Create (nothing is written until then).
        var data: Data
    }

    enum Phase: Equatable {
        case idle
        case thinking
        case preview
        case created
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// The description text (bound to the field).
    var descriptionText = ""
    /// The chosen page preset (bound to the picker).
    var page: GenerationPagePreset = .default
    /// The previewed drawing; the view presents the preview while set.
    var preview: Preview?
    /// The engine footnote for the preview.
    private(set) var engineLabel = ""
    /// The last raw model reply, for DEBUG inspection / the live-run harness. Not shown.
    @ObservationIgnored private(set) var lastRawReply = ""
    /// Set when a provider generation needs consent; the view presents the consent screen.
    var pendingConsent: AIProviderConfig?

    @ObservationIgnored var providerStore: AIProviderStore?
    /// The model call. `nil` uses the real on-device / provider run; tests set a stub.
    @ObservationIgnored var producer: DrawingGenerationProducer?
    /// A test seam: forces the engine, bypassing availability/provider resolution.
    @ObservationIgnored var engineOverride: AIEngineChoice?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pendingDescription: String?

    var isBusy: Bool { phase == .thinking }

    private var onDeviceAvailable: Bool { EmfySettings.shared.useOnDeviceAI && DrawingAIAvailability.current().isAvailable }

    private var engine: AIEngineChoice? {
        if let engineOverride { return engineOverride }
        if let providerStore { return providerStore.resolvedEngine(onDeviceAvailable: onDeviceAvailable) }
        return onDeviceAvailable ? .onDevice : nil
    }

    /// Whether any engine is available (so the view can show/hide the entry).
    var hasEngine: Bool { engine != nil }

    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
        preview = nil
        pendingConsent = nil
        pendingDescription = nil
        engineLabel = ""
    }

    /// Submits the current description. For a provider, presents the consent screen first.
    func submit() {
        let text = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let engine else { phase = .failed("AI isn’t available right now."); return }
        if case .provider(let config) = engine, !(providerStore?.isConsentGranted(config.id) ?? false) {
            pendingDescription = text
            pendingConsent = config
            return
        }
        start(description: text, engine: engine)
    }

    func consentAllowed() {
        pendingConsent = nil
        guard let text = pendingDescription, let engine else { return }
        pendingDescription = nil
        start(description: text, engine: engine)
    }

    func consentDeclined() {
        pendingConsent = nil
        pendingDescription = nil
    }

    private func start(description text: String, engine: AIEngineChoice) {
        task?.cancel()
        phase = .thinking
        preview = nil
        engineLabel = AIEngineLabel.text(for: engine)
        let preset = page
        task = Task { [weak self] in await self?.run(description: text, preset: preset, engine: engine) }
    }

    private func run(description text: String, preset: GenerationPagePreset, engine: AIEngineChoice) async {
        // Produce → sanitiser → strict decode. The live (non-stub) path gets ONE bounded retry
        // that feeds the decode error back; the stub path never retries.
        let maxAttempts = (producer == nil) ? 2 : 1
        var plan: GenerationPlan?
        var lastDecodeError = ""
        var lastRaw = ""
        for attempt in 0 ..< maxAttempts {
            let raw: String
            do {
                if let producer {
                    raw = try await producer(text, preset.promptHint, engine)
                } else {
                    raw = try await defaultProduce(description: attempt == 0 ? text : Self.retryDescription(original: text, error: lastDecodeError), pageHint: preset.promptHint, engine: engine)
                }
            } catch {
                if error is CancellationError { phase = .idle; return }
                phase = .failed(Self.friendly(error))
                return
            }
            if Task.isCancelled { phase = .idle; return }
            lastRaw = raw
            do {
                let decoded = try GenerationPlan.decode(fromJSON: DrawingAIOutputSanitiser.sanitise(raw))
                if !decoded.operations.isEmpty { plan = decoded; break }
                lastDecodeError = "the reply contained no elements; add shapes and text elements for the description"
            } catch {
                lastDecodeError = "\(error)"
            }
        }
        lastRawReply = lastRaw
        guard var plan else {
            // No reply or a blank reply reads as a refusal; otherwise the output was unusable.
            phase = .failed(lastRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? DrawingAIEditModel.onDeviceRefusalMessage
                : "The drawing couldn’t be understood. Try describing it differently.")
            return
        }
        // Force the page the user chose, so the output matches the picker.
        plan.page = GenerationPage(preset: preset.planPreset, coordinateSpace: plan.page.coordinateSpace)

        let validation = GenerationPlanValidator.validate(plan)
        guard validation.isApplicable else {
            phase = .failed(Self.problemMessage(validation.problems))
            return
        }

        // Build the scene, export to EMF bytes, and render a preview off the main actor.
        let built = await Task.detached(priority: .userInitiated) {
            Self.build(plan: plan)
        }.value
        guard !Task.isCancelled else { phase = .idle; return }
        guard let built else { phase = .failed("Couldn’t prepare a preview of that drawing."); return }

        preview = Preview(image: built.image, summary: Self.summary(plan), data: built.data)
        phase = .preview
    }

    /// Hands the previewed drawing's EMF bytes to `handler` (the view opens it as a new,
    /// unsaved document) and marks the generation created. A no-op when nothing is previewed —
    /// so a document is never created without a confirmed preview.
    func create(_ handler: (Data) -> Void) {
        guard let preview else { return }
        handler(preview.data)
        self.preview = nil
        phase = .created
    }

    func cancelPreview() {
        preview = nil
        phase = .idle
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .thinking { phase = .idle }
    }

    // MARK: Building

    private struct Built: @unchecked Sendable { let image: CGImage; let data: Data }

    nonisolated private static func build(plan: GenerationPlan) -> Built? {
        guard let scene = try? plan.makeScene(),
              let data = try? SceneExporter.export(scene, as: .emf).data,
              let image = SceneRenderer.makeImage(scene, scale: 2) else { return nil }
        return Built(image: image, data: data)
    }

    static func summary(_ plan: GenerationPlan) -> String {
        let (shapes, labels) = plan.summaryCounts
        var parts: [String] = []
        if shapes > 0 { parts.append("\(shapes) shape\(shapes == 1 ? "" : "s")") }
        if labels > 0 { parts.append("\(labels) text label\(labels == 1 ? "" : "s")") }
        return parts.isEmpty ? "an empty drawing" : parts.joined(separator: ", ")
    }

    // MARK: The real model run (on-device or provider)

    private func defaultProduce(description: String, pageHint: String, engine: AIEngineChoice) async throws -> String {
        let prompt = DrawingAIPrompt.generatePrompt(description: description, pageHint: pageHint)
        switch engine {
        case .onDevice:
            guard #available(macOS 26, iOS 26, *), DrawingAIEngine.isModelAvailable else {
                throw ProviderError.other("On-device AI isn’t available right now.")
            }
            let session = LanguageModelSession(instructions: DrawingAIPrompt.generateInstructions)
            return try await session.respond(to: prompt).content
        case .provider(let config):
            guard let service = providerStore?.service else {
                throw ProviderError.other("No provider is configured for AI drawing.")
            }
            let request = AIProviderRequest(
                system: DrawingAIPrompt.generateInstructions,
                userPrompt: prompt, tools: [], model: config.model, streaming: true)
            var accumulated = ""
            let refused = try await DrawingAIProviderRun.stream(
                service: service, config: config, request: request,
                onText: { accumulated = $0 }, onTool: { _ in })
            if refused { throw ProviderError.refusal }
            return accumulated
        }
    }

    // MARK: Messages

    private static func friendly(_ error: Error) -> String {
        if #available(macOS 26, iOS 26, *), DrawingAIEngine.isRefusal(error) {
            return DrawingAIEditModel.onDeviceRefusalMessage
        }
        if #available(macOS 26, iOS 26, *), DrawingAIEngine.isOnDeviceError(error) {
            return DrawingAIEngine.friendlyMessage(for: error)
        }
        if let providerError = error as? ProviderError { return providerError.friendlyMessage }
        return "Something went wrong preparing the drawing. Please try again."
    }

    static func retryDescription(original: String, error: String) -> String {
        """
        \(original)

        (Your previous reply could not be parsed as the required drawing JSON: \(error). \
        Reply with ONLY the JSON object described, and nothing else.)
        """
    }

    static func problemMessage(_ problems: [GenerationPlanProblem]) -> String {
        guard let first = problems.first else { return "The drawing couldn’t be created." }
        switch first {
        case .emptyPlan:
            return "That description didn’t produce any shapes. Try describing it differently."
        case .tooManyElements:
            return "That drawing is too large to create at once. Try a simpler description."
        case .coordinateNotFinite, .coordinateOutOfPage, .nonPositiveSize, .tooFewPoints:
            return "The drawing used positions or sizes that don’t fit the page. Try again."
        case .invalidColor:
            return "The drawing used a colour I couldn’t read. Try again."
        case .fontSizeOutOfRange:
            return "The drawing used a text size outside a sensible range. Try again."
        case .textTooLong:
            return "One of the labels is too long. Try a shorter description."
        }
    }
}
