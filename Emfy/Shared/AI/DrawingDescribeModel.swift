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
    /// The content id the current description belongs to, so a drawing change resets.
    @ObservationIgnored private var contentID: Int?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isBusy: Bool {
        switch phase {
        case .loading, .streaming: return true
        default: return false
        }
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
    }

    /// Starts (or restarts) a description for the open drawing. Resolves the bytes
    /// through `dataProvider`, builds the context off-main, streams the answer, and
    /// asks the alt-text store to seed its cache.
    func describe(
        contentID: Int,
        dataProvider: @escaping @Sendable () async -> Data?,
        fileName: String,
        unsupportedNotes: [String],
        altTextStore: DrawingAltTextStore
    ) {
        guard #available(macOS 26, iOS 26, *), DrawingAIEngine.isModelAvailable else {
            phase = .failed("On-device AI isn’t available right now.")
            return
        }
        task?.cancel()
        self.contentID = contentID
        phase = .loading
        text = ""
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
            // The enclosing `guard #available` covers this closure.
            await self.stream(bundle: bundle)
        }
    }

    /// Cancels an in-flight description.
    func cancel() {
        task?.cancel()
        task = nil
        if isBusy { phase = text.isEmpty ? .idle : .done }
    }

    #if DEBUG
    /// Seeds a finished description for an in-process screenshot (A1a verification).
    func debugSeed(text: String) {
        self.text = text
        phase = .done
    }
    #endif

    @available(macOS 26, iOS 26, *)
    private func stream(bundle: DrawingAIContextProvider.Bundle) async {
        let session = DrawingAIEngine.makeSession(toolData: bundle.toolData)
        let prompt = DrawingAIPrompt.describePrompt(for: bundle.context)
        phase = .streaming
        do {
            let stream = session.streamResponse(to: prompt)
            for try await snapshot in stream {
                if Task.isCancelled { break }
                text = snapshot.content
            }
            phase = Task.isCancelled ? (text.isEmpty ? .idle : .done) : .done
        } catch {
            if error is CancellationError { phase = text.isEmpty ? .idle : .done; return }
            phase = .failed(DrawingAIEngine.friendlyMessage(for: error))
        }
    }
}
