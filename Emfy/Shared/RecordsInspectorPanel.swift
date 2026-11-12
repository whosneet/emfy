import EMFParse
import EMFRender
import SwiftUI

// MARK: - Viewer inspector Info | Records segment (F5c)
//
// In read-only viewing the inspector gains an Info | Records segmented control.
// Info keeps the existing file-details view; Records shows the per-record list, a
// type-name filter, the step-through replay controls and the DC-state panel for the
// selected record. Selecting Records swaps the viewer's canvas for the dedicated
// replay view (handled by the host), so this panel only drives the model.

/// Which panel the read-only viewer inspector shows. `ask` appears only when
/// on-device AI is available (A1a).
enum ViewerInspectorTab: Hashable { case info, records, ask }

/// The read-only viewer inspector: an Info | Records (| Ask) segmented control over
/// the caller's Info view, the Records inspector, or the Ask chat. Mirrors
/// `EditorInspectorPanel`'s shape so both inspectors read the same on either
/// platform.
struct ViewerInspectorPanel<Info: View>: View {
    @Binding var tab: ViewerInspectorTab
    let model: RecordInspectorModel
    let summaries: [Int: String]
    let diagnostics: ViewerDiagnostics
    let onClose: () -> Void
    /// The Ask chat model + inputs (A1a). Non-nil only when on-device AI is
    /// available, which is also when the Ask segment is offered.
    var askModel: DrawingAskModel? = nil
    var aiInputs: DrawingAIInspectorInputs? = nil
    @ViewBuilder let info: () -> Info

    private var aiAvailable: Bool { askModel != nil && aiInputs != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    Text("Info").tag(ViewerInspectorTab.info)
                    Text("Records").tag(ViewerInspectorTab.records)
                    if aiAvailable {
                        Text("Ask").tag(ViewerInspectorTab.ask)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                closeButton
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            switch tab {
            case .info: info()
            case .records: RecordsInspectorPanel(model: model, summaries: summaries, diagnostics: diagnostics)
            case .ask:
                if let askModel, let aiInputs {
                    DrawingAskView(model: askModel, inputs: aiInputs)
                } else {
                    info()
                }
            }
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close inspector")
    }
}

// MARK: - Records inspector

/// The Records panel: the filter field, the virtualised record list, the replay
/// controls and the DC-state panel. It drives the shared `RecordInspectorModel`;
/// the host owns the `RecordReplayDriver` and re-renders the canvas as the selection
/// moves.
struct RecordsInspectorPanel: View {
    let model: RecordInspectorModel
    let summaries: [Int: String]
    let diagnostics: ViewerDiagnostics

    /// Record type names the render log reports as skipped/unsupported, so those rows
    /// carry a badge. EMR_HEADER (1) and EMR_EOF (14) are excluded: EMFParse decodes
    /// both to `.unimplemented` (they are structure, not drawing content), so a render
    /// log entry for either must not badge the structural row as "skipped".
    private var unsupportedTypeNames: Set<String> {
        var names = Set<String>()
        for entry in diagnostics.renderLog {
            switch entry {
            case .unimplementedRecord(let type, _), .malformedRecord(let type):
                guard type != 1, type != 14, let name = EMFRecordType.name(for: type) else { continue }
                names.insert(name)
            default:
                break
            }
        }
        return names
    }

    var body: some View {
        let unsupported = unsupportedTypeNames
        VStack(spacing: 0) {
            filterField
            Divider()
            recordList(unsupported: unsupported)
            Divider()
            replayControls
            if !model.stateGroups.isEmpty {
                Divider()
                dcPanel
            }
        }
    }

    // MARK: Filter

