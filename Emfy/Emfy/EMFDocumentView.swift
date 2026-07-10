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
            .background(Color(white: 0.9))
            .overlay(alignment: .top) {
                if document.plusPresence == .drawingContent {
                    plusNotice
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
            Image(image, scale: 1, label: Text("EMF image"))
                .resizable()
                .interpolation(.high)
                .frame(width: naturalSize.width * zoom, height: naturalSize.height * zoom)
                .shadow(radius: 2)
        } else {
            Text("This file could not be rendered.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - EMF+ notice

    private var plusNotice: some View {
        Text("Contains EMF+ content — showing partial rendering (GDI fallback).")
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
        guard let data = EMFExport.pdfData(from: document.file) else {
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

    private var parserDiagnostics: [EMFDiagnostic] { document.file.diagnostics }
    private var renderLog: [EMFRenderLog.Entry] { document.renderLog }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("These notes describe anything Emfy skipped, approximated, or recovered from while opening this file. The image remains the best available rendering.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if parserDiagnostics.isEmpty && renderLog.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("No diagnostics", systemImage: "checkmark.circle")
                                .font(.headline)
                                .foregroundStyle(.green)
                            Text("Emfy parsed and rendered this document without notes.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        if !parserDiagnostics.isEmpty {
                            diagnosticsSection(
                                title: "Parser diagnostics (\(parserDiagnostics.count))",
                                systemImage: "doc.text.magnifyingglass",
                                messages: parserDiagnostics.map(\.userMessage)
                            )
                        }

                        if !renderLog.isEmpty {
                            diagnosticsSection(
                                title: "Render notes (\(renderLog.count))",
                                systemImage: "paintbrush.pointed",
                                messages: renderLog.map(\.userMessage)
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
        messages: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            ForEach(Array(messages.enumerated()), id: \.offset) { item in
                Label(item.element, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension EMFDiagnostic {
    var userMessage: String {
        switch self {
        case .sizeTooSmall(let offset, let size):
            return "Record at byte \(offset) has an invalid size (\(size)); parsing stopped there."
        case .sizeNotAligned(let offset, let size):
            return "Record at byte \(offset) has a size of \(size), which is not four-byte aligned; parsing stopped there."
        case .sizeExceedsRemaining(let offset, let size, let remaining):
            return "Record at byte \(offset) claims \(size) bytes, but only \(remaining) remain; parsing stopped there."
        case .truncatedRecordHeader(let offset, let remaining):
            return "Only \(remaining) bytes remain at byte \(offset), which is too short for a record header; parsing stopped there."
        case .missingEOF:
            return "The file ended without an EMR_EOF record."
        case .trailingBytesAfterEOF(let count):
            return "The file contains \(count) trailing bytes after its EMR_EOF record."
        case .recordCountMismatch(let headerSays, let walked):
            return "The header claims \(headerSays) records, but Emfy found \(walked); the walked count was used."
        case .byteCountMismatch(let headerSays, let walked):
            return "The header claims \(headerSays) bytes, but Emfy walked \(walked); the walked count was used."
        case .recordCountCapped(let limit):
            return "The \(limit)-record safety limit was reached; later records were skipped."
        }
    }
}

private extension EMFRenderLog.Entry {
    var userMessage: String {
        switch self {
        case .unimplementedRecord(let type, let count):
            return "Skipped unsupported EMF record type \(type) (\(count) occurrence\(count == 1 ? "" : "s"))."
        case .malformedRecord(let type):
            return "Skipped malformed EMF record type \(type)."
        case .unsupportedROP2(let rawMode, let count):
            return "Used normal copy drawing for unsupported ROP2 mode \(rawMode) (\(count) occurrence\(count == 1 ? "" : "s"))."
        case .unsupportedBrushStyle(let rawStyle):
            return "Used a solid fallback for unsupported brush style \(rawStyle)."
        case .unsupportedPenStyle(let rawStyle):
            return "Used a solid fallback for unsupported pen style \(rawStyle)."
        case .zeroExtentMapping:
            return "Kept the current mapping because the file contains a zero-sized extent."
        case .unsupportedClipMode(let record, let rawMode):
            return "Skipped unsupported clipping mode \(rawMode) in record type \(record)."
        case .noCurrentPath(let record):
            return "Skipped record type \(record) because it had no current path."
        case .nestedBeginPath:
            return "Started a new path after a nested path begin; the unfinished path was discarded."
        case .unknownEnumValue(let record, let rawValue):
            return "Ignored unknown value \(rawValue) in record type \(record)."
        case .malformedBezier(let pointCount):
            return "Rendered the valid part of a Bezier record with an invalid \(pointCount)-point count."
        case .invalidObjectIndex(let index):
            return "Ignored unavailable graphics object index \(index)."
        case .objectTableFull(let index):
            return "Ignored graphics object index \(index) because the object table is full."
        case .unsupportedStockObject(let rawValue):
            return "Ignored unsupported stock graphics object \(rawValue)."
        case .restoreDCUnbalanced(let savedDC):
            return "Could not restore graphics state \(savedDC) because no matching saved state exists."
        case .saveDCStackOverflow:
            return "Skipped a graphics-state save because the safety limit was reached."
        case .unsupportedWorldTransformMode(let rawMode):
            return "Ignored unsupported world-transform mode \(rawMode)."
        case .canvasClamped(let requestedWidth, let requestedHeight, let renderedWidth, let renderedHeight):
            return "Rendered at \(renderedWidth) × \(renderedHeight) instead of \(requestedWidth) × \(requestedHeight) to stay within the image safety limit."
        case .fontSubstituted(let requested, let used, let count):
            return "Used \(used) instead of unavailable font \(requested) (\(count) occurrence\(count == 1 ? "" : "s"))."
        case .stockFontUsed(let rawValue, let count):
            return "Used a system fallback for stock font \(rawValue) (\(count) occurrence\(count == 1 ? "" : "s"))."
        case .glyphIndexTextSkipped(let count):
            return "Skipped \(count) glyph-index text run\(count == 1 ? "" : "s") that could not be mapped to a macOS font."
        case .unsupportedDIB(let reason, let count):
            return "Skipped unsupported embedded bitmap\(reason.map { ": \($0.userMessage)" } ?? "") (\(count) occurrence\(count == 1 ? "" : "s"))."
        case .unsupportedRasterOp(let rasterOperation, let count):
            return "Used a best-effort fallback for raster operation \(rasterOperation) (\(count) occurrence\(count == 1 ? "" : "s"))."
        case .xformSrcIgnored(let count):
            return "Ignored a source bitmap transform (\(count) occurrence\(count == 1 ? "" : "s"))."
        }
    }
}

private extension DIBUnsupportedReason {
    var userMessage: String {
        switch self {
        case .compression(let compression):
            return "compression \(compression.userMessage)"
        case .bitCount(let bitCount):
            return "\(bitCount)-bit color depth"
        case .paletteUsage(let paletteUsage):
            return "palette usage \(paletteUsage)"
        }
    }
}

private extension BitmapCompression {
    var userMessage: String {
        switch self {
        case .rgb:
            return "BI_RGB"
        case .rle8:
            return "RLE8"
        case .rle4:
            return "RLE4"
        case .bitfields:
            return "bitfields"
        case .jpeg:
            return "JPEG"
        case .png:
            return "PNG"
        case .other(let rawValue):
            return "unknown format \(rawValue)"
        }
    }
}
