import EMFEdit
import SwiftUI

// MARK: - "Edit with AI…" sheet (X2a)
//
// The user types an instruction ("make all the headings dark blue and 2pt bigger"); the
// model proposes an EditPlan, which is shown as a before/after preview with a plain op
// list and any warnings. Nothing applies until the user taps Apply (one "AI Edit" undo).
// A decode/validation failure shows a clear message and applies nothing. The drawing's
// own text is untrusted and never obeyed (the model enforces this; see DrawingAIEditContext).

struct DrawingAIEditView: View {
    let model: DrawingAIEditModel
    let onClose: () -> Void

    @Environment(AIProviderStore.self) private var providerStore: AIProviderStore?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            header
            switch model.phase {
            case .idle, .applied:
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
            Image(systemName: "wand.and.stars.inverse")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Edit with AI").font(.headline)
                Text("Applies to \(model.scopeDescription).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var inputForm: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            Text("Describe the change you want. You’ll see a preview before anything is applied.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("e.g. make all the headings dark blue and 2pt bigger", text: $model.instruction, axis: .vertical)
                .lineLimit(2 ... 4)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .accessibilityIdentifier("aiEditInstruction")
                .onSubmit { model.submit() }
            if !model.engineLabel.isEmpty {
                Text(model.engineLabel).font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Propose Edit") { model.submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("aiEditSubmit")
            }
        }
    }

    private var thinking: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Preparing your edit…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            HStack {
                Spacer()
                Button(role: .cancel) { model.cancel() } label: { Text("Stop") }
            }
        }
        .frame(minHeight: 80)
    }

    private func previewContent(_ preview: DrawingAIEditModel.Preview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                previewColumn("Before", image: preview.before)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                previewColumn("After", image: preview.after)
            }
            .frame(maxWidth: .infinity)

            if !preview.warnings.isEmpty {
                ForEach(preview.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("This will:").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(preview.operations, id: \.self) { line in
                    Label(line, systemImage: "checkmark.circle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Button("Cancel") { model.cancelPreview(); onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") { model.apply(); onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("aiEditApply")
            }
        }
    }

    private func previewColumn(_ title: String, image: CGImage) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 200, maxHeight: 200)
                .background(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
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
