import Foundation

// MARK: - AI engine selection (A2b)
//
// Which engine runs Describe, Ask and Explain: Apple's on-device model, or one of
// the user's configured providers. Pure value logic, decided identically by the
// Settings picker and the viewer's routing, and unit-tested without any UI.
//
// OS gating (v3-plan §10.1): the on-device option is HIDDEN where Apple Intelligence
// can't run (an old OS or ineligible device), but provider engines stay available on
// macOS 14/15 and iOS 17/18 — a user who configures a provider gets the AI features
// there. So the whole AI surface shows whenever on-device is available OR at least
// one provider is configured.

/// The engine actually used for a request.
enum AIEngineChoice: Equatable, Sendable {
    /// Apple's on-device Foundation Models.
    case onDevice
    /// A user-configured cloud/local provider.
    case provider(AIProviderConfig)
}

/// One selectable option for the Settings engine picker.
struct AIEngineOption: Equatable, Identifiable, Sendable {
    /// The stored selection id: `AIEngineSelection.appleID`, or a provider's id.
    var id: String
    /// The user-facing label ("On-device (Apple)" or the provider's display name).
    var label: String
}

enum AIEngineSelection {
    /// The stored id for the on-device engine.
    static let appleID = "apple"

    /// The picker options. The on-device option appears only when it can run; every
    /// configured provider always appears.
    static func options(providers: [AIProviderConfig], onDeviceAvailable: Bool) -> [AIEngineOption] {
        var out: [AIEngineOption] = []
        if onDeviceAvailable {
            out.append(AIEngineOption(id: appleID, label: "On-device (Apple)"))
        }
        out.append(contentsOf: providers.map { AIEngineOption(id: $0.id, label: $0.displayName) })
        return out
    }

    /// Whether the AI surface shows at all: true when on-device is available or any
    /// provider is configured.
    static func shouldShowAISurface(providers: [AIProviderConfig], onDeviceAvailable: Bool) -> Bool {
        onDeviceAvailable || !providers.isEmpty
    }

    /// Resolves the stored selection id to the engine that will actually run, falling
    /// back sensibly when the selected engine is gone (a removed provider, or the
    /// on-device engine becoming unavailable): prefer on-device when available, else
    /// the first configured provider. Returns `nil` only when nothing is available.
    static func resolve(selectedID: String, providers: [AIProviderConfig], onDeviceAvailable: Bool) -> AIEngineChoice? {
        if selectedID == appleID, onDeviceAvailable {
            return .onDevice
        }
        if let provider = providers.first(where: { $0.id == selectedID }) {
            return .provider(provider)
        }
        // Fallback: the stored selection no longer resolves.
        if onDeviceAvailable { return .onDevice }
        if let first = providers.first { return .provider(first) }
        return nil
    }
}
