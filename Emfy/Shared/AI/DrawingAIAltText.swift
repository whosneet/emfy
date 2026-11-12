import Foundation
import Observation

// MARK: - VoiceOver alt text (A1a)
//
// A one-sentence, on-device description of the open drawing, cached by content id
// and set as the canvas's accessibility label so VoiceOver reads something
// meaningful. Generated on demand — when VoiceOver is running, or when the user
// runs Describe — never eagerly. Until it exists (or when AI is unavailable), the
// canvas falls back to "Drawing, <file name>".
//
// The cache key and fallback are pure and unit-tested; the generation is gated to
// macOS 26 / iOS 26.

@MainActor
@Observable
final class DrawingAltTextStore {
    /// Cached alt text, keyed by the viewer's content id, so re-opening the same
    /// drawing reuses it and a different drawing never shows a stale sentence.
    @ObservationIgnored private var cache: [Int: String] = [:]
    /// Content ids in insertion order, so the cache can be bounded (oldest dropped).
    @ObservationIgnored private var order: [Int] = []
    /// A revision bumped on every store, so a view observing `label(for:)` re-reads
    /// once new alt text lands.
    private var revision = 0
    /// Content ids a generation is already in flight for, so Describe and a VoiceOver
    /// trigger don't both ask the model for the same drawing.
    @ObservationIgnored private var inFlight: Set<Int> = []

    /// At most this many drawings' alt text is kept.
    static let maxEntries = 32

    /// The cached alt text for a content id, or `nil` if not generated yet.
    func cached(for contentID: Int) -> String? {
        _ = revision
        return cache[contentID]
    }

    /// The accessibility label to use now: the cached sentence, else the fallback.
    func label(for contentID: Int, fileName: String) -> String {
        cached(for: contentID) ?? DrawingAltText.fallbackLabel(fileName: fileName)
    }

    /// Stores alt text for a content id, evicting the oldest past the cap.
    func store(_ text: String, for contentID: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if cache[contentID] == nil { order.append(contentID) }
        cache[contentID] = trimmed
        while order.count > Self.maxEntries {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        revision &+= 1
    }

    /// Generates alt text once per content id (on demand) and caches it. A no-op if
    /// it's already cached, already in flight, or AI is unavailable. Resolves the
    /// bytes through `dataProvider` and builds the context off the main actor.
    func generateIfNeeded(
        contentID: Int,
        dataProvider: @escaping @Sendable () async -> Data?,
        fileName: String,
        unsupportedNotes: [String]
    ) {
        guard cached(for: contentID) == nil, !inFlight.contains(contentID) else { return }
        guard #available(macOS 26, iOS 26, *), DrawingAIEngine.isModelAvailable else { return }
        inFlight.insert(contentID)
        Task { [weak self] in
            defer { Task { @MainActor in self?.inFlight.remove(contentID) } }
            guard let data = await dataProvider() else { return }
            let bundle = await Task.detached(priority: .utility) {
                DrawingAIContextProvider.make(data: data, fileName: fileName, unsupportedNotes: unsupportedNotes)
            }.value
            guard let bundle else { return }
            // The enclosing `guard #available` covers this closure.
            let session = DrawingAIEngine.makeSession(toolData: bundle.toolData)
            let prompt = DrawingAIPrompt.altTextPrompt(for: bundle.context)
            if let text = try? await session.respond(to: prompt).content {
                self?.store(text, for: contentID)
            }
        }
    }
}

/// Pure alt-text helpers (the cache key and the fallback), so they're unit-tested
/// without the store or a model.
enum DrawingAltText {
    /// The fallback canvas label used until on-device alt text exists (or when AI is
    /// off): "Drawing, <file name>".
    static func fallbackLabel(fileName: String) -> String {
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Drawing" : "Drawing, \(name)"
    }
}
