import CryptoKit
import Foundation
import FoundationModels

// MARK: - Background auto title/tags generation (A1b Part 1)
//
// Generates a short AI title and 3–5 tags for each recents entry, on-device, in the
// BACKGROUND at low priority, ONE AT A TIME (a serial queue), cached by content hash,
// and stored on the entry's metadata. The file is never renamed — the title is a
// secondary line. Gating (CLAUDE.md §8, brief Part 1): nothing generates while AI is
// off or Private mode is on, and stored AI metadata is ignored for display then too.

/// The pure gate for generating and displaying AI title/tags, so both the service and
/// the views decide identically and it's unit-tested without a model.
enum DrawingTitleTagPolicy {
    /// The minimum amount of extracted text (drawing text or OCR) a drawing must carry
    /// before a title and tags are generated at all (A1c Part 1). Below this, a title
    /// is guesswork over structure alone — the A1b live review's "Vector Drawing" with
    /// tags like "metadata"/"embodies" — so nothing is generated, stored or shown.
    static let minTextCharacters = 20

    /// Whether a drawing carries enough extracted text to earn an AI title/tags.
    static func hasEnoughText(characterCount: Int) -> Bool {
        characterCount >= minTextCharacters
    }

    /// New metadata is generated only when AI is on, Private mode is off, and the model
    /// is available.
    static func shouldGenerate(aiEnabled: Bool, privateMode: Bool, modelAvailable: Bool) -> Bool {
        aiEnabled && !privateMode && modelAvailable
    }

    /// Stored AI title/tags are shown only when AI is on and Private mode is off.
    static func shouldDisplay(aiEnabled: Bool, privateMode: Bool) -> Bool {
        aiEnabled && !privateMode
    }
}

/// The content-hash cache key for a drawing's bytes (SHA-256 hex). Identical content
/// reuses a generated result without another model call.
enum DrawingContentHash {
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class DrawingTitleTagService {
    static let shared = DrawingTitleTagService()

    private weak var store: RecentsStore?
    private weak var settings: EmfySettings?
    private weak var providerStore: AIProviderStore?

    /// FIFO work queue, processed one id at a time.
    private var order: [UUID] = []
    private var queued: Set<UUID> = []
    /// Ids to (re)generate even if they already have a title (a reopen may have changed
    /// the bytes; the hash check inside confirms).
    private var forced: Set<UUID> = []
    private var isRunning = false

    /// In-memory content-hash → result cache, bounded, so two entries with identical
    /// bytes (or a reopen) reuse a result without another model call.
    private var cache: [String: DrawingTitleTags] = [:]
    private var cacheOrder: [String] = []
    private static let cacheLimit = 128

    private init() {}

    /// Wires the service to the shared store, settings and provider store, and makes new
    /// opens trigger a (re)check. Idempotent.
    func activate(store: RecentsStore, settings: EmfySettings, providerStore: AIProviderStore? = nil) {
        self.store = store
        self.settings = settings
        self.providerStore = providerStore ?? AIProviderStore.shared
        store.onEntryChanged = { [weak self] id in self?.enqueue(id, force: true) }
    }

    private var onDeviceReady: Bool {
        (settings?.useOnDeviceAI ?? false) && DrawingAIAvailability.current().isAvailable
    }

    /// The provider that would generate titles, when the opt-in is on and its own
    /// titling consent is granted (A2b). Nil when on-device titling (or none) applies.
    private var titlesProvider: AIProviderConfig? {
        providerStore?.titlesProvider(onDeviceAvailable: onDeviceReady)
    }

    /// Whether generation may run right now: not Private mode, and either on-device
    /// titling is enabled OR a provider titling opt-in is configured and consented.
    private var isEnabled: Bool {
        guard let settings, !settings.privateMode else { return false }
        let onDevice = DrawingTitleTagPolicy.shouldGenerate(
            aiEnabled: settings.useOnDeviceAI,
            privateMode: settings.privateMode,
            modelAvailable: DrawingAIAvailability.current().isAvailable)
        return onDevice || titlesProvider != nil
    }

    /// Enqueue every persisted entry that has no title yet (the launch sweep). Idempotent.
    func syncOnLaunch() {
        guard isEnabled, let store else { return }
        for entry in store.nonPrivateEntries where entry.aiTitle == nil {
            enqueue(entry.id, force: false)
        }
    }

    /// The AI toggle (or Private mode) changed: start generating when it just became
    /// possible; the queue self-clears while disabled.
    func settingsChanged() {
        if isEnabled { syncOnLaunch() } else { clearQueue() }
    }

    private func clearQueue() {
        order.removeAll()
        queued.removeAll()
        forced.removeAll()
    }

    private func enqueue(_ id: UUID, force: Bool) {
        guard isEnabled else { return }
        if force { forced.insert(id) }
        if queued.insert(id).inserted { order.append(id) }
        drain()
    }

    private func drain() {
        guard !isRunning, isEnabled, !order.isEmpty else {
            if !isEnabled { clearQueue() }
            return
        }
        isRunning = true
        let id = order.removeFirst()
        queued.remove(id)
        let force = forced.remove(id) != nil
        Task { @MainActor [weak self] in
            await self?.process(id: id, force: force)
            self?.isRunning = false
            self?.drain()
        }
    }

    private func process(id: UUID, force: Bool) async {
        guard isEnabled, let store,
              let entry = store.entry(id: id), !store.isSessionPrivate(id) else { return }
        // Fast path: already done and not forced → no byte read.
        if !force, entry.aiTitle != nil, entry.aiContentHash != nil { return }
        guard let data = try? await store.resolveData(for: entry) else { return }
        let hash = DrawingContentHash.hash(data)
        // Content unchanged since last generation.
        if entry.aiContentHash == hash, entry.aiTitle != nil { return }
        // Cache hit for identical content → store without a model call.
        if let cached = cache[hash] {
            store.setAITitleTags(cached, contentHash: hash, for: id)
            return
        }
        let fileName = entry.displayName
        let bundle = await Task.detached(priority: .utility) {
            DrawingAIContextProvider.make(data: data, fileName: fileName, unsupportedNotes: [])
        }.value
        guard let bundle else { return }
        // Follow the selected engine: a configured, consented provider when the opt-in is
        // on, else the on-device model.
        let result: DrawingTitleTags?
        if let provider = titlesProvider {
            result = await generateViaProvider(context: bundle.context, config: provider)
        } else if #available(macOS 26, iOS 26, *) {
            result = await generate(context: bundle.context)
        } else {
            result = nil
        }
        guard let result else { return }
        // Settings may have changed during the await.
        guard isEnabled, store.entry(id: id) != nil else { return }
        remember(hash, result)
        store.setAITitleTags(result, contentHash: hash, for: id)
    }

