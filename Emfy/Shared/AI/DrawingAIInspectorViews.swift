import SwiftUI

// MARK: - AI inspector views (A1a)
//
// The Describe section (in the Info segment) and the Ask chat (its own inspector
// segment). Both are shared by the Mac and iPad viewers and only appear when
// on-device AI is available. Answers are plain text — no links, no executed
// markdown.

/// The drawing-specific inputs the AI views need, gathered by the viewer: a stable
/// content id, the file name, the "couldn't show" summaries, and a closure that
/// resolves the drawing's bytes on demand (off the main actor).
struct DrawingAIInspectorInputs {
    var contentID: Int
    var fileName: String
    var unsupportedNotes: [String]
    var dataProvider: @Sendable () async -> Data?
}

// MARK: - Describe (Info segment)

/// A "Describe" row and the streamed description, shown in the Info inspector. One
/// Form `Section`, so it sits with the other grouped rows.
struct DrawingDescribeSection: View {
    let model: DrawingDescribeModel
    let altTextStore: DrawingAltTextStore
    let inputs: DrawingAIInspectorInputs

    var body: some View {
        Section {
            switch model.phase {
            case .idle:
                describeButton(title: "Describe this drawing")
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the drawing…").foregroundStyle(.secondary)
                }
            case .streaming, .done:
                if !model.text.isEmpty {
                    Text(model.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.phase == .streaming {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Describing…").foregroundStyle(.secondary)
                    }
                } else {
                    describeButton(title: "Describe again")
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                describeButton(title: "Try again")
            }
        } header: {
            Label("Describe", systemImage: "sparkles")
        }
    }

    private func describeButton(title: String) -> some View {
        Button {
            model.describe(
                contentID: inputs.contentID,
                dataProvider: inputs.dataProvider,
                fileName: inputs.fileName,
                unsupportedNotes: inputs.unsupportedNotes,
                altTextStore: altTextStore
            )
        } label: {
            Label(title, systemImage: "sparkles")
        }
        .accessibilityIdentifier("describeDrawing")
    }
}

// MARK: - Ask (its own segment)

/// The Ask chat: streamed answers grounded in the open drawing, a "Used: …" tool
/// footnote per answer, a question field and a Send/Stop button.
struct DrawingAskView: View {
    let model: DrawingAskModel
    let inputs: DrawingAIInspectorInputs

    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            transcript
            Divider()
            composer(model: model)
        }
        .onAppear {
            model.prepare(
                contentID: inputs.contentID,
                dataProvider: inputs.dataProvider,
                fileName: inputs.fileName,
                unsupportedNotes: inputs.unsupportedNotes
            )
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.messages.isEmpty {
                        emptyState
                    }
                    ForEach(model.messages) { message in
                        messageRow(message).id(message.id)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.messages.last?.text) { _, _ in
                if let last = model.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Ask about this drawing", systemImage: "bubble.left.and.text.bubble.right")
                .font(.callout.weight(.medium))
            Text("For example: “What text is in this drawing?” Answers run on your device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func messageRow(_ message: DrawingAskModel.Message) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 24)
                Text(message.text)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                if message.text.isEmpty && message.streaming {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…").foregroundStyle(.secondary)
                    }
                } else {
                    Text(message.text)
                        .foregroundStyle(message.failed ? .secondary : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !message.toolsUsed.isEmpty {
                    Text("Used: \(message.toolsUsed.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func composer(model: DrawingAskModel) -> some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            TextField("Ask about this drawing", text: $model.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1 ... 4)
                .focused($fieldFocused)
                .onSubmit(send)
                .disabled(model.isResponding)
            if model.isResponding {
                Button(role: .cancel) { model.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!model.canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func send() {
        guard model.canSend else { return }
        model.send()
    }
}
