import EMFEdit
import SwiftUI

// MARK: - "Translate…" sheet (X2c)
//
// The user picks a target language; the model translates the drawing's text runs in place
// (scoped to the selection, else the whole drawing). The proposal is shown as a before/after
// preview with an old→new list, overflow and RTL warnings. Nothing applies until the user
// taps Apply (one "Translate" undo). A decode/validation failure shows a clear message and
// applies nothing. The drawing's own text is untrusted and never obeyed (see
// DrawingAITranslateContext).

struct DrawingAITranslateView: View {
    let model: DrawingAITranslateModel
    let onClose: () -> Void

    @Environment(AIProviderStore.self) private var providerStore: AIProviderStore?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            header
            switch model.phase {
            case .idle, .applied:
                if model.hasText { inputForm } else { noText }
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
        .onAppear { model.providerStore = providerStore }
        .aiConsentSheet(
            provider: model.pendingConsent,
            purpose: .drawingData,
            store: providerStore,
            onAllow: { model.consentAllowed() },
            onDeny: { model.consentDeclined() })
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.bubble")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Translate").font(.headline)
                Text("Translates the text of \(model.scopeDescription).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var noText: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("There’s no text to translate here.", systemImage: "text.badge.xmark")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") { onClose() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private var inputForm: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            Text("Choose a language. You’ll see a preview before anything is applied.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Translate to", selection: $model.targetLanguage) {
                ForEach(model.languages) { language in
                    Text(language.englishName).tag(language)
                }
            }
            .accessibilityIdentifier("translateLanguage")
            if !model.engineLabel.isEmpty {
                Text(model.engineLabel).font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Translate") { model.submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("translateSubmit")
            }
        }
    }

    private var thinking: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Translating…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            HStack {
                Spacer()
                Button(role: .cancel) { model.cancel() } label: { Text("Stop") }
            }
        }
        .frame(minHeight: 80)
    }

    private func previewContent(_ preview: DrawingAITranslateModel.Preview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                previewColumn("Before", image: preview.before)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                previewColumn("After", image: preview.after)
            }
            .frame(maxWidth: .infinity)

            ForEach(preview.notes, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Translated to \(preview.languageName):")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(preview.changes) { change in
                            changeRow(change)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            HStack {
                Button("Cancel") { model.cancelPreview(); onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") { model.apply(); onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("translateApply")
            }
        }
    }

    private func changeRow(_ change: DrawingAITranslateModel.Change) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(excerpt(change.before))
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(.caption2).foregroundStyle(.tertiary)
            Text(excerpt(change.after))
            if change.overflow {
                Image(systemName: "arrow.left.and.right.square")
                    .font(.caption2).foregroundStyle(.orange)
                    .help("May be wider than before")
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .lineLimit(1)
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

    private func excerpt(_ string: String) -> String {
        let clean = string.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return clean.count > 40 ? String(clean.prefix(40)) + "…" : clean
    }
}