    /// Generates title/tags with a configured provider (A2b): a non-streaming JSON reply
    /// through the consent-gated core, parsed and sanitised exactly like the on-device
    /// output. The provider gate (`titlesProvider`) already checked the titling consent.
    private func generateViaProvider(context: DrawingAIContext, config: AIProviderConfig) async -> DrawingTitleTags? {
        guard DrawingTitleTagPolicy.hasEnoughText(characterCount: context.textExcerpt.count) else { return nil }
        guard let service = providerStore?.service else { return nil }
        let request = AIProviderRequest(
            system: DrawingAIPrompt.structuredInstructions,
            userPrompt: DrawingAIPrompt.titleTagsJSONPrompt(for: context),
            tools: [],
            model: config.model,
            streaming: true,
            // Background titling requires the distinct titling consent category (S-4),
            // on top of the drawing-text categories it sends.
            requiredCategories: [.drawingText, .formatAndPage, .recordCounts, .titles])
        var text = ""
        do {
            let stream = try service.stream(config: config, request: request)
            for try await event in stream {
                if case .text(let piece) = event { text += piece }
            }
        } catch {
            return nil
        }
        guard let parsed = DrawingTitleTagsJSON.parse(text) else { return nil }
        let sanitised = DrawingTitleTagsSanitizer.sanitize(title: parsed.title, tags: parsed.tags)
        return sanitised.title.isEmpty ? nil : sanitised
    }

    @available(macOS 26, iOS 26, *)
    private func generate(context: DrawingAIContext) async -> DrawingTitleTags? {
        // No title/tags for a drawing without enough real text (A1c Part 1): a title
        // over structure alone is generic ("Vector Drawing"), so store and show nothing.
        guard DrawingTitleTagPolicy.hasEnoughText(characterCount: context.textExcerpt.count) else { return nil }
        let session = LanguageModelSession(instructions: DrawingAIPrompt.structuredInstructions)
        do {
            let output = try await session.respond(
                to: DrawingAIPrompt.titleTagsPrompt(for: context),
                generating: DrawingTitleTagsOutput.self
            ).content
            let sanitised = DrawingTitleTagsSanitizer.sanitize(title: output.title, tags: output.tags)
            return sanitised.title.isEmpty ? nil : sanitised
        } catch {
            return nil
        }
    }

    private func remember(_ hash: String, _ result: DrawingTitleTags) {
        if cache[hash] == nil { cacheOrder.append(hash) }
        cache[hash] = result
        while cacheOrder.count > Self.cacheLimit {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    #if DEBUG
    /// Generates title/tags for one file's bytes directly (DEBUG probe — the gate's live
    /// title/tag run), bypassing the store. Returns the sanitised result or `nil`.
    func debugGenerate(data: Data, fileName: String) async -> DrawingTitleTags? {
        guard #available(macOS 26, iOS 26, *),
              let bundle = DrawingAIContextProvider.make(data: data, fileName: fileName, unsupportedNotes: []) else { return nil }
        return await generate(context: bundle.context)
    }
    #endif
}
