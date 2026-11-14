import CoreGraphics
import EMFEdit
import Foundation
import FoundationModels
import Observation

// MARK: - Edit by instruction (X2a)
//
// The "Edit with AI…" view-model: the user types an instruction; the model is given the
// fenced, sanitised description of the editable scene (DrawingAIEditContext) and told to
// output ONLY an EditPlan. The raw output goes sanitiser → strict decode → validator;
// on success the user sees a before/after preview, a human-readable op list and any
// validator warnings, and only an explicit Apply mutates — as ONE grouped "AI Edit"
// undo through DocumentSession.applyGroupedCommands (docs/v3-plan §11.2). A decode or
// validation failure applies nothing and shows a clear message.
//
// The model call is injected (`producer`), so tests drive the whole flow with a stub
// that returns canned plans — no network, no on-device model.

/// Produces the raw model reply (expected to contain an EditPlan JSON object) for an
/// instruction over the fenced element data, using the chosen engine. Injected so tests
/// stub it.
typealias DrawingEditPlanProducer = @MainActor (_ instruction: String, _ elementsBlock: String, _ engine: AIEngineChoice) async throws -> String

@MainActor
@Observable
final class DrawingAIEditModel {

    /// A validated, previewed edit awaiting the user's confirm.
    struct Preview: Identifiable {
        let id = UUID()
        var before: CGImage
        var after: CGImage
        /// Human-readable op descriptions ("Recolour 3 text elements to #1F3A93").
        var operations: [String]
        /// Prominent warnings the preview must show (e.g. deletes the whole drawing).
        var warnings: [String]
        /// The commands to apply on confirm, and the scene they were built against.
        var commands: [SceneCommand]
    }

    enum Phase: Equatable {
        case idle
        case thinking
        case preview
        case applied
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// The current instruction text (bound to the field).
    var instruction = ""
    /// The previewed edit; the view presents the preview sheet while set.
    var preview: Preview?
    /// The engine footnote ("On-device · Apple Intelligence" / "via …") for the preview.
    private(set) var engineLabel = ""
    /// The last raw model reply, for DEBUG inspection / the live-run harness. Not shown.
    @ObservationIgnored private(set) var lastRawReply = ""
    /// Set when a provider edit needs consent; the view presents the consent screen.
    var pendingConsent: AIProviderConfig?

    /// The configured-provider store, injected by the view, used to resolve the engine.
    @ObservationIgnored var providerStore: AIProviderStore?
    /// The model call. `nil` uses the real on-device / provider run; tests set a stub.
    @ObservationIgnored var producer: DrawingEditPlanProducer?
    /// A test seam: forces the engine (bypassing availability/provider resolution) so the
    /// stubbed-producer flow is tested without Apple Intelligence or a configured provider.
    @ObservationIgnored var engineOverride: AIEngineChoice?

    @ObservationIgnored private weak var session: DocumentSession?
    @ObservationIgnored private var scene: Scene?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pendingInstruction: String?
    /// The selection the edit is scoped to (empty = whole drawing).
    @ObservationIgnored var scope: Set<Int> = []

    /// A short description of the edit's scope, for the sheet header.
    var scopeDescription: String {
        scope.isEmpty ? "the whole drawing" : "\(scope.count) selected element\(scope.count == 1 ? "" : "s")"
    }

    var isBusy: Bool { phase == .thinking }

    private var onDeviceAvailable: Bool { EmfySettings.shared.useOnDeviceAI && DrawingAIAvailability.current().isAvailable }

    private var engine: AIEngineChoice? {
        if let engineOverride { return engineOverride }
        if let providerStore { return providerStore.resolvedEngine(onDeviceAvailable: onDeviceAvailable) }
        return onDeviceAvailable ? .onDevice : nil
    }

    /// Whether any engine is available (so the view can show/hide the entry).
    var hasEngine: Bool { engine != nil }

    func configure(session: DocumentSession, scope: Set<Int> = []) {
        self.session = session
        self.scope = scope
    }

    /// Resets to idle (e.g. when the sheet is dismissed or the drawing changes).
    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
        preview = nil
        pendingConsent = nil
        pendingInstruction = nil
        engineLabel = ""
    }

