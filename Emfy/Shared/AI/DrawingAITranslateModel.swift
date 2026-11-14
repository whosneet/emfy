import CoreGraphics
import EMFEdit
import Foundation
import FoundationModels
import Observation

// MARK: - Translate in place (X2c)
//
// The "Translate…" view-model: the user picks a target language; the text runs (scoped to
// the selection, else the whole drawing) are sent to the model in bounded, fenced batches,
// each run tagged with its element id. Each reply goes sanitiser → strict decode → per-batch
// reconcile (unknown / duplicate / missing ids are rejected, with ONE bounded retry on the
// live path); a batch that still won't reconcile fails the whole translation — a partial
// batch is never applied. The reconciled id→text map becomes `setText` ops through the
// EditPlan validator, so a translation takes the SAME preview/confirm/undo path as any edit.
// On confirm it applies as ONE grouped "Translate" undo.
//
// The model call is injected (`producer`), so tests drive the whole flow with a stub — no
// network, no on-device model. The drawing's own text is untrusted and never obeyed
// (DrawingAITranslateContext fences it; the instructions forbid acting on it).

/// Produces the raw model reply (expected to contain the translation JSON) for one batch:
/// the full prompt, the fenced batch block (ids), the target language and the engine.
/// Injected so tests stub it.
typealias DrawingTranslateProducer = @MainActor (_ prompt: String, _ batchBlock: String, _ targetLanguage: String, _ engine: AIEngineChoice) async throws -> String

@MainActor
@Observable
final class DrawingAITranslateModel {

    /// One old→new row for the preview list.
    struct Change: Identifiable, Equatable {
        let id: Int
        let before: String
        let after: String
        /// The translated run is likely to overflow its original width (~30% wider).
        let overflow: Bool
    }

    /// A previewed translation awaiting the user's confirm.
    struct Preview: Identifiable {
        let id = UUID()
        var before: CGImage
        var after: CGImage
        var changes: [Change]
        var overflowCount: Int
        /// Honest notes to surface (RTL rendering, truncation, omitted runs).
        var notes: [String]
        var commands: [SceneCommand]
        var languageName: String
    }

    enum Phase: Equatable {
        case idle
        case thinking
        case preview
        case applied
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// The chosen target language (bound to the picker).
    var targetLanguage: TranslationLanguage = TranslationLanguages.systemPreferred()
    /// The offered target languages.
    let languages = TranslationLanguages.all
    /// The previewed translation; the view presents the preview while set.
    var preview: Preview?
    /// The engine footnote for the preview ("On-device · Apple Intelligence" / "via …").
    private(set) var engineLabel = ""
    /// The last raw model reply, for DEBUG inspection / the live-run harness. Not shown.
    @ObservationIgnored private(set) var lastRawReply = ""
    /// Set when a provider translation needs consent; the view presents the consent screen.
    var pendingConsent: AIProviderConfig?

    @ObservationIgnored var providerStore: AIProviderStore?
    /// The model call. `nil` uses the real on-device / provider run; tests set a stub.
    @ObservationIgnored var producer: DrawingTranslateProducer?
    /// A test seam: forces the engine, bypassing availability/provider resolution.
    @ObservationIgnored var engineOverride: AIEngineChoice?

    @ObservationIgnored private weak var session: DocumentSession?
    @ObservationIgnored private var scene: Scene?
    @ObservationIgnored private var runs: [DrawingAITranslateContext.Run] = []
    @ObservationIgnored private var didTruncate = false
    @ObservationIgnored private var omittedRuns = 0
    @ObservationIgnored private var scope: Set<Int> = []
    @ObservationIgnored private var task: Task<Void, Never>?

    /// A short description of the scope, for the sheet header.
    private(set) var scopeDescription = "the whole drawing"

    var isBusy: Bool { phase == .thinking }
    /// Whether there is any text to translate (gates the Translate button after `prepare`).
    private(set) var hasText = false

    private var onDeviceAvailable: Bool { EmfySettings.shared.useOnDeviceAI && DrawingAIAvailability.current().isAvailable }

    private var engine: AIEngineChoice? {
        if let engineOverride { return engineOverride }
        if let providerStore { return providerStore.resolvedEngine(onDeviceAvailable: onDeviceAvailable) }
        return onDeviceAvailable ? .onDevice : nil
    }

    var hasEngine: Bool { engine != nil }

