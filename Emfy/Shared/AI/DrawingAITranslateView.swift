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

    /// Cap the preview change list so a large translation doesn't build hundreds of rows in
    /// the non-lazy stack (C5e L5).
    private static let previewRowCap = 50

    var body: some View {
        sheetBody
            .onAppear { model.providerStore = providerStore }
            // Cancel an in-flight request if the sheet is swiped away (C5e U4).
            .onDisappear { model.cancel() }
            // Announce the translation (or failure) to VoiceOver (C5e A6).
            .onChange(of: model.phase) { _, phase in
                switch phase {
                case .preview where model.preview != nil:
                    VoiceOverAnnouncement.post("Translation ready. Review and apply.")
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
    // Scroll the phase content and pin the actions so Apply/Translate stay reachable at
    // large accessibility sizes and in landscape (C5e A3).
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
            if model.hasText { inputForm } else { noText }
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
                if model.hasText { inputActions } else { noTextActions }
            case .thinking:
                thinkingActions
            case .preview:
                if model.preview != nil { previewActions } else { inputActions }
            case .failed:
                failureActions
            }
        }
        // Single-line labels that shrink rather than wrap at the largest AX sizes (C5e A3 review).
        .lineLimit(1)
        .minimumScaleFactor(0.6)
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
        Label("There’s no text to translate here.", systemImage: "text.badge.xmark")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var noTextActions: some View {
        HStack {
            Spacer()
            Button("Close") { onClose() }.keyboardShortcut(.cancelAction)
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
        }
    }

    private var inputActions: some View {
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

    private var thinking: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Translating…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 60)
    }

    private var thinkingActions: some View {
        HStack {
            Spacer()
            Button(role: .cancel) { model.cancel() } label: { Text("Stop") }
        }
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
                        ForEach(preview.changes.prefix(Self.previewRowCap)) { change in
                            changeRow(change)
                        }
                        if preview.changes.count > Self.previewRowCap {
                            Text("and \(preview.changes.count - Self.previewRowCap) more")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 160)
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
                .accessibilityIdentifier("translateApply")
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

    private func excerpt(_ string: String) -> String {
        let clean = string.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return clean.count > 40 ? String(clean.prefix(40)) + "…" : clean
    }
}
