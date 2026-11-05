import CoreGraphics
import EMFParse
import EMFRender
import SwiftUI
import UniformTypeIdentifiers

/// The document window: a scrollable, zoomable view of the pre-rendered EMF
/// image, a zoom/fit toolbar, and PNG/PDF export. All rendering already
/// happened in `EMFDocument`; this view only presents and scales the result.
struct EMFDocumentView: View {
    let document: EMFDocument

    /// Zoom factor where 1.0 == 100% (one EMF device pixel per point).
    @State private var zoom: CGFloat = 1
    /// Set true once, on first appearance, to fit-on-open.
    @State private var didInitialFit = false
    /// The live visible size of the scroll viewport, tracked from the
    /// GeometryReader so the manual Fit button uses the real window size.
    @State private var viewportSize: CGSize = .zero

    // Export sheet state.
    @State private var exportingPNG = false
    @State private var exportingPDF = false
    @State private var pngDocument = PNGExportDocument(data: Data())
    @State private var pdfDocument = PDFExportDocument(data: Data())
    /// Set from a `.fileExporter` failure so the error surfaces in an alert
    /// instead of the export silently doing nothing.
    @State private var exportError: String?
    /// Shows the parse and render notes retained by `EMFDocument`.
    @State private var showingDiagnostics = false

    /// Zoom bounds and step. GDI pictures can be tiny or huge; keep a generous
    /// but finite range so the scaled frame never overflows layout.
    private static let minZoom: CGFloat = 0.02
    private static let maxZoom: CGFloat = 64
    private static let zoomStep: CGFloat = 1.25

