import Foundation
import Observation

// MARK: - Describe this drawing (A1a)
//
// Drives the inspector's "Describe" action: builds the bounded context off the main
// actor, streams a 2–4 sentence plain description from the on-device model, and —
// as a side effect — seeds the VoiceOver alt-text cache for the same drawing. A
// non-gated `@Observable` holding plain String/Bool state the view binds to; the
// Foundation Models calls happen inside `#available` checks, so the view stays at
// the app's 14/17 floor. Guardrail refusals and errors become friendly messages.

@MainActor
@Observable
final class DrawingDescribeModel {
    enum Phase: Equatable {
        case idle
        case loading
        case streaming
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// The streamed (or final) description text.
    private(set) var text = ""
    /// Which engine produced the current description (for the footnote).
    private(set) var engineLabel = ""
    /// Set when a provider Describe needs consent; the view presents the consent screen.
    var pendingConsent: AIProviderConfig?
    /// The configured-provider store, injected by the view, used to resolve the engine.
    @ObservationIgnored var providerStore: AIProviderStore?

    /// The content id the current description belongs to, so a drawing change resets.
    @ObservationIgnored private var contentID: Int?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Parameters held while the consent screen is shown, so Allow can resume.
    @ObservationIgnored private var pendingInputs: (Int, @Sendable () async -> Data?, String, [String], DrawingAltTextStore)?

    var isBusy: Bool {
        switch phase {
        case .loading, .streaming: return true
        default: return false
        }
    }

    private var onDeviceAvailable: Bool { EmfySettings.shared.useOnDeviceAI && DrawingAIAvailability.current().isAvailable }

    private var engine: AIEngineChoice? {
        if let providerStore { return providerStore.resolvedEngine(onDeviceAvailable: onDeviceAvailable) }
        return onDeviceAvailable ? .onDevice : nil
    }

    /// Resets to idle when the open drawing changes, so a stale description never
    /// shows against a new drawing.
    func resetIfDrawingChanged(contentID: Int) {
        guard self.contentID != contentID else { return }
        task?.cancel()
        task = nil
        self.contentID = contentID
        phase = .idle
        text = ""
        pendingConsent = nil
        pendingInputs = nil
    }

    /// Starts (or restarts) a description for the open drawing with the selected engine.
    /// Resolves the bytes through `dataProvider`, builds the context off-main, streams
    /// the answer, and asks the alt-text store to seed its cache (on-device).
    func describe(
        contentID: Int,
        dataProvider: @escaping @Sendable () async -> Data?,
        fileName: String,
        unsupportedNotes: [String],
        altTextStore: DrawingAltTextStore
    ) {
        guard let engine else {
            phase = .failed("AI isn’t available right now.")
            return
        }
        // A provider Describe needs consent first — present the consent screen and
        // resume on Allow.
        if case .provider(let config) = engine, !(providerStore?.isConsentGranted(config.id) ?? false) {
            pendingInputs = (contentID, dataProvider, fileName, unsupportedNotes, altTextStore)
            pendingConsent = config
            return
        }
        start(contentID: contentID, dataProvider: dataProvider, fileName: fileName, unsupportedNotes: unsupportedNotes, altTextStore: altTextStore, engine: engine)
    }

    /// Resumes a held Describe after the consent screen is allowed.
    func consentAllowed() {
        pendingConsent = nil
        guard let (contentID, dataProvider, fileName, notes, altTextStore) = pendingInputs, let engine else { return }
        pendingInputs = nil
        start(contentID: contentID, dataProvider: dataProvider, fileName: fileName, unsupportedNotes: notes, altTextStore: altTextStore, engine: engine)
    }

    /// Dismisses the consent screen without sending.
    func consentDeclined() {
        pendingConsent = nil
        pendingInputs = nil
    }

