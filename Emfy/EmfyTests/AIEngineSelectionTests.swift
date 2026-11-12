import Foundation
import Testing

// A2b: the pure engine-selection logic — picker options, the hidden-when-unsupported
// rule, and resolution with fallback.

@Suite struct AIEngineSelectionTests {

    private func provider(_ id: String, _ name: String = "P") -> AIProviderConfig {
        AIProviderConfig(id: id, kind: .anthropic, displayName: name, baseURL: URL(string: "https://api.anthropic.com")!, model: "m")
    }

    @Test func onDeviceOptionHiddenWhenUnavailable() {
        let p = provider("p1", "Claude")
        let hidden = AIEngineSelection.options(providers: [p], onDeviceAvailable: false)
        #expect(hidden.map(\.id) == ["p1"])   // no "apple" option
        let shown = AIEngineSelection.options(providers: [p], onDeviceAvailable: true)
        #expect(shown.map(\.id) == [AIEngineSelection.appleID, "p1"])
    }

    @Test func surfaceShowsWithProviderEvenWhenOnDeviceUnavailable() {
        #expect(AIEngineSelection.shouldShowAISurface(providers: [provider("p1")], onDeviceAvailable: false))
        #expect(AIEngineSelection.shouldShowAISurface(providers: [], onDeviceAvailable: true))
        // Nothing available → hidden.
        #expect(!AIEngineSelection.shouldShowAISurface(providers: [], onDeviceAvailable: false))
    }

    @Test func resolvesSelectedProvider() {
        let p = provider("p1", "Claude")
        #expect(AIEngineSelection.resolve(selectedID: "p1", providers: [p], onDeviceAvailable: true) == .provider(p))
        #expect(AIEngineSelection.resolve(selectedID: AIEngineSelection.appleID, providers: [p], onDeviceAvailable: true) == .onDevice)
    }

    @Test func onDeviceUnavailablePlusProviderResolvesToProvider() {
        // The headline case: apple selected but unavailable, one provider → that provider.
        let p = provider("p1", "Claude")
        #expect(AIEngineSelection.resolve(selectedID: AIEngineSelection.appleID, providers: [p], onDeviceAvailable: false) == .provider(p))
    }

    @Test func nothingAvailableResolvesToNil() {
        #expect(AIEngineSelection.resolve(selectedID: AIEngineSelection.appleID, providers: [], onDeviceAvailable: false) == nil)
    }

    @Test func removedSelectionFallsBack() {
        // A stale selection id (a removed provider) falls back to on-device, else first.
        let p = provider("p1")
        #expect(AIEngineSelection.resolve(selectedID: "gone", providers: [p], onDeviceAvailable: true) == .onDevice)
        #expect(AIEngineSelection.resolve(selectedID: "gone", providers: [p], onDeviceAvailable: false) == .provider(p))
    }
}