    /// The natural (100%) point size of the picture: the rendered bitmap in
    /// pixels divided by the scale it was rendered at.
    private var naturalSize: CGSize {
        guard let image = document.image, image.width > 0, image.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        return CGSize(
            width: CGFloat(image.width) / EMFDocument.renderScale,
            height: CGFloat(image.height) / EMFDocument.renderScale
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                content
                    .frame(
                        width: max(naturalSize.width * zoom, geometry.size.width),
                        height: max(naturalSize.height * zoom, geometry.size.height)
                    )
            }
            // App Store dark-mode fix: the canvas around the page follows the
            // system appearance, while the page itself stays white (the
            // renderer fills the EMF bitmap with white paper).
            .background(Color(nsColor: .underPageBackgroundColor))
            .overlay(alignment: .top) {
                if let message = partialSupportMessage {
                    partialNotice(message)
                }
            }
            .onAppear {
                viewportSize = geometry.size
                // Only spend the one-shot fit once we have a real viewport;
                // at .zero (window-restore timing) fitZoom returns 1, which
                // would leave the document stuck at 100%.
                if !didInitialFit, geometry.size.width > 0, geometry.size.height > 0 {
                    didInitialFit = true
                    zoom = fitZoom(in: geometry.size)
                }
            }
            .onChange(of: geometry.size) { _, newSize in
                viewportSize = newSize
                // If onAppear ran at .zero, complete the one-shot fit as soon
                // as a real size arrives — still exactly once.
                if !didInitialFit, newSize.width > 0, newSize.height > 0 {
                    didInitialFit = true
                    zoom = fitZoom(in: newSize)
                }
            }
        }
        .toolbar { toolbarContent }
        .fileExporter(
            isPresented: $exportingPNG,
            document: pngDocument,
            contentType: .png,
            defaultFilename: "Untitled"
        ) { result in
            if case .failure(let error) = result {
                exportError = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $exportingPDF,
            document: pdfDocument,
            contentType: .pdf,
            defaultFilename: "Untitled"
        ) { result in
            if case .failure(let error) = result {
                exportError = error.localizedDescription
            }
        }
        .alert(
            "Export Failed",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            ),
            presenting: exportError
        ) { _ in
            Button("OK", role: .cancel) { exportError = nil }
        } message: { message in
            Text(message)
        }
        .sheet(isPresented: $showingDiagnostics) {
            DocumentDiagnosticsView(document: document)
        }
    }

    // MARK: - Picture

    @ViewBuilder
    private var content: some View {
        if let image = document.image {
            Image(image, scale: 1, label: Text("Metafile image"))
                .resizable()
                .interpolation(.high)
                .frame(width: naturalSize.width * zoom, height: naturalSize.height * zoom)
                .shadow(radius: 2)
        } else {
            Text("This file could not be rendered.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Partial-support notice

    /// The partial-support banner text, or `nil` when nothing needs flagging.
    /// The signal depends on how the file was rendered:
    /// - A decoded EMF (a standalone `.emf`, or a WMF's played-back embedded
    ///   EMF) flags only unsupported EMF+ content — EMF GDI records, when
    ///   skipped, are not nagged about, exactly as before.
    /// - WMF record playback flags any render-log note at all (a skipped or
    ///   approximated record), because the WMF path is newer and the detail is
    ///   in Render Details.
    private var partialSupportMessage: String? {
        switch document.prepared.kind {
        case .emf:
            return hasUnsupportedEMFPlusContent
                ? "Some EMF+ content in this file isn't supported or couldn't be read — see Render Details."
                : nil
        case .wmfRecords:
            return document.renderLog.isEmpty
                ? nil
                : "Some content in this file isn't fully supported — see Render Details."
        }
    }

    /// True when the render log shows EMF+ content that was NOT rendered: an
    /// unsupported record type, a stream that couldn't be fully read, a drawing
    /// record whose body was undecodable, or an unresolved/invalid object
    /// reference (audit M7). EMF+ geometry, gradients, images, and text all
    /// render now, so this is the honest signal that some content is missing or
    /// broken. Approximated EMF+ features (still drawn) are surfaced in Render
    /// Details, not here.
    private var hasUnsupportedEMFPlusContent: Bool {
        document.renderLog.contains { entry in
            switch entry {
            case .emfPlusUnsupportedRecord, .emfPlusStreamIssue, .emfPlusRecordUndecodable, .emfPlusObjectIssue:
                return true
            default:
                return false
            }
        }
    }

    private func partialNotice(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.thinMaterial)
            .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                setZoom(zoom / Self.zoomStep)
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)
            .help("Zoom Out")

            Text(zoomPercentText)
                .font(.system(.body, design: .rounded).monospacedDigit())
                .frame(minWidth: 48)

            Button {
                setZoom(zoom * Self.zoomStep)
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .keyboardShortcut("+", modifiers: .command)
            .help("Zoom In")

            Button("Fit") {
                zoom = fitZoom(in: viewportSize)
            }
            .help("Fit to Window")

            Button("100%") {
                setZoom(1)
            }
            .keyboardShortcut("0", modifiers: .command)
            .help("Actual Size")

            Button {
                showingDiagnostics = true
            } label: {
                Label("Render Details", systemImage: "text.bubble")
            }
            .help("Show parser diagnostics and render notes")

            Menu {
                Button("Export as PNG…", action: exportPNG)
                    .disabled(document.image == nil)
                Button("Export as PDF…", action: exportPDF)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export")
        }
    }

    private var zoomPercentText: String {
        "\(Int((zoom * 100).rounded()))%"
    }

    // MARK: - Zoom helpers

    /// Clamps and applies a new zoom factor.
    private func setZoom(_ value: CGFloat) {
        zoom = min(max(value, Self.minZoom), Self.maxZoom)
    }

    /// The zoom that fits `naturalSize` inside `viewport` (with a small margin),
    /// never magnifying past 100%.
    private func fitZoom(in viewport: CGSize) -> CGFloat {
        let size = naturalSize
        guard size.width > 0, size.height > 0,
              viewport.width > 0, viewport.height > 0
        else { return 1 }
        let margin: CGFloat = 32
        let availableWidth = max(viewport.width - margin, 1)
        let availableHeight = max(viewport.height - margin, 1)
        let fit = min(availableWidth / size.width, availableHeight / size.height)
        return min(max(fit, Self.minZoom), 1)
    }

    // MARK: - Export actions

    private func exportPNG() {
        guard let image = document.image else {
            exportError = "This document has no rendered image to export as PNG."
            return
        }
        guard let data = EMFExport.pngData(from: image) else {
            exportError = "Emfy could not encode a PNG for this document."
            return
        }
        pngDocument = PNGExportDocument(data: data)
        exportingPNG = true
    }

    private func exportPDF() {
        guard let data = MetafileRenderer.pdfData(document.prepared) else {
            exportError = "Emfy could not generate a PDF for this document."
            return
        }
        pdfDocument = PDFExportDocument(data: data)
        exportingPDF = true
    }
}

/// User-facing parser and renderer notes for the open document. Keeping this
/// presentation in the app lets EMFKit remain framework-neutral and reusable
/// by both Quick Look extensions.
private struct DocumentDiagnosticsView: View {
    let document: EMFDocument

    @Environment(\.dismiss) private var dismiss

    /// The shared plain-language diagnostics (C2). Render Details shows every
    /// note (unfiltered), each as a plain summary with the technical line under a
    /// "Technical details" disclosure.
    private var diagnostics: ViewerDiagnostics { document.viewerDiagnostics }
    private var fileNotes: [DiagnosticNote] { diagnostics.fileNotes }
    private var parserNotes: [DiagnosticNote] { diagnostics.allParserNotes }
    private var renderNotes: [DiagnosticNote] { diagnostics.allRenderNotes }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("These notes describe anything Emfy skipped, approximated, or recovered from while opening this file. The image remains the best available rendering.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if fileNotes.isEmpty && parserNotes.isEmpty && renderNotes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("No diagnostics", systemImage: "checkmark.circle")
                                .font(.headline)
                                .foregroundStyle(.green)
                            Text("Emfy parsed and rendered this document without notes.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        if !fileNotes.isEmpty {
                            diagnosticsSection(
                                title: "File notes (\(fileNotes.count))",
                                systemImage: "shippingbox",
                                notes: fileNotes
                            )
                        }

                        if !parserNotes.isEmpty {
                            diagnosticsSection(
                                title: "Parser diagnostics (\(parserNotes.count))",
                                systemImage: "doc.text.magnifyingglass",
                                notes: parserNotes
                            )
                        }

                        if !renderNotes.isEmpty {
                            diagnosticsSection(
                                title: "Render notes (\(renderNotes.count))",
                                systemImage: "paintbrush.pointed",
                                notes: renderNotes
                            )
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Render Details")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    @ViewBuilder
    private func diagnosticsSection(
        title: String,
        systemImage: String,
        notes: [DiagnosticNote]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            ForEach(notes) { note in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Technical details")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(note.technicalDetail)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 4)
                    .padding(.top, 2)
                } label: {
                    Label {
                        Text(note.summary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }
}
