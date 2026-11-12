import Foundation
import FoundationModels
import Observation

// MARK: - Ask about this drawing (A1a; engine routing A2b)
//
// Drives the viewer inspector's "Ask" segment: a small chat, grounded in the open
// drawing, with streamed answers, per-answer "Used: …" tool footnotes, an engine
// footnote, a Stop button, and history kept per open drawing. The engine is the one
// selected in Settings: Apple's on-device model (a `LanguageModelSession` per drawing)
// or a configured provider (a fresh grounded request per question, through the
// consent-gated core). A provider send with no recorded consent presents the consent
// screen (`pendingConsent`) rather than failing silently.
//
// Non-gated `@Observable`; Foundation Models types are touched only inside `#available`.
// Answers are plain text — no links, no markdown executed.

@MainActor
@Observable
final class DrawingAskModel {
    struct Message: Identifiable, Equatable {
        enum Role: Equatable { case user, assistant }
        let id = UUID()
        var role: Role
        var text: String
        /// Display names of the tools the model used for this answer (assistant only).
        var toolsUsed: [String] = []
        /// Which engine produced this answer (assistant only; for the footnote).
        var engineLabel: String = ""
        /// True while this assistant message is still streaming.
        var streaming = false
        /// True when this assistant message is a friendly error.
        var failed = false
    }

    private(set) var messages: [Message] = []
    var draft = ""
    private(set) var isResponding = false
    /// Set when a provider send needs consent; the view presents the consent screen.
    var pendingConsent: AIProviderConfig?

    /// The configured-provider store, injected by the view, used to resolve the engine
    /// and the consent state. Nil falls back to the on-device engine when available.
    @ObservationIgnored var providerStore: AIProviderStore?

    @ObservationIgnored private var contentID: Int?
    @ObservationIgnored private var dataProvider: (@Sendable () async -> Data?)?
    @ObservationIgnored private var fileName = ""
    @ObservationIgnored private var unsupportedNotes: [String] = []
    /// The question held back while the consent screen is shown.
    @ObservationIgnored private var pendingQuestion: String?

    /// The live session (`LanguageModelSession`), type-erased so this class compiles
    /// at the 14/17 floor.
    @ObservationIgnored private var sessionBox: AnyObject?
    @ObservationIgnored private var context: DrawingAIContext?
    @ObservationIgnored private var usage: DrawingAIToolUsage?
    /// The bounded context for the provider path (built once per drawing).
    @ObservationIgnored private var providerBundle: DrawingAIContextProvider.Bundle?
    @ObservationIgnored private var task: Task<Void, Never>?

    var canSend: Bool {
        !isResponding && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var onDeviceAvailable: Bool { EmfySettings.shared.useOnDeviceAI && DrawingAIAvailability.current().isAvailable }

    /// The engine Describe/Ask/Explain use, from the selected Settings choice.
    private var engine: AIEngineChoice? {
        if let providerStore { return providerStore.resolvedEngine(onDeviceAvailable: onDeviceAvailable) }
        return onDeviceAvailable ? .onDevice : nil
    }

    /// Points the model at the open drawing. A content-id change clears the chat and
    /// the session so a new drawing starts fresh.
    func prepare(
        contentID: Int,
        dataProvider: @escaping @Sendable () async -> Data?,
        fileName: String,
        unsupportedNotes: [String]
    ) {
        guard self.contentID != contentID else { return }
        task?.cancel()
        task = nil
        self.contentID = contentID
        self.dataProvider = dataProvider
        self.fileName = fileName
        self.unsupportedNotes = unsupportedNotes
        sessionBox = nil
        context = nil
        usage = nil
        providerBundle = nil
        pendingConsent = nil
        pendingQuestion = nil
        messages = []
        draft = ""
        isResponding = false
    }

    /// Sends the current draft as a question and streams the answer.
    func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding, let dataProvider else { return }
        guard let engine else {
            messages.append(Message(role: .assistant, text: "AI isn’t available right now.", failed: true))
            return
        }
        // A provider send needs consent first — present the consent screen, hold the
        // question, and resume on Allow (never a silent failure).
        if case .provider(let config) = engine, !(providerStore?.isConsentGranted(config.id) ?? false) {
            pendingQuestion = question
            pendingConsent = config
            return
        }
        start(question: question, engine: engine, dataProvider: dataProvider)
    }

    /// Resumes the held question after the consent screen is allowed.
    func consentAllowed() {
        pendingConsent = nil
        guard let question = pendingQuestion, let engine, let dataProvider else { return }
        pendingQuestion = nil
        start(question: question, engine: engine, dataProvider: dataProvider)
    }

    /// Dismisses the consent screen without sending.
    func consentDeclined() {
        pendingConsent = nil
        pendingQuestion = nil
    }

    private func start(question: String, engine: AIEngineChoice, dataProvider: @escaping @Sendable () async -> Data?) {
        draft = ""
        messages.append(Message(role: .user, text: question))
        let isFirstTurn = messages.filter { $0.role == .assistant }.isEmpty
        isResponding = true
        let fileName = self.fileName
        let notes = self.unsupportedNotes
        task = Task { [weak self] in
            guard let self else { return }
            switch engine {
            case .onDevice:
                await self.respondOnDevice(question: question, isFirstTurn: isFirstTurn, dataProvider: dataProvider, fileName: fileName, unsupportedNotes: notes)
            case .provider(let config):
                await self.respondProvider(question: question, config: config, dataProvider: dataProvider, fileName: fileName, unsupportedNotes: notes)
            }
        }
    }

