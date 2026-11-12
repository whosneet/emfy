import SwiftUI

// MARK: - Settings ▸ Apple Intelligence (A1a)
//
// The "Use on-device AI" toggle, in its own group, shared by the Mac Settings
// window and the iOS Settings form. The whole group is HIDDEN when AI is
// unsupported (an old OS, or a device that can't run Apple Intelligence); it shows
// — with a short reason — only where the feature exists, so the toggle never
// advertises something the device can't do. Off means no AI UI at all.

struct AppleIntelligenceSettingsSection: View {
    @Environment(EmfySettings.self) private var settings

    /// Resolved once per appearance (the OS/model state doesn't change mid-session).
    private var status: DrawingAIAvailabilityStatus { DrawingAIAvailability.current() }

    var body: some View {
        @Bindable var settings = settings
        // Hidden entirely on an unsupported OS / ineligible device.
        if status.shouldShowAISurface {
            Section {
                Toggle("Use on-device AI", isOn: $settings.useOnDeviceAI)
                    .disabled(!status.isAvailable)
                if let reason = status.reasonToShow {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Apple Intelligence")
            } footer: {
                Text(AppleIntelligenceFooter.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The footer, shared verbatim by both platforms.
enum AppleIntelligenceFooter {
    static let text = "Describe, Ask and VoiceOver alt text run entirely on your device with Apple Intelligence. Nothing about your drawings is sent anywhere. A drawing’s own text is treated as data the model describes, never as instructions."
}
