import EMFEdit
import SwiftUI

// MARK: - The "Check" inspector segment (X1a)
//
// Accessibility & legibility check for the open drawing: a collapsible content report
// (fonts, colours, images, text, page, counts, unsupported records), the deterministic
// findings grouped by kind with severity icons, a one-tap fix per finding behind a
// before/after preview + confirm, "fix all of this kind" behind a count confirm, an
// optional AI summary of the findings, and a Markdown report export. Shown whether or
// not AI is available; the Summarise button is hidden when no engine is configured.
//
// This view imports EMFEdit to render the report/findings value types; the host panes
// stay EMFEdit-free and only read the model's app-typed outputs.

struct DrawingCheckView: View {
    let model: DrawingCheckModel
    let summariseModel: DrawingSummariseModel
    /// Exports the Markdown report (the host owns the save panel / share sheet).
    let onExport: () -> Void

    @Environment(AIProviderStore.self) private var providerStore: AIProviderStore?
    @State private var reportExpanded = false
    @State private var compareModel = DrawingCompareModel()
    @State private var showingCompare = false
    @State private var pickingBaselineFile = false
    @State private var cleanupModel = DrawingCleanupModel()
    @State private var showingCleanup = false
    @State private var aiEditModel = DrawingAIEditModel()
    @State private var showingAIEdit = false
    @State private var recolourModel = DrawingRecolourModel()
    @State private var showingRecolour = false
    @State private var translateModel = DrawingAITranslateModel()
    @State private var showingTranslate = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.isAnalysing && model.analysis == nil {
                    analysing
                } else if let report = model.report {
                    summarySection
                    actionsRow
                    reportDisclosure(report)
                    findingsSection
                } else {
                    unavailable
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $model.pendingFix) { fix in
            FixPreviewSheet(
                fix: fix,
                onApply: { Task { await model.confirmPendingFix() } },
                onCancel: { model.cancelPendingFix() })
        }
        .onAppear { summariseModel.providerStore = providerStore }
        .sheet(isPresented: $showingCompare) {
            DrawingCompareView(model: compareModel, onClose: { showingCompare = false })
        }
        .fileImporter(isPresented: $pickingBaselineFile, allowedContentTypes: MetafileTypes.readableContentTypes) { result in
            if case .success(let url) = result { loadBaseline(from: url) }
        }
        .sheet(isPresented: $showingCleanup) {
            DrawingCleanupView(model: cleanupModel, fileName: model.documentFileName, onClose: { showingCleanup = false })
        }
        .sheet(isPresented: $showingAIEdit) {
            DrawingAIEditView(model: aiEditModel, onClose: { showingAIEdit = false })
                .environment(providerStore)
        }
        .sheet(isPresented: $showingRecolour) {
            DrawingRecolourView(model: recolourModel, onClose: { showingRecolour = false })
        }
        .sheet(isPresented: $showingTranslate) {
            DrawingAITranslateView(model: translateModel, onClose: { showingTranslate = false })
                .environment(providerStore)
        }
        .aiConsentSheet(
            provider: summariseModel.pendingConsent,
            purpose: .drawingData,
            store: providerStore,
            onAllow: { summariseModel.consentAllowed() },
            onDeny: { summariseModel.consentDeclined() })
    }

    // MARK: States

    private var analysing: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking the drawing…").foregroundStyle(.secondary)
        }
    }

    private var unavailable: some View {
        Label("This drawing couldn’t be checked.", systemImage: "questionmark.circle")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

    private var actionsRow: some View {
        // Fit the inspector width without hyphenating a label: try full labels, then fall
        // back to icon-only buttons on a narrow (iPad) inspector.
        ViewThatFits(in: .horizontal) {
            actionButtons(compact: false)
            actionButtons(compact: true)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionButtons(compact: Bool) -> some View {
        HStack(spacing: 10) {
            if summariseModel.hasEngine, model.summaryData != nil {
                summariseButton(compact: compact)
            }
            if summariseModel.hasEngine {
                Button { startAIEdit() } label: {
                    actionLabel("Edit with AI…", "wand.and.stars.inverse", compact: compact)
                }
                .accessibilityIdentifier("editWithAI")
                Button { startTranslate() } label: {
                    actionLabel("Translate…", "character.bubble", compact: compact)
                }
                .accessibilityIdentifier("translateDrawing")
            }
            Button { startRecolour() } label: {
                actionLabel("Recolour…", "paintpalette", compact: compact)
            }
            .accessibilityIdentifier("recolourDrawing")
            Button(action: onExport) {
                actionLabel("Export Report…", "square.and.arrow.up", compact: compact)
            }
            .accessibilityIdentifier("exportCheckReport")
            compareButton(compact: compact)
            Button { startCleanup() } label: {
                actionLabel("Clean Up…", "wand.and.stars", compact: compact)
            }
            .accessibilityIdentifier("cleanUpDrawing")
        }
    }

    private func startAIEdit() {
        guard let session = model.editSession else { return }
        aiEditModel.configure(session: session)
        aiEditModel.providerStore = providerStore
        aiEditModel.reset()
        showingAIEdit = true
    }

    private func startRecolour() {
        guard let session = model.editSession else { return }
        showingRecolour = true
        Task { await recolourModel.start(session: session, selection: []) }
    }

    private func startTranslate() {
        guard let session = model.editSession else { return }
        translateModel.providerStore = providerStore
        showingTranslate = true
        Task { await translateModel.prepare(session: session, selection: []) }
    }

    private func startCleanup() {
        showingCleanup = true
        let dirty = model.hasUnsavedChanges
        Task {
            guard let data = await model.cleanupData() else { return }
            cleanupModel.analyse(data: data, hasUnsavedChanges: dirty)
        }
    }

    @ViewBuilder
    private func compareButton(compact: Bool) -> some View {
        if model.canCompareWithOpenedVersion {
            Menu {
                Button("Compare with Opened Version") { compareWithOpenedVersion() }
                Button("Compare with File…") { pickingBaselineFile = true }
            } label: {
                actionLabel("Compare…", "rectangle.on.rectangle", compact: compact)
            }
            .menuIndicator(.hidden)
            .accessibilityIdentifier("compareDrawing")
        } else {
            Button { pickingBaselineFile = true } label: {
                actionLabel("Compare…", "rectangle.on.rectangle", compact: compact)
            }
            .accessibilityIdentifier("compareDrawing")
        }
    }

    // MARK: Compare actions (X1b item 1)

    private func compareWithOpenedVersion() {
        guard let data = model.openedVersionBaselineData() else { return }
        startCompare(baselineData: data, label: "Opened version")
    }

    private func loadBaseline(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        startCompare(baselineData: data, label: url.lastPathComponent)
    }

    private func startCompare(baselineData: Data, label: String) {
        showingCompare = true
        Task {
            guard let current = await model.currentSceneForCompare(),
                  let baseline = try? SceneImporter.import(data: baselineData) else { return }
            compareModel.compare(current: current, baseline: baseline, baselineLabel: label)
        }
    }

    private func summariseButton(compact: Bool) -> some View {
        Group {
            switch summariseModel.phase {
            case .streaming:
                Button(role: .cancel) { summariseModel.cancel() } label: {
                    actionLabel("Stop", "stop.circle", compact: compact)
                }
            default:
                Button {
                    guard let data = model.summaryData else { return }
                    summariseModel.resetIfChanged(key: model.analysisVersion)
                    summariseModel.summarise(key: model.analysisVersion, data: data)
                } label: {
                    actionLabel("Summarise", "sparkles", compact: compact)
                }
                .accessibilityIdentifier("summariseCheck")
            }
        }
    }

    /// A button label that never hyphenates: a single-line icon+text when it fits, else
    /// an icon-only control that keeps the text as its accessibility label.
    @ViewBuilder
    private func actionLabel(_ title: String, _ icon: String, compact: Bool) -> some View {
        if compact {
            Image(systemName: icon)
                .accessibilityLabel(title)
        } else {
            Label(title, systemImage: icon)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        switch summariseModel.phase {
        case .idle:
            EmptyView()
        case .streaming, .done:
            if !summariseModel.text.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summariseModel.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if summariseModel.phase == .streaming {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Summarising…").foregroundStyle(.secondary)
                        }
                    } else if !summariseModel.engineLabel.isEmpty {
                        Text(summariseModel.engineLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Content report

    private func reportDisclosure(_ report: ContentReport) -> some View {
        DisclosureGroup(isExpanded: $reportExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                pageBlock(report)
                if !report.fonts.isEmpty { fontsBlock(report) }
                if !report.colors.isEmpty { coloursBlock(report) }
                if !report.images.isEmpty { imagesBlock(report) }
                if !report.textRuns.isEmpty { textBlock(report) }
                if !report.unsupported.isEmpty { unsupportedBlock(report) }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Content report", systemImage: "doc.text.magnifyingglass")
                .font(.callout.weight(.medium))
        }
    }

    private func blockHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func pageBlock(_ report: ContentReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            blockHeader("Page")
            Text(String(format: "%.0f × %.0f px", report.pageSizeDevice.width, report.pageSizeDevice.height))
                .font(.callout)
            if let mm = report.physicalSizeMM {
                Text(String(format: "%.1f × %.1f mm", mm.width, mm.height))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(report.elementCount) element\(report.elementCount == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            if !report.kindCounts.isEmpty {
                Text(report.kindCounts.map { "\(kindName($0.kind)) \($0.count)" }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fontsBlock(_ report: ContentReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            blockHeader("Fonts")
            ForEach(Array(report.fonts.enumerated()), id: \.offset) { _, font in
                let sizes = font.pointSizes.isEmpty ? "" : " — " + font.pointSizes.map { String(format: "%g pt", $0) }.joined(separator: ", ")
                Text("\(font.family) (\(font.runCount) run\(font.runCount == 1 ? "" : "s"))\(sizes)")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func coloursBlock(_ report: ContentReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            blockHeader("Colours")
            ForEach(Array(report.colors.enumerated()), id: \.offset) { _, usage in
                HStack(spacing: 8) {
                    swatch(usage.color)
                    Text(usage.color.hexString)
                        .font(.callout.monospaced())
                    Text(roleName(usage.role))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text("×\(usage.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func imagesBlock(_ report: ContentReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            blockHeader("Images")
            ForEach(Array(report.images.enumerated()), id: \.offset) { _, image in
                Text("\(image.pixelWidth)×\(image.pixelHeight) \(image.format) ×\(image.count)")
                    .font(.callout)
            }
        }
    }

    private func textBlock(_ report: ContentReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            blockHeader("Text")
            ForEach(Array(report.textRuns.enumerated()), id: \.offset) { _, run in
                let size = run.pointSize.map { String(format: " (%.1f pt)", $0) } ?? ""
                Text("“\(run.string)”\(size)")
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
    }

    private func unsupportedBlock(_ report: ContentReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            blockHeader("Unsupported records")
            ForEach(Array(report.unsupported.enumerated()), id: \.offset) { _, group in
                Text("\(group.label) ×\(group.count)")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func swatch(_ color: SceneColor) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))
            .frame(width: 16, height: 16)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.4), lineWidth: 0.5))
    }

    // MARK: Findings

    @ViewBuilder
    private var findingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Findings")
                .font(.callout.weight(.medium))
            if model.findings.isEmpty {
                Label("No accessibility or legibility issues found.", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(groupedFindings, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(group.title) (\(group.findings.count))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(group.findings) { finding in
                            findingRow(finding)
                        }
                    }
                }
            }
        }
    }

    private func findingRow(_ finding: Finding) -> some View {
        let selected = model.selectedFindingID == finding.id
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                model.select(findingID: selected ? nil : finding.id)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    severityIcon(finding.severity)
                    Text(DrawingAnalysis.describe(finding))
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if selected {
                fixControls(finding)
                    .padding(.leading, 24)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.10) : Color.clear)
        )
    }

    @ViewBuilder
    private func fixControls(_ finding: Finding) -> some View {
        let count = model.fixAllCount(for: finding.id)
        if model.plannedFix(for: finding.id) != nil {
            HStack(spacing: 10) {
                Button {
                    model.beginFix(findingID: finding.id)
                } label: {
                    if model.isPreparingFix {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Fix…") }
                    } else {
                        Label("Fix…", systemImage: "wand.and.stars")
                    }
                }
                .accessibilityIdentifier("fixFinding")
                if count > 1 {
                    Button("Fix all of this kind (\(count))") {
                        model.beginFixAll(findingID: finding.id)
                    }
                    .accessibilityIdentifier("fixAllFinding")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isPreparingFix)
        } else {
            Text("No automatic fix — review this one by hand.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func severityIcon(_ severity: FindingSeverity) -> some View {
        let (name, tint): (String, Color) = {
            switch severity {
            case .high: return ("exclamationmark.octagon.fill", .red)
            case .medium: return ("exclamationmark.triangle.fill", .orange)
            case .low: return ("info.circle.fill", .secondary)
            }
        }()
        return Image(systemName: name)
            .foregroundStyle(tint)
            .accessibilityLabel(DrawingAnalysis.severityLabel(severity))
    }

    // MARK: Grouping + names

    private struct FindingGroup { var title: String; var findings: [Finding] }

    private var groupedFindings: [FindingGroup] {
        let order: [(Int, String)] = [(0, "Low contrast"), (1, "Tiny text"), (2, "Colour-only distinction"), (3, "Unlabelled images")]
        func rank(_ finding: Finding) -> Int {
            switch finding.kind {
            case .lowContrast: return 0
            case .tinyText: return 1
            case .colorPair: return 2
            case .unlabelledImage: return 3
            }
        }
        return order.compactMap { (key, title) in
            let group = model.findings.filter { rank($0) == key }
            return group.isEmpty ? nil : FindingGroup(title: title, findings: group)
        }
    }

    private func kindName(_ kind: ElementKind) -> String {
        switch kind {
        case .path: return "path"
        case .rect: return "rect"
        case .ellipse: return "ellipse"
        case .roundRect: return "round-rect"
        case .polygon: return "polygon"
        case .polyline: return "polyline"
        case .line: return "line"
        case .arc: return "arc"
        case .bezier: return "bezier"
        case .text: return "text"
        case .image: return "image"
        case .group: return "group"
        case .passthrough: return "passthrough"
        }
    }

    private func roleName(_ role: ColorRole) -> String {
        switch role {
        case .fill: return "fill"
        case .stroke: return "stroke"
        case .text: return "text"
        }
    }
}

// MARK: - Fix preview sheet

/// The before/after preview for a single fix, or the count confirm for "fix all". Apply
/// routes through the model (which applies through `DocumentSession` as one undo); Cancel
/// dismisses with nothing changed.
struct FixPreviewSheet: View {
    let fix: DrawingCheckModel.PendingFix
    let onApply: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            header
            content
            buttons
        }
        .padding(22)
        #if os(macOS)
        .frame(width: 460)
        #endif
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "wand.and.stars")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(actionTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch fix.content {
        case .single(let before, let after, _):
            HStack(spacing: 16) {
                cropColumn("Before", image: before)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                cropColumn("After", image: after)
            }
        case .all(let count, _):
            Text("This applies the same fix to \(count) finding\(count == 1 ? "" : "s") of this kind, as one undoable step.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
        }
    }

    private func cropColumn(_ title: String, image: CGImage) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 170, maxHeight: 170)
                .background(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var buttons: some View {
        HStack {
            Button("Cancel") { onCancel(); dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Apply") { onApply(); dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }

    private var actionTitle: String {
        switch fix.content {
        case .single(_, _, let title): return title
        case .all(_, let title): return title
        }
    }
}