    /// Submits the current instruction. Enters edit mode first (so element ids match what
    /// will be applied), resolves the engine, and — for a provider — presents the consent
    /// screen before sending.
    func submit() {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let engine else { phase = .failed("AI isn’t available right now."); return }
        if case .provider(let config) = engine, !(providerStore?.isConsentGranted(config.id) ?? false) {
            pendingInstruction = text
            pendingConsent = config
            return
        }
        start(instruction: text, engine: engine)
    }

    /// Resumes a held edit after the consent screen is allowed.
    func consentAllowed() {
        pendingConsent = nil
        guard let text = pendingInstruction, let engine else { return }
        pendingInstruction = nil
        start(instruction: text, engine: engine)
    }

    func consentDeclined() {
        pendingConsent = nil
        pendingInstruction = nil
    }

    private func start(instruction text: String, engine: AIEngineChoice) {
        task?.cancel()
        phase = .thinking
        preview = nil
        engineLabel = AIEngineLabel.text(for: engine)
        task = Task { [weak self] in await self?.run(instruction: text, engine: engine) }
    }

    private func run(instruction text: String, engine: AIEngineChoice) async {
        guard let session else { phase = .failed("No open drawing to edit."); return }
        if session.editing != .editing { await session.beginEditing() }
        guard session.editing == .editing, let scene = session.editingScene else {
            phase = .failed("This drawing can’t be edited."); return
        }
        self.scene = scene
        // Scope the described elements to the current selection (intersected with what is
        // actually editable), so the AI edit stays within the selection when there is one.
        let editableScope = scope.intersection(Set(scene.editableElements.map(\.id)))
        let block = DrawingAIEditContext.elementsBlock(for: scene, selectedIDs: editableScope)

        // Produce → sanitiser → strict decode. The live (non-stub) path gets ONE bounded
        // retry that feeds the decode error back, hardening the JSON channel WITHOUT ever
        // loosening the decoder or the validator. The stub path never retries.
        let maxAttempts = (producer == nil) ? 2 : 1
        var plan: EditPlan?
        var lastDecodeError = ""
        var lastRaw = ""
        for attempt in 0 ..< maxAttempts {
            let prompt = attempt == 0 ? text : Self.retryInstruction(original: text, hint: lastDecodeError)
            let raw: String
            do {
                if let producer {
                    raw = try await producer(prompt, block, engine)
                } else {
                    raw = try await defaultProduce(instruction: prompt, elementsBlock: block, engine: engine)
                }
            } catch {
                if error is CancellationError { phase = .idle; return }
                phase = .failed(Self.friendly(error))
                return
            }
            if Task.isCancelled { phase = .idle; return }
            lastRaw = raw
            do {
                let decoded = try EditPlan.decode(fromJSON: DrawingAIOutputSanitiser.sanitise(raw))
                // An empty plan is also retried once (the model declined to act) — the
                // retry just asks again, it does not loosen the validator.
                if !decoded.operations.isEmpty { plan = decoded; break }
                lastDecodeError = "the reply contained no operations; name the element ids listed in the data that should change"
            } catch {
                // A fixed hint — never echo the model's own error/reply text back into the
                // next prompt's instruction slot, which would be an injection path (S6).
                lastDecodeError = "the reply wasn’t the required EditPlan JSON"
            }
        }
        lastRawReply = lastRaw   // DEBUG inspection only
        guard let plan else {
            // A blank reply reads as an on-device refusal; otherwise the output was unusable.
            phase = .failed(lastRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.onDeviceRefusalMessage
                : "The edit couldn’t be understood. Try rephrasing your request.")
            return
        }
        // Enforce the selection scope: when the user limited the edit to a selection, the
        // model's plan may only touch those elements (S7).
        let validation = EditPlanValidator.validate(plan, in: scene, allowedIDs: editableScope.isEmpty ? nil : editableScope)
        guard validation.isApplicable else {
            phase = .failed(Self.problemMessage(validation.problems))
            return
        }
        let commands = plan.commands(in: scene)
        guard !commands.isEmpty else {
            phase = .failed("That request didn’t map to any change I can make to this drawing.")
            return
        }

        // Build the before/after preview off the main actor.
        let rendered = await Task.detached(priority: .userInitiated) {
            Self.renderBeforeAfter(scene: scene, commands: commands)
        }.value
        guard !Task.isCancelled else { phase = .idle; return }
        guard let rendered else { phase = .failed("Couldn’t prepare a preview of that edit."); return }

        preview = Preview(
            before: rendered.before, after: rendered.after,
            operations: EditPlanDescriber.describe(plan.operations, in: scene),
            warnings: validation.warnings.map(EditPlanDescriber.describe),
            commands: commands)
        phase = .preview
    }

