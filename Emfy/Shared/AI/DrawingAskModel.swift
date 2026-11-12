import Foundation
import FoundationModels
import Observation

// MARK: - Ask about this drawing (A1a)
//
// Drives the viewer inspector's "Ask" segment: a small chat, grounded in the open
// drawing, with streamed answers, per-answer "Used: …" tool footnotes, a Stop
// button, and history kept per open drawing. One `LanguageModelSession` per drawing
// carries the conversation and the read-only tools; a drawing change starts fresh.
//
// Non-gated `@Observable` holding plain state the view binds to; the session (a
// macOS 26 / iOS 26 type) is held type-erased and only touched inside `#available`.
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
        /// True while this assistant message is still streaming.
        var streaming = false
        /// True when this assistant message is a friendly error.
        var failed = false
    }

    private(set) var messages: [Message] = []
    var draft = ""
    private(set) var isResponding = false

    @ObservationIgnored private var contentID: Int?
    @ObservationIgnored private var dataProvider: (@Sendable () async -> Data?)?
    @ObservationIgnored private var fileName = ""
    @ObservationIgnored private var unsupportedNotes: [String] = []

    /// The live session (`LanguageModelSession`), type-erased so this class compiles
    /// at the 14/17 floor.
    @ObservationIgnored private var sessionBox: AnyObject?
    @ObservationIgnored private var context: DrawingAIContext?
    @ObservationIgnored private var usage: DrawingAIToolUsage?
    @ObservationIgnored private var task: Task<Void, Never>?

    var canSend: Bool {
        !isResponding && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        messages = []
        draft = ""
        isResponding = false
    }

    /// Sends the current draft as a question and streams the answer.
    func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }
        guard #available(macOS 26, iOS 26, *), DrawingAIEngine.isModelAvailable, let dataProvider else {
            messages.append(Message(role: .assistant, text: "On-device AI isn’t available right now.", failed: true))
            return
        }
        draft = ""
        messages.append(Message(role: .user, text: question))
        let isFirstTurn = messages.filter { $0.role == .assistant }.isEmpty
        isResponding = true
        let fileName = self.fileName
        let notes = self.unsupportedNotes
        task = Task { [weak self] in
            guard let self else { return }
            await self.respond(question: question, isFirstTurn: isFirstTurn, dataProvider: dataProvider, fileName: fileName, unsupportedNotes: notes)
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

    @available(macOS 26, iOS 26, *)
    private func respond(question: String, isFirstTurn: Bool, dataProvider: @escaping @Sendable () async -> Data?, fileName: String, unsupportedNotes: [String]) async {
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
        messages.append(Message(role: .assistant, text: "", streaming: true))
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

    private func finishWithError(_ message: String) {
        messages.append(Message(role: .assistant, text: message, failed: true))
        isResponding = false
    }

    #if DEBUG
    /// Seeds a finished Q&A for an in-process screenshot (A1a verification). Sets the
    /// content id so the view's `prepare(contentID:)` on appear is a no-op and the
    /// seeded messages survive.
    func debugSeed(messages: [Message], contentID: Int) {
        self.contentID = contentID
        self.messages = messages
    }
    #endif
}