    /// Enters edit mode, collects the (scoped) text runs, guesses the source language and
    /// preselects a sensible default target. Called when the sheet appears, mirroring the
    /// recolour model's `start`. A no-op leaves `hasText == false` so the view shows "no text".
    func prepare(session: DocumentSession, selection: Set<Int>) async {
        reset()
        self.session = session
        self.scope = selection
        if session.editing != .editing { await session.beginEditing() }
        guard session.editing == .editing, let scene = session.editingScene else { return }
        self.scene = scene
        let editableScope = selection.intersection(Set(scene.editableElements.map(\.id)))
        self.scope = editableScope
        scopeDescription = editableScope.isEmpty
            ? "the whole drawing"
            : "\(editableScope.count) selected element\(editableScope.count == 1 ? "" : "s")"

        let collected = DrawingAITranslateContext.runs(for: scene, selectedIDs: editableScope)
        self.runs = collected
        self.hasText = !collected.isEmpty
        // Truncation / omission flags, measured against the un-truncated source.
        let allTextRuns = (editableScope.isEmpty ? scene.editableElements : scene.editableElements.filter { editableScope.contains($0.id) })
            .filter { $0.kind == .text && $0.text != nil && !($0.text?.string.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }
        omittedRuns = max(0, allTextRuns.count - collected.count)
        didTruncate = allTextRuns.contains { ($0.text?.string.count ?? 0) > DrawingAITranslateContext.maxSourceChars }

        let sourceText = collected.map(\.text).joined(separator: "\n")
        targetLanguage = TranslationLanguages.defaultTarget(sourceCode: TranslationLanguages.detectSource(sourceText))
    }

    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
        preview = nil
        pendingConsent = nil
        engineLabel = ""
    }

    /// Submits the current language. For a provider, presents the consent screen first.
    func submit() {
        guard hasText else { phase = .failed("There’s no text to translate here."); return }
        guard let engine else { phase = .failed("AI isn’t available right now."); return }
        if case .provider(let config) = engine, !(providerStore?.isConsentGranted(config.id) ?? false) {
            pendingConsent = config
            return
        }
        start(engine: engine)
    }

    func consentAllowed() {
        pendingConsent = nil
        guard let engine else { return }
        start(engine: engine)
    }

    func consentDeclined() { pendingConsent = nil }

    private func start(engine: AIEngineChoice) {
        task?.cancel()
        phase = .thinking
        preview = nil
        engineLabel = AIEngineLabel.text(for: engine)
        let language = targetLanguage
        task = Task { [weak self] in await self?.run(language: language, engine: engine) }
    }

    private func run(language: TranslationLanguage, engine: AIEngineChoice) async {
        guard let session else { phase = .failed("No open drawing to translate."); return }
        if session.editing != .editing { await session.beginEditing() }
        guard session.editing == .editing, let scene = session.editingScene else {
            phase = .failed("This drawing can’t be edited."); return
        }
        self.scene = scene
        guard !runs.isEmpty else { phase = .failed("There’s no text to translate here."); return }

        // Translate batch by batch. A batch that can't be fully reconciled (after one bounded
        // retry on the live path) fails the whole translation — never a partial batch.
        var translated: [Int: String] = [:]
        let batches = stride(from: 0, to: runs.count, by: DrawingAITranslateContext.maxBatchRuns).map {
            Array(runs[$0 ..< min($0 + DrawingAITranslateContext.maxBatchRuns, runs.count)])
        }
        for batch in batches {
            let ids = batch.map(\.id)
            let block = DrawingAITranslateContext.batchBlock(batch)
            let maxAttempts = (producer == nil) ? 2 : 1
            var lastProblem = ""
            var merged: [Int: String]?
            for attempt in 0 ..< maxAttempts {
                let raw: String
                do {
                    raw = try await produce(block: block, retryNote: attempt == 0 ? nil : lastProblem, language: language, engine: engine)
                } catch {
                    if error is CancellationError { phase = .idle; return }
                    phase = .failed(Self.friendly(error)); return
                }
                if Task.isCancelled { phase = .idle; return }
                lastRawReply = raw
                do {
                    let entries = try TextTranslation.decode(fromJSON: DrawingAIOutputSanitiser.sanitise(raw))
                    switch TextTranslation.reconcile(entries, requested: ids) {
                    case .success(let map): merged = map
                    case .failure(let problem): lastProblem = Self.describe(problem)
                    }
                } catch {
                    lastProblem = "\(error)"
                }
                if merged != nil { break }
            }
            guard let merged else {
                phase = .failed("The translation couldn’t be read back for \(batch.count) item\(batch.count == 1 ? "" : "s"). Try again.")
                return
            }
            translated.merge(merged) { _, new in new }
        }

        // Build setText ops for runs whose text actually changed; validate; map to commands.
        var ops: [EditOperation] = []
        var changes: [Change] = []
        var overflowCount = 0
        for run in runs {
            guard let after = translated[run.id], let element = scene.elements.first(where: { $0.id == run.id }), let text = element.text else { continue }
            let before = text.string
            guard after != before else { continue }
            let ratio = TextWidthRatio.ratio(original: before, candidate: after, family: text.fontFamily, bold: text.bold, italic: text.italic)
            let overflow = ratio > TextWidthRatio.overflowThreshold
            if overflow { overflowCount += 1 }
            ops.append(.setText(id: run.id, text: after))
            changes.append(Change(id: run.id, before: before, after: after, overflow: overflow))
        }
        guard !ops.isEmpty else {
            phase = .failed("This text already appears to be in \(language.englishName).")
            return
        }
        let plan = EditPlan(operations: ops)
        // Keep the translation within the selection scope too (S7).
        let validation = EditPlanValidator.validate(plan, in: scene, allowedIDs: scope.isEmpty ? nil : scope)
        guard validation.isApplicable else { phase = .failed(DrawingAIEditModel.problemMessage(validation.problems)); return }
        let commands = plan.commands(in: scene)
        guard !commands.isEmpty else { phase = .failed("That translation didn’t map to any change I can make."); return }

        let rendered = await Task.detached(priority: .userInitiated) {
            Self.renderBeforeAfter(scene: scene, commands: commands)
        }.value
        guard !Task.isCancelled else { phase = .idle; return }
        guard let rendered else { phase = .failed("Couldn’t prepare a preview of that translation."); return }

        var notes: [String] = []
        if overflowCount > 0 {
            notes.append("\(overflowCount) run\(overflowCount == 1 ? "" : "s") may be wider than before — check the layout. Emfy won’t shrink text to fit.")
        }
        if language.isRightToLeft {
            notes.append("\(language.englishName) is right-to-left. Emfy renders the characters but keeps each run’s original position and alignment — the direction may need a manual tweak.")
        }
        if didTruncate {
            notes.append("Very long runs were shortened before translating.")
        }
        if omittedRuns > 0 {
            notes.append("\(omittedRuns) further text run\(omittedRuns == 1 ? "" : "s") weren’t translated (translate a smaller selection to include them).")
        }

        preview = Preview(before: rendered.before, after: rendered.after, changes: changes,
                          overflowCount: overflowCount, notes: notes, commands: commands,
                          languageName: language.englishName)
        phase = .preview
    }

