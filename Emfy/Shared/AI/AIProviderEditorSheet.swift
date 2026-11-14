import SwiftUI

// MARK: - Add / edit a provider (A2b)
//
// The sheet behind "Add Provider" and tapping a provider row: the kind (Anthropic /
// OpenAI / OpenAI-compatible, with the OpenRouter / Ollama / LM Studio / custom
// presets), a display name, a base URL, the model (free-text plus a "Load models"
// call), the API key (a SecureField saved straight to the Keychain and never shown
// again — only "Key saved ✓", Replace and Remove), and Test connection. Test
// connection and the first drawing send both go through the consent screen.
//
// The provider is committed to the store as soon as Load models, Test connection or
// Save runs, so those operations act on a real, keyed provider; cancelling an Add
// that never committed persists nothing.

struct AIProviderEditorSheet: View {
    /// The provider being edited, or nil when adding.
    let config: AIProviderConfig?

    @Environment(AIProviderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var kind: AIProviderKind
    @State private var preset: CompatiblePreset
    @State private var name: String
    @State private var baseURLString: String
    @State private var model: String
    @State private var apiKey: String = ""
    /// In edit mode with a saved key: whether the SecureField is revealed to replace it.
    @State private var replacingKey: Bool
    @State private var loadedModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelError: String?
    @State private var isTesting = false
    @State private var testResult: TestOutcome?
    @State private var pendingConsent: AIProviderConfig?
    /// The committed provider id, once this sheet has persisted it.
    @State private var committedID: String?

    enum TestOutcome: Equatable { case ok, failure(String) }

    init(config: AIProviderConfig?) {
        self.config = config
        if let config {
            _kind = State(initialValue: config.kind)
            _preset = State(initialValue: CompatiblePreset.matching(config.baseURL))
            _name = State(initialValue: config.displayName)
            _baseURLString = State(initialValue: config.baseURL.absoluteString)
            _model = State(initialValue: config.model)
            _replacingKey = State(initialValue: false)
            _committedID = State(initialValue: config.id)
        } else {
            _kind = State(initialValue: .anthropic)
            _preset = State(initialValue: .openRouter)
            _name = State(initialValue: AIProviderKindLabel.text(.anthropic))
            _baseURLString = State(initialValue: AIProviderPresets.anthropicBaseURL.absoluteString)
            _model = State(initialValue: AIProviderPresets.anthropicDefaultModel)
            _replacingKey = State(initialValue: false)
            _committedID = State(initialValue: nil)
        }
    }

    private var isEditing: Bool { config != nil }
    private var providerID: String { committedID ?? config?.id ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                kindSection
                detailsSection
                keySection
                modelSection
                actionsSection
                if isEditing { manageSection }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Provider" : "Add Provider")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Done" : "Add") { save() }
                        .disabled(!canSave)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .aiConsentSheet(
                provider: pendingConsent,
                purpose: .drawingData,
                store: store,
                onAllow: { pendingConsent = nil; Task { await runTest() } },
                onDeny: { pendingConsent = nil })
        }
        #if os(macOS)
        .frame(width: 480, height: 560)
        #endif
    }

    // MARK: Sections

    @ViewBuilder
    private var kindSection: some View {
        Section {
            if isEditing {
                LabeledContent("Type", value: AIProviderKindLabel.text(kind))
            } else {
                Picker("Type", selection: $kind) {
                    ForEach(AIProviderKind.allCases, id: \.self) { k in
                        Text(AIProviderKindLabel.text(k)).tag(k)
                    }
                }
                .onChange(of: kind) { _, new in applyKindDefaults(new) }
                if kind == .openAICompatible {
                    Picker("Preset", selection: $preset) {
                        ForEach(CompatiblePreset.allCases, id: \.self) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .onChange(of: preset) { _, new in
                        if let url = new.baseURL { baseURLString = url.absoluteString }
                    }
                }
            }
        }
    }

    private var detailsSection: some View {
        Section {
            TextField("Name", text: $name)
                #if os(iOS)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                #endif
            if kind == .openAICompatible {
                TextField("Base URL", text: $baseURLString)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            } else {
                LabeledContent("Base URL", value: baseURLString)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Details")
        } footer: {
            // S2: consent (and the stored key) were approved for a specific host. Warn
            // before saving that changing it re-targets where drawing data would go and
            // requires approving the new host again.
            if isEditing, hostChanged, store.isConsentGranted(providerID) {
                Text("You’ve pointed this provider at a different server. Emfy will ask your permission again before sending any drawing there.")
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Whether the edited Base URL now points at a different host (or kind) than the saved
    /// provider, so saving will drop consent (S2).
    private var hostChanged: Bool {
        guard let original = config, let draft = draftConfig() else { return false }
        return !AIProviderStore.consentSurvivesEdit(from: original, to: draft)
    }

    @ViewBuilder
    private var keySection: some View {
        Section {
            if isEditing, store.hasKey(for: providerID), !replacingKey {
                LabeledContent("API key") {
                    Label("Key saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                }
                Button("Replace Key…") { replacingKey = true }
                Button("Remove Key", role: .destructive) {
                    store.setKey("", for: providerID)
                    apiKey = ""
                }
            } else {
                SecureField("API key", text: $apiKey)
                    .textContentType(.none)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
        } header: {
            Text("API key")
        } footer: {
            Text("Stored only in the Keychain on this device. It is never shown again and never sent anywhere except to this provider.")
        }
    }

    private var modelSection: some View {
        Section {
            TextField("Model", text: $model)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            if !loadedModels.isEmpty {
                Picker("Available models", selection: $model) {
                    ForEach(loadedModels, id: \.self) { Text($0).tag($0) }
                }
            }
            Button {
                Task { await loadModels() }
            } label: {
                if isLoadingModels {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading models…") }
                } else {
                    Label("Load models", systemImage: "arrow.down.circle")
                }
            }
            .disabled(isLoadingModels)
            if let modelError {
                Text(modelError).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Model")
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                startTest()
            } label: {
                if isTesting {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Testing…") }
                } else {
                    Label("Test connection", systemImage: "bolt.horizontal.circle")
                }
            }
            .disabled(isTesting || !canSave)
            switch testResult {
            case .ok:
                Label("Connection OK", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }
        } footer: {
            Text("Sends one tiny message to check the key and model. It asks for your permission first.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var manageSection: some View {
        Section {
            if store.isConsentGranted(providerID) {
                Button("Revoke consent") { store.revokeConsent(providerID) }
            }
            Button("Remove Provider", role: .destructive) {
                store.removeProvider(providerID)
                dismiss()
            }
        }
    }

    // MARK: Logic

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var resolvedBaseURL: URL? {
        switch kind {
        case .anthropic: return AIProviderPresets.anthropicBaseURL
        case .openAI: return AIProviderPresets.openAIBaseURL
        case .openAICompatible: return URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && resolvedBaseURL != nil && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func applyKindDefaults(_ kind: AIProviderKind) {
        switch kind {
        case .anthropic:
            baseURLString = AIProviderPresets.anthropicBaseURL.absoluteString
            if model.isEmpty { model = AIProviderPresets.anthropicDefaultModel }
            if trimmedName.isEmpty || isPresetName { name = AIProviderKindLabel.text(.anthropic) }
        case .openAI:
            baseURLString = AIProviderPresets.openAIBaseURL.absoluteString
            if trimmedName.isEmpty || isPresetName { name = AIProviderKindLabel.text(.openAI) }
        case .openAICompatible:
            if let url = preset.baseURL { baseURLString = url.absoluteString }
            if trimmedName.isEmpty || isPresetName { name = preset.label }
        }
    }

    /// Whether the name is still one of the auto-filled preset names (so switching kind
    /// may update it, without clobbering a name the user typed).
    private var isPresetName: Bool {
        let presets = [AIProviderKindLabel.text(.anthropic), AIProviderKindLabel.text(.openAI)] + CompatiblePreset.allCases.map(\.label)
        return presets.contains(trimmedName)
    }

    /// Builds the current config (reusing the existing id when editing).
    private func draftConfig() -> AIProviderConfig? {
        guard let baseURL = resolvedBaseURL else { return nil }
        let id = config?.id ?? committedID ?? UUID().uuidString
        return AIProviderConfig(id: id, kind: kind, displayName: trimmedName, baseURL: baseURL, model: model.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Persists the provider and its key, returning the committed config.
    @discardableResult
    private func commit() -> AIProviderConfig? {
        guard let draft = draftConfig() else { return nil }
        if isEditing {
            store.updateProvider(draft)
            if replacingKey || !apiKey.isEmpty { store.setKey(apiKey, for: draft.id) }
        } else if committedID == nil {
            store.addProvider(draft, key: apiKey)
            committedID = draft.id
        } else {
            store.updateProvider(draft)
            if !apiKey.isEmpty { store.setKey(apiKey, for: draft.id) }
        }
        replacingKey = false
        return store.provider(id: draft.id) ?? draft
    }

    private func save() {
        commit()
        dismiss()
    }

    private func loadModels() async {
        guard let draft = draftConfig() else { return }
        isLoadingModels = true
        modelError = nil
        do {
            let key = apiKey.isEmpty ? nil : apiKey
            let models = try await store.loadModels(for: draft, explicitKey: key)
            loadedModels = models
            if models.isEmpty { modelError = "No models returned. Type the model name instead." }
        } catch let error as ProviderError {
            modelError = error.friendlyMessage
        } catch {
            modelError = "Couldn’t load models."
        }
        isLoadingModels = false
    }

    private func startTest() {
        guard let committed = commit() else { return }
        testResult = nil
        if !store.isConsentGranted(committed.id) {
            pendingConsent = committed
            return
        }
        Task { await runTest() }
    }

    private func runTest() async {
        guard let committed = commit() else { return }
        isTesting = true
        testResult = nil
        let error = await store.testConnection(config: committed)
        isTesting = false
        testResult = error.map { .failure($0.friendlyMessage) } ?? .ok
    }
}

// MARK: - OpenAI-compatible presets

enum CompatiblePreset: String, CaseIterable, Sendable {
    case openRouter, ollama, lmStudio, custom

    var label: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .custom: return "Custom URL"
        }
    }

    var baseURL: URL? {
        switch self {
        case .openRouter: return AIProviderPresets.openRouterBaseURL
        case .ollama: return AIProviderPresets.ollamaBaseURL
        case .lmStudio: return AIProviderPresets.lmStudioBaseURL
        case .custom: return nil
        }
    }

    /// The preset whose base URL matches `url`, else `.custom`.
    static func matching(_ url: URL) -> CompatiblePreset {
        allCases.first { $0.baseURL == url } ?? .custom
    }
}
