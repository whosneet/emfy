import CoreGraphics
import EMFParse
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