    @ViewBuilder
    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField("Filter records", text: Binding(get: { model.filterText }, set: { model.filterText = $0 }))
                .textFieldStyle(.plain)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                #endif
            if !model.filterText.isEmpty {
                Button { model.filterText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: List

    @ViewBuilder
    private func recordList(unsupported: Set<String>) -> some View {
        let indices = model.filteredIndices
        ScrollViewReader { proxy in
            list(indices, unsupported: unsupported)
                // Keep the current record visible as the step index moves (scrubber,
                // ‹ ›, Home/End, or the arrow keys), so the list follows the replay.
                .onChange(of: model.selectedIndex) { _, index in
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(index, anchor: .center) }
                }
        }
    }

    @ViewBuilder
    private func list(_ indices: [Int], unsupported: Set<String>) -> some View {
        List(selection: Binding<Int?>(get: { model.selectedIndex }, set: { if let value = $0 { model.select(value) } })) {
            ForEach(indices, id: \.self) { index in
                recordRow(index, unsupported: unsupported)
                    .tag(index)
                    .id(index)
            }
        }
        #if os(macOS)
        .listStyle(.inset(alternatesRowBackgrounds: true))
        #else
        .listStyle(.plain)
        #endif
        .frame(minHeight: 180)
        // ←/→ step and ⌥←/⌥→ jump to the previous/next drawing record when the list
        // has focus (F5c). The List keeps ↑/↓ for selection. Ignored (so the field
        // keeps its own cursor keys) unless this drawing can step.
        .onKeyPress { press in
            guard model.canStep else { return .ignored }
            switch press.key {
            case .leftArrow:
                press.modifiers.contains(.option) ? model.jumpDrawing(forward: false) : model.step(by: -1)
                return .handled
            case .rightArrow:
                press.modifiers.contains(.option) ? model.jumpDrawing(forward: true) : model.step(by: 1)
                return .handled
            default:
                return .ignored
            }
        }
    }

    @ViewBuilder
    private func recordRow(_ index: Int, unsupported: Set<String>) -> some View {
        let ref = model.refs[index]
        let summary = model.summary(at: index) { summaries[$0] ?? "" }
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("\(index)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34, alignment: .trailing)
                Text(ref.typeName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                badge(ref, unsupported: unsupported)
            }
            HStack(spacing: 8) {
                Text("@\(ref.offset) · \(ref.size) B")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func badge(_ ref: RecordRef, unsupported: Set<String>) -> some View {
        if ref.isEMFPlusCarrier {
            Text("EMF+ (\(ref.emfPlusRecordCount) record\(ref.emfPlusRecordCount == 1 ? "" : "s"))")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.18), in: Capsule())
        } else if unsupported.contains(ref.typeName) {
            Text("skipped")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.orange.opacity(0.16), in: Capsule())
        }
    }

    // MARK: Replay controls

    @ViewBuilder
    private var replayControls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Button { model.home() } label: { Image(systemName: "backward.end.fill") }
                    .accessibilityLabel("First record")
                Button { model.step(by: -1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous record")
                Text(model.positionText)
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 76)
                Button { model.step(by: 1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next record")
                Button { model.end() } label: { Image(systemName: "forward.end.fill") }
                    .accessibilityLabel("Last record")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canStep)

            Slider(
                value: Binding(
                    get: { Double(model.selectedIndex) },
                    set: { model.select(Int($0.rounded())) }
                ),
                in: 0 ... Double(max(1, model.recordCount - 1)),
                step: 1
            )
            .disabled(!model.canStep)
            .accessibilityLabel("Record scrubber")

            if !model.supportsPartial {
                Text(RecordInspectorLogic.emfPlusStepNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: DC panel

    @ViewBuilder
    private var dcPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.stateGroups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title.uppercased())
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        ForEach(group.rows, id: \.label) { row in
                            stateRow(row)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 260)
    }

    @ViewBuilder
    private func stateRow(_ row: RecordStateRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            if let swatch = row.swatch {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(.sRGB, red: swatch.red, green: swatch.green, blue: swatch.blue))
                    .frame(width: 11, height: 11)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(.secondary.opacity(0.4), lineWidth: 0.5))
            }
            Text(row.value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
