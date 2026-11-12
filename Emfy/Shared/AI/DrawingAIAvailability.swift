import FoundationModels
import Foundation

// MARK: - On-device AI availability (A1a)
//
// Whether Emfy's on-device AI (Apple Foundation Models) can run, and why not when
// it can't. Two layers gate it (docs/v3-plan §10.1 "OS gating"):
//   1. the OS — Foundation Models exist only on macOS 26 / iOS 26 and later, so
//      everything is `#available(macOS 26, iOS 26, *)`-gated and the whole feature
//      is simply absent on macOS 14/15 and iOS 17/18;
//   2. the device + model — even on a new OS, a device may not be eligible for
//      Apple Intelligence, the user may have it switched off, or the model may
//      still be downloading (`SystemLanguageModel.default.availability`).
//
// The UI HIDES the AI surface entirely when it's unsupported (old OS, or a device
// that can never run it), and shows only a short, user-actionable reason when AI
// is merely switched off or not ready yet — the two states the user can change.
//
// The mapping is a pure function over a `ModelProbe` seam so it is unit-tested
// without a live model; the one gated resolver reads the live availability and
// feeds it through that same mapping.

/// Why on-device AI is unavailable. The first two are permanent for this
/// device/OS (the UI hides AI); the last two are states the user can change (the
/// UI shows a short reason).
enum DrawingAIReason: Equatable, Sendable {
    /// The OS is older than macOS 26 / iOS 26 — Foundation Models don't exist.
    case unsupportedOS
    /// The device can't run Apple Intelligence at all.
    case deviceNotEligible
    /// Apple Intelligence is switched off in system settings.
    case appleIntelligenceNotEnabled
    /// The model is still downloading / preparing.
    case modelNotReady

    /// A short, user-facing reason — but only for the states the user can act on.
    /// `nil` for the permanent cases, so the UI hides AI rather than nagging.
    var userFacingReason: String? {
        switch self {
        case .unsupportedOS, .deviceNotEligible:
            return nil
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings to use on-device AI."
        case .modelNotReady:
            return "The on-device model is still getting ready. Try again in a moment."
        }
    }
}

/// Whether on-device AI can run, and why not. `Equatable`/`Sendable` so it can be
/// held in state and compared across view updates.
enum DrawingAIAvailabilityStatus: Equatable, Sendable {
    case available
    case unavailable(DrawingAIReason)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// Whether the AI surface should appear at all. Hidden for an unsupported OS or
    /// an ineligible device; shown (with a reason) when it's merely off or not
    /// ready, so the user knows the feature exists and how to enable it.
    var shouldShowAISurface: Bool {
        switch self {
        case .available:
            return true
        case .unavailable(let reason):
            return reason.userFacingReason != nil
        }
    }

    /// The short reason to show when AI is present-but-unavailable, else `nil`.
    var reasonToShow: String? {
        if case .unavailable(let reason) = self { return reason.userFacingReason }
        return nil
    }
}

/// A test seam mirroring `SystemLanguageModel.Availability`, so the mapping can be
/// exercised for every state without a live model.
enum DrawingAIModelProbe: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
}

enum DrawingAIAvailability {

    /// The pure mapping. `osSupported == false` (an old OS, decided by the caller's
    /// `#available` check) always wins and hides AI; otherwise the model probe
    /// decides. A `nil` probe with a supported OS means "couldn't read the model
    /// state", treated as not-ready.
    static func status(osSupported: Bool, probe: DrawingAIModelProbe?) -> DrawingAIAvailabilityStatus {
        guard osSupported else { return .unavailable(.unsupportedOS) }
        switch probe {
        case .available:
            return .available
        case .deviceNotEligible:
            return .unavailable(.deviceNotEligible)
        case .appleIntelligenceNotEnabled:
            return .unavailable(.appleIntelligenceNotEnabled)
        case .modelNotReady, nil:
            return .unavailable(.modelNotReady)
        }
    }

    /// The live status on this device: the OS gate plus the system model's current
    /// availability. Safe to call on any OS — on macOS 14/15 or iOS 17/18 the
    /// `#available` check fails and it reports `.unsupportedOS` without touching
    /// Foundation Models.
    static func current() -> DrawingAIAvailabilityStatus {
        if #available(macOS 26, iOS 26, *) {
            return status(osSupported: true, probe: liveProbe())
        }
        return status(osSupported: false, probe: nil)
    }

    /// Reads `SystemLanguageModel.default.availability` into the test seam.
    @available(macOS 26, iOS 26, *)
    private static func liveProbe() -> DrawingAIModelProbe {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        @unknown default:
            return .modelNotReady
        }
    }
}
