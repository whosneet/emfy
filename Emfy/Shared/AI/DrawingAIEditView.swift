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
        sheetBody
            .onAppear { model.providerStore = providerStore; fieldFocused = true }
            // Cancel an in-flight request if the sheet is swiped away (C5e U4).
            .onDisappear { model.cancel() }
            // Announce the proposed edit (or failure) to VoiceOver (C5e A6).
            .onChange(of: model.phase) { _, phase in
                switch phase {
                case .preview where model.preview != nil:
                    VoiceOverAnnouncement.post("Preview ready. Review the proposed edit and apply.")
                case .failed(let message):
                    VoiceOverAnnouncement.post(message)
                default:
                    break
                }
            }
            .aiConsentSheet(
                provider: model.pendingConsent,
                purpose: .drawingData,
                store: providerStore,
                onAllow: { model.consentAllowed() },
                onDeny: { model.consentDeclined() })
    }

    #if os(macOS)
    private var sheetBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            phaseContent
            phaseActions
        }
        .padding(22)
        .frame(width: 520)
    }
    #else
    // Scroll the phase content and pin the actions so Apply/Propose stay reachable at large
    // accessibility sizes and in landscape (C5e A3).
    private var sheetBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                phaseContent
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            phaseActions
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(.bar)
        }
    }
    #endif

    @ViewBuilder
    private var phaseContent: some View {
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

    private var phaseActions: some View {
        Group {
            switch model.phase {
            case .idle, .applied:
                inputActions
            case .thinking:
                thinkingActions
            case .preview:
                if model.preview != nil { previewActions } else { inputActions }
            case .failed:
                failureActions
            }
        }
        // Single-line labels that shrink rather than wrap into a hyphenated circle at the
        // largest accessibility text sizes (C5e A3 review).
        .lineLimit(1)
        .minimumScaleFactor(0.6)
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
        }
    }

    private var inputActions: some View {
        @Bindable var model = model
        return HStack {
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

    private var thinking: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Preparing your edit…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 60)
    }

    private var thinkingActions: some View {
        HStack {
            Spacer()
            Button(role: .cancel) { model.cancel() } label: { Text("Stop") }
        }
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
        }
    }

    private var previewActions: some View {
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
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var failureActions: some View {
        HStack {
            Button("Close") { onClose() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Try Again") { model.reset() }
                .buttonStyle(.borderedProminent)
        }
    }
}
