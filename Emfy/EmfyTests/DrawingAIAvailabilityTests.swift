import Foundation
import Testing

// A1a: the pure availability mapping — OS gate plus the four model states — and
// which of them show a user-facing reason vs hide the AI surface entirely. No live
// model is needed: the mapping is exercised through the `DrawingAIModelProbe` seam.

@Suite struct DrawingAIAvailabilityTests {

    @Test func unsupportedOSHidesEverythingRegardlessOfProbe() {
        for probe: DrawingAIModelProbe? in [nil, .available, .deviceNotEligible, .modelNotReady] {
            let status = DrawingAIAvailability.status(osSupported: false, probe: probe)
            #expect(status == .unavailable(.unsupportedOS))
            #expect(!status.isAvailable)
            #expect(!status.shouldShowAISurface)   // hidden entirely
            #expect(status.reasonToShow == nil)
        }
    }

    @Test func availableWhenOSAndModelReady() {
        let status = DrawingAIAvailability.status(osSupported: true, probe: .available)
        #expect(status == .available)
        #expect(status.isAvailable)
        #expect(status.shouldShowAISurface)
        #expect(status.reasonToShow == nil)
    }

    @Test func deviceNotEligibleHidesTheSurface() {
        let status = DrawingAIAvailability.status(osSupported: true, probe: .deviceNotEligible)
        #expect(status == .unavailable(.deviceNotEligible))
        #expect(!status.isAvailable)
        // An ineligible device can never run it, so the surface stays hidden.
        #expect(!status.shouldShowAISurface)
        #expect(status.reasonToShow == nil)
    }

    @Test func notEnabledShowsAnActionableReason() {
        let status = DrawingAIAvailability.status(osSupported: true, probe: .appleIntelligenceNotEnabled)
        #expect(status == .unavailable(.appleIntelligenceNotEnabled))
        #expect(!status.isAvailable)
        // Merely off: show the surface with a short reason the user can act on.
        #expect(status.shouldShowAISurface)
        #expect(status.reasonToShow?.isEmpty == false)
    }

    @Test func notReadyShowsAnActionableReason() {
        let status = DrawingAIAvailability.status(osSupported: true, probe: .modelNotReady)
        #expect(status == .unavailable(.modelNotReady))
        #expect(status.shouldShowAISurface)
        #expect(status.reasonToShow?.isEmpty == false)
    }

    @Test func nilProbeOnSupportedOSTreatedAsNotReady() {
        let status = DrawingAIAvailability.status(osSupported: true, probe: nil)
        #expect(status == .unavailable(.modelNotReady))
    }

    @Test func liveCurrentDoesNotCrashAndAgreesWithOSGate() {
        // Smoke test: `current()` is safe to call on any OS. On macOS 14/15 it must
        // report `.unsupportedOS`; on 26+ it reflects the device's model state.
        let status = DrawingAIAvailability.current()
        if #available(macOS 26, iOS 26, *) {
            #expect(status != .unavailable(.unsupportedOS) || !status.isAvailable)
        } else {
            #expect(status == .unavailable(.unsupportedOS))
        }
    }
}
