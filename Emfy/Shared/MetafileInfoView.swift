import EMFRender
import SwiftUI
import UniformTypeIdentifiers

/// The file-details content shown in the viewer's inspector (v3-plan §9.1, "Built-in
/// `.inspector`"). Ported from the iOS `FileInfoInspector` into one cross-platform
/// view: the Mac and iPad show it in Apple's `.inspector` column; the iPhone shows
/// it in a sheet (screenshot #6). The file name and when it was opened, a grouped
/// details list, a plain-language "What Emfy couldn't show" section with a Technical
/// details disclosure, and Export as PNG/PDF rows that save to disk.
///
/// Rendering for the export rows reuses the shared off-main `MetafileExport` path,
/// so the bytes are identical to the Mac's long-standing export.
struct MetafileInfoView: View {
    let entry: RecentEntry
    let prepared: MetafileRenderer.Prepared
    let diagnostics: ViewerDiagnostics
    /// The "What Emfy couldn't show" rows, computed once at load (P6).
    let couldNotShowNotes: [DiagnosticNote]
    let naturalSize: CGSize
    /// Reads the live zoom percentage. Called inside the Zoom row's own body so a
    /// zoom change invalidates only that leaf, not this whole Form (P1/P2). `nil`
    /// hides the Zoom row.
    let zoomProvider: (() -> Int)?
    /// Closes the inspector/sheet.
    let onClose: () -> Void
    /// When set, the export rows route here instead of presenting this view's own
    /// `fileExporter` (C3b scope 5). The Mac passes its hoisted exporter, so Export
    /// works with the inspector closed; iOS passes nothing and keeps its own path.
    var onExport: ((ExportFormat) -> Void)? = nil
    /// iOS/iPadOS only: steps the viewer zoom by this fraction (±0.25) from the Zoom
    /// row's − / + buttons (C4a A14, owner decision). `nil` on the Mac, which keeps
    /// the read-only row and its toolbar buttons.
    var onZoomStep: ((CGFloat) -> Void)? = nil
    /// The on-device Describe section's inputs + models (A1a). All non-nil only when
    /// on-device AI is available; nil hides the section entirely.
    var aiInputs: DrawingAIInspectorInputs? = nil
    var describeModel: DrawingDescribeModel? = nil
    var altTextStore: DrawingAltTextStore? = nil

    @Environment(ToastCenter.self) private var toast
    @Environment(EmfySettings.self) private var settings
    /// Moves VoiceOver focus to the header when the inspector opens (C4a A18).
    @AccessibilityFocusState private var headerFocused: Bool
    @State private var exportRunner = ExportTaskRunner()
    @State private var isRenderingExport = false
    @State private var isExportingPNG = false
    @State private var isExportingPDF = false
    @State private var pngDocument = PNGExportDocument(data: Data())
    @State private var pdfDocument = PDFExportDocument(data: Data())
    @State private var filesError: String?
    /// Streams the on-device "Explain what's missing" answer (A1b Part 3).
    @State private var explainModel = DrawingExplainModel()

