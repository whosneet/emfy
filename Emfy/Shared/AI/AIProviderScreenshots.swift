#if DEBUG
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - DEBUG provider screenshots (A2b)
//
// Captures the A2b provider surfaces — the Settings ▸ AI section, the provider
// editor, the consent screen, and an Ask answer via a provider — with no Screen
// Recording permission and no real network or key. The provider store is seeded with
// a stubbed Anthropic provider, and a DEBUG `URLProtocol` returns a canned answer so
// the Ask footnote ("via Anthropic · claude-opus-5-5") comes from a genuine stream.
//
// macOS: the real views are hosted offscreen and rendered with `cacheDisplay`,
// triggered by `-EmfyDebugProviderShots <base>`, writing <base>-{settings,editor,
// consent,ask}.png then exiting. iOS: SwiftUI's offscreen `ImageRenderer` can't
// rasterise a Form/List, so instead the app shows the seeded Settings screen as its
// root when launched with `-EmfyDebugAISettings`, and the simulator screen is shot
// externally. Inside `#if DEBUG`, so Release has none of it.

enum AIProviderScreenshots {

    /// A seeded store with one stubbed Anthropic provider, consent granted, selected.
    @MainActor
    static func seededStore() -> (AIProviderStore, AIProviderConfig) {
        let defaults = UserDefaults(suiteName: "emfy.screenshot.providers") ?? .standard
        for key in defaults.dictionaryRepresentation().keys { defaults.removeObject(forKey: key) }
        let store = AIProviderStore(
            defaults: defaults,
            keyStore: InMemoryKeyStore(),
            consentStore: AIConsentStore(defaults: defaults),
            sessionFactory: { AITransport.makeSession(protocolClasses: [ProviderShotStubProtocol.self]) })
        let config = AIProviderConfig(kind: .anthropic, displayName: "Anthropic", baseURL: AIProviderPresets.anthropicBaseURL, model: AIProviderPresets.anthropicDefaultModel)
        store.addProvider(config, key: "sk-screenshot-demo")
        store.grantConsent(config.id, purpose: .drawingData)
        store.selectedEngineID = config.id
        return (store, config)
    }

    @MainActor
    static func screenshotSettings() -> EmfySettings {
        EmfySettings(defaults: UserDefaults(suiteName: "emfy.screenshot.providers.settings") ?? .standard)
    }

    // MARK: iOS — the seeded Settings screen as the app root

    /// Whether the app was launched to show the seeded AI Settings for a screenshot.
    static var iosSettingsRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-EmfyDebugAISettings")
    }

    /// The seeded AI Settings screen (iOS screenshot d), shown as the window root.
    @MainActor
    static func iosSettingsScreen() -> some View {
        let (store, _) = seededStore()
        return NavigationStack {
            Form { AISettingsSection() }
                .navigationTitle("Settings")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
        .environment(screenshotSettings())
        .environment(store)
    }

    // MARK: macOS — offscreen capture

    #if os(macOS)
    static func runIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-EmfyDebugProviderShots"), i + 1 < args.count else { return }
        let base = args[i + 1]
        Task { @MainActor in
            await captureAll(base: base)
            exit(0)
        }
    }

    @MainActor
    private static func captureAll(base: String) async {
        let (store, config) = seededStore()
        let settings = screenshotSettings()

        // (a) Settings ▸ AI with the configured provider.
        capture(Form { AISettingsSection() }
            .formStyle(.grouped)
            .environment(settings)
            .environment(store),
            size: CGSize(width: 520, height: 420), to: base + "-settings.png")

        // (b) The provider editor (shows "Key saved", model claude-opus-5-5).
        capture(AIProviderEditorSheet(config: config).environment(store),
                size: CGSize(width: 480, height: 560), to: base + "-editor.png")

        // (c) The consent screen for the provider.
        capture(AIConsentSheet(content: AIConsentSheetContent.make(provider: config, purpose: .drawingData), onAllow: {}, onDeny: {}),
                size: CGSize(width: 440, height: 560), to: base + "-consent.png")

        // (d) An Ask answer via the provider — a genuine stubbed stream.
        if let data = DrawingAIDebugProbe.makeLongTextDrawing(lineCount: 12, token: "EMFY-DEMO") {
            let ask = DrawingAskModel()
            ask.providerStore = store
            let inputs = DrawingAIInspectorInputs(contentID: 7, fileName: "demo.emf", unsupportedNotes: [], dataProvider: { data })
            ask.prepare(contentID: 7, dataProvider: { data }, fileName: "demo.emf", unsupportedNotes: [])
            ask.draft = "What kind of drawing is this?"
            ask.send()
            await wait(seconds: 20) { !ask.isResponding && ask.messages.last?.role == .assistant && ask.messages.last?.streaming == false }
            capture(DrawingAskView(model: ask, inputs: inputs).environment(store),
                    size: CGSize(width: 380, height: 440), to: base + "-ask.png")
        }
    }

    @MainActor
    private static func wait(seconds: Double, until condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    @MainActor
    private static func capture<V: View>(_ view: V, size: CGSize, to path: String) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let content = window.contentView, content.bounds.width > 0,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        window.orderOut(nil)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
    #endif
}

/// A DEBUG URLProtocol that returns a canned Anthropic text answer, so a provider Ask
/// can be shot without a real network or key.
final class ProviderShotStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"id":"m","role":"assistant"}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"This looks like a vector drawing made mostly of text and simple shapes — a short labelled diagram."}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{}}

        event: message_stop
        data: {"type":"message_stop"}


        """
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://api.anthropic.com")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(sse.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
