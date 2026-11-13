import EMFEdit
import SwiftUI

/// Hosts the "New Drawing from Description…" sheet with its own view-model, shared by the
/// Mac File menu and the iOS library "+". On Create it hands the generated EMF bytes to
/// `onCreate` (which opens them as a new, unsaved document); dismiss discards.
struct GenerateDrawingSheet: View {
    let onCreate: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model = DrawingAIGenerateModel()

    var body: some View {
        DrawingAIGenerateView(model: model, onCreate: onCreate, onClose: { dismiss() })
            #if os(iOS)
            .presentationDetents([.medium, .large])
            #endif
    }
}

// MARK: - "New Drawing from Description…" sheet (X2d)
//
// The user types a description and picks a page; the model proposes a drawing, shown as a
// preview render with a short summary ("12 shapes, 3 text labels"). Nothing is created until
// the user taps Create, which opens it as a NEW, unsaved, editable document (no file is
// written until they save). A decode/validation failure — or an on-device refusal — shows a
// clear message and creates nothing.

struct DrawingAIGenerateView: View {
    let model: DrawingAIGenerateModel
    /// Called with the generated EMF bytes when the user taps Create.
    let onCreate: (Data) -> Void
    let onClose: () -> Void

    @Environment(AIProviderStore.self) private var providerStore: AIProviderStore?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            header
            switch model.phase {
            case .idle, .created:
                inputForm
            case .thinking:
                thinking
            case .preview:
                if let preview = model.preview { previewContent(preview) } else { inputForm }
            case .failed(let message):
                failure(message)
            }
        }
        .padding(22)
        #if os(macOS)
        .frame(width: 520)
        #endif
        .onAppear { model.providerStore = providerStore; fieldFocused = true }
        .aiConsentSheet(
            provider: model.pendingConsent,
            purpose: .drawingData,
            store: providerStore,
            onAllow: { model.consentAllowed() },
            onDeny: { model.consentDeclined() })
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("New Drawing from Description").font(.headline)
                Text("Describe a drawing and Emfy will create an editable version.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var inputForm: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            TextField("e.g. a simple flowchart with three boxes connected by arrows, labelled Start, Process, End",
                      text: $model.descriptionText, axis: .vertical)
                .lineLimit(2 ... 5)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .accessibilityIdentifier("generateDescription")
                .onSubmit { model.submit() }
            Picker("Page", selection: $model.page) {
                ForEach(GenerationPagePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .accessibilityIdentifier("generatePage")
            if !model.engineLabel.isEmpty {
                Text(model.engineLabel).font(.caption2).foregroundStyle(.secondary)
            }
            Text("You’ll see a preview before anything is created.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Generate") { model.submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("generateSubmit")
            }
        }
    }

    private var thinking: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Drawing your idea…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            HStack {
                Spacer()
                Button(role: .cancel) { model.cancel() } label: { Text("Stop") }
            }
        }
        .frame(minHeight: 80)
    }

    private func previewContent(_ preview: DrawingAIGenerateModel.Preview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(decorative: preview.image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 280)
                .background(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Label(preview.summary, systemImage: "square.on.square.dashed")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { model.cancelPreview(); onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    model.create { data in onCreate(data) }
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("generateCreate")
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Try Again") { model.reset() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