    /// Applies the previewed edit as ONE grouped "AI Edit" undo. A no-op when nothing is
    /// previewed — so an edit is never applied without a confirmed preview.
    func apply() {
        guard let preview, let session, session.editing == .editing else { self.preview = nil; return }
        self.preview = nil
        session.applyGroupedCommands(preview.commands, name: .group("edit.action.aiEdit"))
        phase = .applied
    }

    /// Dismisses the preview without applying.
    func cancelPreview() {
        preview = nil
        phase = .idle
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .thinking { phase = .idle }
    }

    // MARK: The real model run (on-device or provider)

    /// Streams the edit plan from the chosen engine and returns the final raw reply,
    /// grounded in `DrawingAIPrompt.editInstructions`. Used when no `producer` stub is set.
    private func defaultProduce(instruction: String, elementsBlock: String, engine: AIEngineChoice) async throws -> String {
        let prompt = DrawingAIPrompt.editPrompt(instruction: instruction, elementsBlock: elementsBlock)
        switch engine {
        case .onDevice:
            guard #available(macOS 26, iOS 26, *), DrawingAIEngine.isModelAvailable else {
                throw ProviderError.other("On-device AI isn’t available right now.")
            }
            let session = LanguageModelSession(instructions: DrawingAIPrompt.editInstructions)
            let response = try await session.respond(to: prompt)
            return response.content
        case .provider(let config):
            guard let service = providerStore?.service else {
                throw ProviderError.other("No provider is configured for AI editing.")
            }
            let request = AIProviderRequest(
                system: DrawingAIPrompt.editInstructions,
                userPrompt: prompt,
                tools: [],
                model: config.model,
                streaming: true)
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

    /// The shared plain message shown when the on-device model refuses a request (its output
    /// guardrail declines, or it returns no reply). Used by the Edit, Translate and Generate
    /// flows so a refusal always reads the same way, never as a silent failure.
    static let onDeviceRefusalMessage = "The on-device model declined this request. Try rewording, or use a configured provider."

    private static func friendly(_ error: Error) -> String {
        if #available(macOS 26, iOS 26, *), DrawingAIEngine.isRefusal(error) {
            return onDeviceRefusalMessage
        }
        if #available(macOS 26, iOS 26, *), DrawingAIEngine.isOnDeviceError(error) {
            return DrawingAIEngine.friendlyMessage(for: error)
        }
        if let providerError = error as? ProviderError { return providerError.friendlyMessage }
        return "Something went wrong preparing the edit. Please try again."
    }

    /// The retry prompt: the original request plus a FIXED hint, so the model fixes its
    /// JSON. The hint is always Emfy's own text (never the model's error/reply), so the
    /// model can't feed instructions back to itself through the retry (S6). Never loosens
    /// the decoder — it just gives the model a second, informed try.
    static func retryInstruction(original: String, hint: String) -> String {
        """
        \(original)

        (Your previous reply could not be used — \(hint). \
        Reply with ONLY the JSON object described, and nothing else.)
        """
    }

    /// A short message for the first validation problem (the preview isn't shown for an
    /// invalid plan).
    static func problemMessage(_ problems: [EditPlanProblem]) -> String {
        guard let first = problems.first else { return "The edit couldn’t be applied." }
        switch first {
        case .emptyPlan:
            return "That request didn’t map to any change I can make."
        case .tooManyOperations:
            return "That request is too large to apply at once. Try a smaller change."
        case .elementNotFound, .elementNotEditable:
            return "The edit referred to something that can’t be changed here."
        case .outOfScope:
            return "The edit tried to change something outside your selection."
        case .notTextElement:
            return "A text change was aimed at something that isn’t text."
        case .invalidColor:
            return "The edit used a colour I couldn’t read."
        case .numberNotFinite, .moveOutOfRange, .scaleOutOfRange, .fontSizeOutOfRange, .lineWidthOutOfRange:
            return "The edit used a value outside a sensible range."
        case .textTooLong:
            return "The replacement text is too long."
        case .emptyTargetList:
            return "The edit didn’t say which elements to change."
        }
    }
}