    private func start(
        contentID: Int,
        dataProvider: @escaping @Sendable () async -> Data?,
        fileName: String,
        unsupportedNotes: [String],
        altTextStore: DrawingAltTextStore,
        engine: AIEngineChoice
    ) {
        task?.cancel()
        self.contentID = contentID
        phase = .loading
        text = ""
        engineLabel = AIEngineLabel.text(for: engine)
        // On-device alt text is a separate feature; it self-gates on availability.
        altTextStore.generateIfNeeded(contentID: contentID, dataProvider: dataProvider, fileName: fileName, unsupportedNotes: unsupportedNotes)
        task = Task { [weak self] in
            guard let data = await dataProvider() else {
                self?.phase = .failed("Emfy couldn’t read this drawing for the model.")
                return
            }
            let bundle = await Task.detached(priority: .userInitiated) {
                DrawingAIContextProvider.make(data: data, fileName: fileName, unsupportedNotes: unsupportedNotes)
            }.value
            guard let self else { return }
            guard let bundle else {
                self.phase = .failed("Emfy couldn’t read this drawing for the model.")
                return
            }
            switch engine {
            case .onDevice:
                await self.streamOnDevice(bundle: bundle)
            case .provider(let config):
                await self.streamProvider(bundle: bundle, config: config)
            }
        }
    }

    /// Cancels an in-flight description.
    func cancel() {
        task?.cancel()
        task = nil
        if isBusy { phase = text.isEmpty ? .idle : .done }
    }

    private func streamOnDevice(bundle: DrawingAIContextProvider.Bundle) async {
        guard #available(macOS 26, iOS 26, *), DrawingAIEngine.isModelAvailable else {
            phase = .failed("On-device AI isn’t available right now.")
            return
        }
        let session = DrawingAIEngine.makeSession(toolData: bundle.toolData)
        let prompt = DrawingAIPrompt.describePrompt(for: bundle.context)
        phase = .streaming
        do {
            // Build the normalised haystack ONCE for the whole stream (P14) rather than
            // re-join/re-normalise the drawing text on every token.
            let haystack = DrawingDescribeGrounding.haystack(for: bundle.toolData.textLines)
            let stream = session.streamResponse(to: prompt)
            var gate = StreamFlushGate()
            var latest = ""
            for try await snapshot in stream {
                if Task.isCancelled { break }
                latest = snapshot.content
                // Coalesce UI writes to ~15 Hz (P14): the snapshot is cumulative, so an
                // intermediate skip loses nothing and the final flush shows the full text.
                if gate.shouldFlush() {
                    text = DrawingDescribeGrounding.groundQuotes(
                        in: DrawingAIOutputSanitiser.sanitise(latest), normalisedHaystack: haystack)
                }
            }
            // Final flush: strip quotation marks from any "quote" not actually in the
            // drawing's text (F3), over the complete text — identical to per-token grounding.
            text = DrawingDescribeGrounding.groundQuotes(
                in: DrawingAIOutputSanitiser.sanitise(latest), normalisedHaystack: haystack)
            phase = Task.isCancelled ? (text.isEmpty ? .idle : .done) : .done
        } catch {
            if error is CancellationError { phase = text.isEmpty ? .idle : .done; return }
            phase = .failed(DrawingAIEngine.friendlyMessage(for: error))
        }
    }

    private func streamProvider(bundle: DrawingAIContextProvider.Bundle, config: AIProviderConfig) async {
        guard let service = providerStore?.service else {
            phase = .failed("AI isn’t available right now.")
            return
        }
        phase = .streaming
        let request = AIProviderRequestBuilder.describe(bundle: bundle, model: config.model)
        // One normalised haystack for the whole stream (P14).
        let haystack = DrawingDescribeGrounding.haystack(for: bundle.toolData.textLines)
        var gate = StreamFlushGate()
        var latest = ""
        do {
            let refused = try await DrawingAIProviderRun.stream(
                service: service, config: config, request: request,
                onText: { [weak self] value in
                    // Coalesce UI writes to ~15 Hz (P14); cumulative snapshots make a skip safe.
                    latest = value
                    guard gate.shouldFlush() else { return }
                    self?.text = DrawingDescribeGrounding.groundQuotes(
                        in: DrawingAIOutputSanitiser.sanitise(value), normalisedHaystack: haystack)
                },
                onTool: { _ in })
            // Final flush over the complete text — identical to per-token grounding.
            text = DrawingDescribeGrounding.groundQuotes(
                in: DrawingAIOutputSanitiser.sanitise(latest), normalisedHaystack: haystack)
            if refused {
                phase = .failed("The provider declined this request.")
            } else {
                phase = Task.isCancelled ? (text.isEmpty ? .idle : .done) : .done
            }
        } catch {
            if error is CancellationError { phase = text.isEmpty ? .idle : .done; return }
            phase = .failed((error as? ProviderError)?.friendlyMessage ?? "Something went wrong with the provider. Please try again.")
        }
    }
}
