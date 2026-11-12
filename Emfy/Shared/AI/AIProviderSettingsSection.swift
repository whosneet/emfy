import SwiftUI

// MARK: - Settings ▸ AI (A2b)
//
// Extends the A1 "Apple Intelligence" group into a full "AI" section, shared by the
// Mac Settings window and the iOS Settings form: the engine picker (on-device when
// available, plus each configured provider), the Providers list with Add / Test
// connection / Load models / Remove, and the separate opt-in for third-party auto
// titles. Keys go straight to the Keychain and are never shown again (only "Key
// saved ✓"). The whole section is hidden when neither on-device AI nor any provider
// is available; the on-device option is hidden when the device can't run it, but
// providers stay available on macOS 14/15 and iOS 17/18.

struct AISettingsSection: View {
    @Environment(EmfySettings.self) private var settings
    @Environment(AIProviderStore.self) private var providers

    /// On-device AI is available when the hardware/OS supports it AND the user left it
    /// on — the engine picker offers it only then.
    private var onDeviceAvailable: Bool {
        settings.useOnDeviceAI && DrawingAIAvailability.current().isAvailable
    }

    /// Whether the device could run on-device AI at all (independent of the toggle).
    private var onDeviceHardwareReady: Bool { DrawingAIAvailability.current().isAvailable }

    /// Show the section when there's any engine to configure or run.
    private var showSection: Bool {
        onDeviceHardwareReady || !providers.providers.isEmpty
    }

    var body: some View {
        @Bindable var settings = settings
        @Bindable var providers = providers
        if showSection {
            // Engine group.
            Section {
                if onDeviceHardwareReady {
                    Toggle("Use on-device AI", isOn: $settings.useOnDeviceAI)
                        .onChange(of: settings.useOnDeviceAI) { _, _ in
                            DrawingTitleTagService.shared.settingsChanged()
                            SpotlightService.shared.settingsChanged()
                        }
                }
                let options = providers.engineOptions(onDeviceAvailable: onDeviceAvailable)
                if options.count > 1 {
                    Picker("AI engine", selection: $providers.selectedEngineID) {
                        ForEach(options) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                }
            } header: {
                Text("AI")
            } footer: {
                Text(AISettingsFooter.engine)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Providers group.
            AIProvidersList()

            // Third-party auto-titling opt-in — only when a provider is the selected
            // engine. Default off; its own consent is checked at generation time.
            if case .provider(let config)? = providers.resolvedEngine(onDeviceAvailable: onDeviceAvailable) {
                Section {
                    Toggle("Also generate titles with \(config.displayName)", isOn: $providers.generateTitlesWithProvider)
                } footer: {
                    Text(AISettingsFooter.titles)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

enum AISettingsFooter {
    static let engine = "Describe, Ask and Explain use the engine you choose here. On-device runs entirely on your device. A provider sends the drawing’s text and your question to the service you configure, only after you allow it. A drawing’s own text is treated as data, never as instructions."
    static let providers = "Add a cloud or local AI provider. Your API key is stored in the Keychain on this device and never shown again. Nothing is sent until you allow a provider on first use."
    static let titles = "Generates short titles and tags for your recent drawings by sending their text to the provider in the background. Off by default; it asks for its own permission before any drawing is sent."
}

// MARK: - Providers list

private struct AIProvidersList: View {
    @Environment(AIProviderStore.self) private var providers
    @State private var editing: ProviderEditIntent?

    var body: some View {
        Section {
            if providers.providers.isEmpty {
                Text("No providers configured.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(providers.providers) { config in
                    Button {
                        editing = ProviderEditIntent(config: config)
                    } label: {
                        AIProviderRow(config: config)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                editing = ProviderEditIntent(config: nil)
            } label: {
                Label("Add Provider…", systemImage: "plus")
            }
        } header: {
            Text("Providers")
        } footer: {
            Text(AISettingsFooter.providers)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $editing) { intent in
            AIProviderEditorSheet(config: intent.config)
        }
    }
}

/// The identity that drives the add/edit sheet; a fresh id per presentation.
private struct ProviderEditIntent: Identifiable {
    let id = UUID()
    /// The provider being edited, or nil when adding.
    let config: AIProviderConfig?
}

/// One provider row: name, kind, model, and whether a key and consent are set.
private struct AIProviderRow: View {
    @Environment(AIProviderStore.self) private var providers
    let config: AIProviderConfig

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.displayName)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if providers.isConsentGranted(config.id) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Allowed")
            }
        }
    }

    private var detail: String {
        var parts = [AIProviderKindLabel.text(config.kind), config.model]
        if !providers.hasKey(for: config.id) { parts.append("no key") }
        return parts.joined(separator: " · ")
    }
}

enum AIProviderKindLabel {
    static func text(_ kind: AIProviderKind) -> String {
        switch kind {
        case .anthropic: return "Anthropic"
        case .openAI: return "OpenAI"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }
}