    /// Cancels the in-flight answer, keeping whatever streamed so far.
    func stop() {
        task?.cancel()
        task = nil
        isResponding = false
        if let last = messages.indices.last, messages[last].role == .assistant, messages[last].streaming {
            messages[last].streaming = false
        }
    }

    // MARK: On-device path

    private func respondOnDevice(question: String, isFirstTurn: Bool, dataProvider: @escaping @Sendable () async -> Data?, fileName: String, unsupportedNotes: [String]) async {
        guard #available(macOS 26, iOS 26, *), DrawingAIEngine.isModelAvailable else {
            finishWithError("On-device AI isn’t available right now.")
            return
        }
        if sessionBox == nil {
            guard let data = await dataProvider() else {
                finishWithError("Emfy couldn’t read this drawing for the model.")
                return
            }
            let bundle = await Task.detached(priority: .userInitiated) {
                DrawingAIContextProvider.make(data: data, fileName: fileName, unsupportedNotes: unsupportedNotes)
            }.value
            guard let bundle else {
                finishWithError("Emfy couldn’t read this drawing for the model.")
                return
            }
            var toolData = bundle.toolData
            let recorder = DrawingAIToolUsage()
            toolData.usage = recorder
            sessionBox = DrawingAIEngine.makeSession(toolData: toolData)
            context = bundle.context
            usage = recorder
        }
        guard let session = sessionBox as? LanguageModelSession, let context else {
            finishWithError("Emfy couldn’t start the on-device model.")
            return
        }
        usage?.reset()
        let prompt = isFirstTurn
            ? DrawingAIPrompt.askPrompt(question: question, context: context)
            : DrawingAIPrompt.followUpPrompt(question: question)
        let label = AIEngineLabel.text(for: .onDevice)
        messages.append(Message(role: .assistant, text: "", engineLabel: label, streaming: true))
        let index = messages.count - 1
        do {
            let stream = session.streamResponse(to: prompt)
            for try await snapshot in stream {
                if Task.isCancelled { break }
                guard messages.indices.contains(index) else { break }
                messages[index].text = snapshot.content
            }
            if messages.indices.contains(index) {
                messages[index].streaming = false
                messages[index].toolsUsed = usage?.used() ?? []
                if messages[index].text.isEmpty && !Task.isCancelled {
                    messages[index].text = "The model didn’t return an answer. Try asking again."
                    messages[index].failed = true
                }
            }
            isResponding = false
        } catch {
            if error is CancellationError {
                if messages.indices.contains(index) { messages[index].streaming = false }
                isResponding = false
                return
            }
            if messages.indices.contains(index) {
                messages[index].streaming = false
                messages[index].text = DrawingAIEngine.friendlyMessage(for: error)
                messages[index].toolsUsed = usage?.used() ?? []
                messages[index].failed = true
            }
            isResponding = false
        }
    }

    // MARK: Provider path

    private func respondProvider(question: String, config: AIProviderConfig, dataProvider: @escaping @Sendable () async -> Data?, fileName: String, unsupportedNotes: [String]) async {
        guard let service = providerStore?.service else {
            finishWithError("AI isn’t available right now.")
            return
        }
        if providerBundle == nil {
            guard let data = await dataProvider() else {
                finishWithError("Emfy couldn’t read this drawing for the model.")
                return
            }
            providerBundle = await Task.detached(priority: .userInitiated) {
                DrawingAIContextProvider.make(data: data, fileName: fileName, unsupportedNotes: unsupportedNotes)
            }.value
        }
        guard let bundle = providerBundle else {
            finishWithError("Emfy couldn’t read this drawing for the model.")
            return
        }
        let label = AIEngineLabel.text(for: .provider(config))
        messages.append(Message(role: .assistant, text: "", engineLabel: label, streaming: true))
        let index = messages.count - 1
        var tools: [String] = []
        let request = AIProviderRequestBuilder.ask(question: question, bundle: bundle, model: config.model)
        do {
            let refused = try await DrawingAIProviderRun.stream(
                service: service, config: config, request: request,
                onText: { [weak self] text in
                    guard let self, self.messages.indices.contains(index) else { return }
                    self.messages[index].text = text
                },
                onTool: { name in if !tools.contains(name) { tools.append(name) } }
            )
            if messages.indices.contains(index) {
                messages[index].streaming = false
                messages[index].toolsUsed = tools
                if refused {
                    messages[index].text = "The provider declined this request."
                    messages[index].failed = true
                } else if messages[index].text.isEmpty && !Task.isCancelled {
                    messages[index].text = "The provider didn’t return an answer. Try asking again."
                    messages[index].failed = true
                }
            }
            isResponding = false
        } catch {
            if error is CancellationError {
                if messages.indices.contains(index) { messages[index].streaming = false }
                isResponding = false
                return
            }
            let message = (error as? ProviderError)?.friendlyMessage ?? "Something went wrong with the provider. Please try again."
            if messages.indices.contains(index) {
                messages[index].streaming = false
                messages[index].text = message
                messages[index].toolsUsed = tools
                messages[index].failed = true
            }
            isResponding = false
        }
    }

    private func finishWithError(_ message: String) {
        messages.append(Message(role: .assistant, text: message, failed: true))
        isResponding = false
    }
}