    var body: some View {
        Form {
            Section {
                header
            }
            #if os(iOS)
            .listRowBackground(Color.clear)
            #endif

            Section {
                LabeledContent("Format", value: entry.fullFormatName)
                LabeledContent("Size", value: entry.sizeLabel)
                LabeledContent("Picture size", value: pictureSizeString)
                LabeledContent("Drawn from", value: drawnFrom)
                if let zoomProvider {
                    ZoomInfoRow(percent: zoomProvider, onZoomStep: onZoomStep)
                }
            }

            if !couldNotShowNotes.isEmpty {
                Section("What Emfy couldn't show") {
                    ForEach(couldNotShowNotes) { note in
                        noteRow(note)
                    }
                    // Explain what's missing (A1b Part 3) — only when on-device AI is on
                    // AND a VISUAL record was actually skipped (A1c): structural-only
                    // skips (HEADER/EOF/COMMENT) would otherwise offer to explain a
                    // non-existent loss on nearly every file. Grounded strictly in the
                    // named diagnostics list.
                    if aiInputs != nil, !explainableItems.isEmpty {
                        explainMissingRows
                    }
                }
            }

            Section {
                // The default export format leads (S1a-6 Export › Default export format).
                ForEach(ExportMenuOrder.formats(default: settings.defaultExportFormat), id: \.self) { format in
                    exportRow(format)
                }
                Button {
                    copyDiagnosticReport()
                } label: {
                    Label("Copy Diagnostic Report", systemImage: "doc.on.clipboard")
                }
                .accessibilityIdentifier("copyDiagnosticReport")
            }

            // AI title and tags for this drawing (A1b), gated by the AI toggle/Private
            // mode; absent when none have been generated.
            DrawingAITagsSection(entry: entry)

            // Describe this drawing (A1a) — only when on-device AI is available.
            if let aiInputs, let describeModel, let altTextStore {
                DrawingDescribeSection(model: describeModel, altTextStore: altTextStore, inputs: aiInputs)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        // A new drawing clears any stale "what's missing" explanation (A1b Part 3).
        .onChange(of: aiInputs?.contentID) { _, id in
            explainModel.resetIfChanged(key: id ?? 0)
        }
        .fileExporter(
            isPresented: $isExportingPNG,
            document: pngDocument,
            contentType: .png,
            defaultFilename: entry.baseName
        ) { result in
            handleExportResult(result, format: "PNG")
        }
        .fileExporter(
            isPresented: $isExportingPDF,
            document: pdfDocument,
            contentType: .pdf,
            defaultFilename: entry.baseName
        ) { result in
            handleExportResult(result, format: "PDF")
        }
        .alert(
            "Export Failed",
            isPresented: Binding(get: { filesError != nil }, set: { if !$0 { filesError = nil } }),
            presenting: filesError
        ) { _ in
            Button("OK", role: .cancel) { filesError = nil }
        } message: { message in
            Text(message)
        }
        .overlay {
            if isRenderingExport {
                // Inside the inspector (an iPhone sheet / an iPad column): keep the
                // card material, not glass over the sheet's own glass (G1).
                ExportProgressOverlay(prefersGlass: false) {
                    exportRunner.cancel()
                    isRenderingExport = false
                }
            }
        }
        .onDisappear { exportRunner.cancel() }
        // Move VoiceOver to the header when the inspector/sheet opens (A18).
        .onAppear { headerFocused = true }
    }

    /// Ignores a user cancel (C4a M2); confirms a save with a toast (C4a M3); surfaces
    /// a real failure.
    private func handleExportResult(_ result: Result<URL, Error>, format: String) {
        switch result {
        case .success:
            toast.show("Exported as \(format)", systemImage: "square.and.arrow.down")
        case .failure(let error):
            if (error as? CocoaError)?.code == .userCancelled { return }
            filesError = error.localizedDescription
        }
    }

    /// The named, visual "what's missing" items the on-device Explain speaks to
    /// (A1c). Empty when only structural records (HEADER/EOF/COMMENT) were skipped, so
    /// the Explain button then hides rather than explaining a non-existent loss.
    private var explainableItems: [String] {
        DrawingMissingItems.list(from: diagnostics)
    }

    /// The "Explain what's missing" button and its streamed answer (A1b Part 3).
    @ViewBuilder
    private var explainMissingRows: some View {
        switch explainModel.phase {
        case .idle:
            explainButton(title: "Explain what's missing")
        case .streaming, .done:
            if !explainModel.text.isEmpty {
                Text(explainModel.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if explainModel.phase == .streaming {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Explaining…").foregroundStyle(.secondary)
                }
            } else {
                explainButton(title: "Explain again")
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            explainButton(title: "Try again")
        }
    }

    private func explainButton(title: String) -> some View {
        Button {
            explainModel.resetIfChanged(key: aiInputs?.contentID ?? 0)
            explainModel.explain(
                key: aiInputs?.contentID ?? 0,
                items: explainableItems)
        } label: {
            Label(title, systemImage: "sparkles")
        }
        .accessibilityIdentifier("explainWhatsMissing")
    }

    @ViewBuilder
    private func noteRow(_ note: DiagnosticNote) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                Text("Technical details")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(note.technicalDetail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.top, 2)
        } label: {
            Label {
                Text(note.summary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(openedLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($headerFocused)   // A18

            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close details")
        }
        .textCase(nil)
        .padding(.vertical, 2)
    }

    // MARK: - Export

    /// One "Export as PNG/PDF…" row, so the default export format can lead.
    @ViewBuilder
    private func exportRow(_ format: EmfySettings.ExportFormat) -> some View {
        switch format {
        case .png:
            Button { exportTapped(.png) } label: { Label("Export as PNG…", systemImage: "photo") }
        case .pdf:
            Button { exportTapped(.pdf) } label: { Label("Export as PDF…", systemImage: "doc.richtext") }
        }
    }

    /// Copies the current file's privacy-safe diagnostic report and confirms with a
    /// toast — the Info inspector's button (Mac) and the details sheet's (iOS).
    private func copyDiagnosticReport() {
        DiagnosticReportAction.copyFileReport(
            entry: entry,
            recordKinds: prepared.recordKinds,
            notes: couldNotShowNotes,
            toast: toast
        )
    }

    /// Routes to the hoisted exporter when one is provided (Mac), else this view's
    /// own `fileExporter` path (iOS, unchanged).
    private func exportTapped(_ format: ExportFormat) {
        if let onExport {
            onExport(format)
        } else {
            exportToFiles(format)
        }
    }

    private func exportToFiles(_ format: ExportFormat) {
        let prepared = self.prepared
        let opts = ExportScale.pngOptions(for: prepared.naturalSize, settings: settings)
        let options = settings.renderOptions
        exportRunner.run(
            setBusy: { busy in isRenderingExport = busy },
            render: { MetafileExport.data(for: format, prepared: prepared, scale: opts.scale, background: opts.background, options: options) },
            done: { data in
                guard let data else {
                    filesError = format.failureMessage
                    return
                }
                switch format {
                case .png:
                    pngDocument = PNGExportDocument(data: data)
                    isExportingPNG = true
                case .pdf:
                    pdfDocument = PDFExportDocument(data: data)
                    isExportingPDF = true
                }
            }
        )
    }

    // MARK: - Derived text

    private var pictureSizeString: String {
        "\(Int(naturalSize.width.rounded())) × \(Int(naturalSize.height.rounded()))"
    }

    /// Where the drawing was played from, reflecting the live Rendering options:
    /// the built-in EMF copy, the WMF records (noting when a copy was turned off),
    /// the GDI copy of a dual EMF+ file shown as GDI, or a plain EMF's records.
    private var drawnFrom: String {
        DrawnFrom.label(
            kind: diagnostics.kind,
            embeddedEMF: diagnostics.embeddedEMF,
            hasGDICopy: prepared.hasGDICopy,
            arbitration: settings.renderOptions.emfPlusArbitration
        )
    }

    private var openedLine: String {
        let when = entry.openedAt
        let time = when.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(when) {
            return "Opened today at \(time)"
        }
        let date = when.formatted(date: .abbreviated, time: .shortened)
        return "Opened \(date)"
    }
}

/// The inspector's Zoom row, as its own leaf view so the live percentage invalidates
/// only this row each zoom frame — not the whole Form or the pane/screen hosting the
/// inspector (P1/P2). `percent()` reads `controller.zoom`, and because that read
/// happens inside *this* view's body, Observation attributes the dependency here.
/// On iOS/iPadOS a single-pointer − / + stepper (25% steps) with the live % between
/// them (A14, WCAG 2.5.1); on the Mac a read-only value (it has toolbar zoom buttons).
private struct ZoomInfoRow: View {
    let percent: () -> Int
    let onZoomStep: ((CGFloat) -> Void)?

    var body: some View {
        let value = percent()
        if let onZoomStep {
            LabeledContent("Zoom") {
                HStack(spacing: 12) {
                    Button { onZoomStep(-0.25) } label: {
                        Image(systemName: "minus")
                    }
                    .accessibilityLabel("Zoom out")
                    Text("\(value)%")
                        .monospacedDigit()
                        .frame(minWidth: 52)
                        .accessibilityLabel("Zoom \(value) percent")
                    Button { onZoomStep(0.25) } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Zoom in")
                }
                .buttonStyle(.borderless)
                .font(.body)
            }
        } else {
            LabeledContent("Zoom", value: "\(value)%")
                .monospacedDigit()
        }
    }
}