    /// Applies the previewed translation as ONE grouped "Translate" undo. A no-op when
    /// nothing is previewed — so a translation is never applied without a confirmed preview.
    func apply() {
        guard let preview, let session, session.editing == .editing else { self.preview = nil; return }
        self.preview = nil
        session.applyGroupedCommands(preview.commands, name: .group("Translate"))
        phase = .applied
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

    // MARK: Model run

    private func produce(block: String, retryNote: String?, language: TranslationLanguage, engine: AIEngineChoice) async throws -> String {
        let base = DrawingAIPrompt.translatePrompt(targetLanguage: language.englishName, batchBlock: block)
        let prompt = retryNote.map { Self.retryPrompt(base: base, problem: $0) } ?? base
        if let producer { return try await producer(prompt, block, language.englishName, engine) }
        return try await defaultProduce(prompt: prompt, language: language, engine: engine)
    }

    private func defaultProduce(prompt: String, language: TranslationLanguage, engine: AIEngineChoice) async throws -> String {
        let instructions = DrawingAIPrompt.translateInstructions(targetLanguage: language.englishName)
        switch engine {
        case .onDevice:
            guard #available(macOS 26, iOS 26, *), DrawingAIEngine.isModelAvailable else {
                throw ProviderError.other("On-device AI isn’t available right now.")
            }
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: prompt).content
        case .provider(let config):
            guard let service = providerStore?.service else {
                throw ProviderError.other("No provider is configured for AI translation.")
            }
            let request = AIProviderRequest(
                system: instructions, userPrompt: prompt, tools: [],
                model: config.model, streaming: true)
            var accumulated = ""
            let refused = try await DrawingAIProviderRun.stream(
                service: service, config: config, request: request,
                onText: { accumulated = $0 }, onTool: { _ in })
            if refused { throw ProviderError.refusal }
            return accumulated
        }
    }

    // MARK: Rendering

    private struct Rendered: @unchecked Sendable { let before: CGImage; let after: CGImage }

    nonisolated private static func renderBeforeAfter(scene: Scene, commands: [SceneCommand]) -> Rendered? {
        var history = SceneHistory(scene: scene)
        for command in commands { try? history.apply(command) }
        guard let before = SceneRenderer.makeImage(scene, scale: 2),
              let after = SceneRenderer.makeImage(history.scene, scale: 2) else { return nil }
        return Rendered(before: before, after: after)
    }

    // MARK: Messages

    private static func friendly(_ error: Error) -> String {
        if #available(macOS 26, iOS 26, *), DrawingAIEngine.isRefusal(error) {
            return DrawingAIEditModel.onDeviceRefusalMessage
        }
        if #available(macOS 26, iOS 26, *), error is LanguageModelSession.GenerationError {
            return DrawingAIEngine.friendlyMessage(for: error)
        }
        if let providerError = error as? ProviderError { return providerError.friendlyMessage }
        return "Something went wrong preparing the translation. Please try again."
    }

    static func retryPrompt(base: String, problem: String) -> String {
        """
        \(base)

        (Your previous reply could not be used: \(problem). Reply with ONLY the JSON object \
        described — one entry for every item, reusing each id — and nothing else.)
        """
    }

    static func describe(_ problem: TranslationBatchProblem) -> String {
        switch problem {
        case .notDecodable(let reason): return "it was not the required JSON (\(reason))"
        case .unknownID(let id): return "it included an id (\(id)) that was not in the list"
        case .duplicateID(let id): return "it returned id \(id) twice"
        case .missingID(let id): return "it did not return id \(id)"
        case .textTooLong(let id, _, _): return "the text for id \(id) was too long"
        }
    }
}