// MARK: - Human-readable op descriptions (app-layer display text)
//
// Describes an edit the way a user sees it — naming a text run by a short excerpt of its
// text (local UI only, never sent to a model) and counting elements kind-aware
// ("2 text elements", "3 shapes") — rather than exposing internal element ids.

enum EditPlanDescriber {
    static func describe(_ operations: [EditOperation], in scene: Scene) -> [String] {
        operations.map { describe($0, in: scene) }
    }

    static func describe(_ operation: EditOperation, in scene: Scene) -> String {
        switch operation {
        case .recolorFill(let ids, let color):
            return "Recolour the fill of \(countPhrase(ids, scene)) to \(color.hex)"
        case .recolorStroke(let ids, let color):
            return "Recolour the outline of \(countPhrase(ids, scene)) to \(color.hex)"
        case .setText(let id, let text):
            return "Change \(name(id, scene)) to “\(excerpt(text))”"
        case .setFontSize(let id, let points):
            return "Set \(name(id, scene)) to \(trim(points)) pt"
        case .setFontFamily(let id, let family):
            return "Set \(name(id, scene)) font to \(family)"
        case .move(let ids, let dx, let dy):
            return "Move \(countPhrase(ids, scene)) by (\(trim(dx)), \(trim(dy)))"
        case .scale(let ids, let factor):
            return "Scale \(countPhrase(ids, scene)) by \(trim(factor))×"
        case .setLineWidth(let ids, let points):
            return "Set the line width of \(countPhrase(ids, scene)) to \(trim(points)) pt"
        case .align(let ids, let edge):
            return "Align \(countPhrase(ids, scene)) \(edgeName(edge))"
        case .distribute(let ids, let axis):
            return "Distribute \(countPhrase(ids, scene)) \(axis == .horizontal ? "horizontally" : "vertically")"
        case .delete(let ids):
            return "Delete \(countPhrase(ids, scene))"
        }
    }

    static func describe(_ warning: EditPlanWarning) -> String {
        switch warning {
        case .deletesEntireDrawing(let count):
            return "This deletes every element in the drawing (\(count))."
        }
    }

    /// A single element named as the user sees it: a text run by a short excerpt, else by
    /// kind ("the rectangle").
    private static func name(_ id: Int, _ scene: Scene) -> String {
        guard let element = scene.elements.first(where: { $0.id == id }) else { return "the element" }
        if element.kind == .text, let string = element.text?.string,
           !string.trimmingCharacters(in: .whitespaces).isEmpty {
            return "“\(excerpt(string))”"
        }
        return "the \(DrawingAIEditContext.kindName(element.kind))"
    }

    /// A kind-aware count phrase: "2 text elements", "3 shapes", "1 image", else "N elements".
    private static func countPhrase(_ ids: [Int], _ scene: Scene) -> String {
        let unique = Array(Set(ids))
        let n = unique.count
        let kinds = Set(unique.compactMap { id in scene.elements.first { $0.id == id }?.kind })
        let noun: String
        if kinds == [.text] {
            noun = n == 1 ? "text element" : "text elements"
        } else if kinds == [.image] {
            noun = n == 1 ? "image" : "images"
        } else if !kinds.isEmpty, kinds.allSatisfy({ $0 != .text && $0 != .image }) {
            noun = n == 1 ? "shape" : "shapes"
        } else {
            noun = n == 1 ? "element" : "elements"
        }
        return "\(n) \(noun)"
    }

    private static func excerpt(_ string: String) -> String {
        let clean = string.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return clean.count > 24 ? String(clean.prefix(24)) + "…" : clean
    }

    private static func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func edgeName(_ edge: PlanAlignEdge) -> String {
        switch edge {
        case .left: return "left"
        case .right: return "right"
        case .top: return "top"
        case .bottom: return "bottom"
        case .centerHorizontal: return "centre (horizontal)"
        case .centerVertical: return "centre (vertical)"
        }
    }
}
