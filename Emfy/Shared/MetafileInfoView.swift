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
    let naturalSize: CGSize
    /// The live zoom percentage, shown only where there is room (regular width).
    let zoomPercent: Int?
    /// Closes the inspector/sheet.
    let onClose: () -> Void
    /// When set, the export rows route here instead of presenting this view's own
    /// `fileExporter` (C3b scope 5). The Mac passes its hoisted exporter, so Export
    /// works with the inspector closed; iOS passes nothing and keeps its own path.
    var onExport: ((ExportFormat) -> Void)? = nil

    @State private var exportRunner = ExportTaskRunner()
    @State private var isRenderingExport = false
    @State private var isExportingPNG = false
    @State private var isExportingPDF = false
    @State private var pngDocument = PNGExportDocument(data: Data())
    @State private var pdfDocument = PDFExportDocument(data: Data())
    @State private var filesError: String?

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
                LabeledContent("Size", value: sizeString)
                LabeledContent("Picture size", value: pictureSizeString)
                LabeledContent("Drawn from", value: drawnFrom)
                if let zoomPercent {
                    LabeledContent("Zoom", value: "\(zoomPercent)%")
                        .monospacedDigit()
                }
            }

            let notes = diagnostics.couldNotShowNotes
            if !notes.isEmpty {
                Section("What Emfy couldn't show") {
                    ForEach(notes) { note in
                        noteRow(note)
                    }
                }
            }

            Section {
                Button {
                    exportTapped(.png)
                } label: {
                    Label("Export as PNG…", systemImage: "photo")
                }
                Button {
                    exportTapped(.pdf)
                } label: {
                    Label("Export as PDF…", systemImage: "doc.richtext")
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .fileExporter(
            isPresented: $isExportingPNG,
            document: pngDocument,
            contentType: .png,
            defaultFilename: entry.baseName
        ) { result in
            if case .failure(let error) = result { filesError = error.localizedDescription }
        }
        .fileExporter(
            isPresented: $isExportingPDF,
            document: pdfDocument,
            contentType: .pdf,
            defaultFilename: entry.baseName
        ) { result in
            if case .failure(let error) = result { filesError = error.localizedDescription }
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
            if isRenderingExport { ExportSpinnerOverlay() }
        }
        .onDisappear { exportRunner.cancel() }
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
        exportRunner.run(
            setBusy: { busy in isRenderingExport = busy },
            render: { MetafileExport.data(for: format, prepared: prepared) },
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

    private var sizeString: String {
        ByteCountFormatter.string(fromByteCount: entry.byteCount, countStyle: .file)
    }

    private var pictureSizeString: String {
        "\(Int(naturalSize.width.rounded())) × \(Int(naturalSize.height.rounded()))"
    }

    /// "Built-in EMF copy" for a WMF that played its embedded EMF, "WMF records"
    /// for WMF record playback, "EMF records" for a plain EMF.
    private var drawnFrom: String {
        switch diagnostics.kind {
        case .emf:
            return diagnostics.embeddedEMF == .played ? "Built-in EMF copy" : "EMF records"
        case .wmfRecords:
            return "WMF records"
        }
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

/// A dimmed, tap-blocking overlay shown while an export renders. Cross-platform
/// (the iOS viewer's own `RenderingOverlay` stays UIKit-adjacent); VoiceOver reads
/// it as one "Preparing export" element.
struct ExportSpinnerOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Preparing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preparing export")
        .accessibilityAddTraits(.updatesFrequently)
    }
}
