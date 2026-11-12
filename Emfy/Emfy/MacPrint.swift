import AppKit
import CoreGraphics
import EMFEdit
import EMFRender
import Foundation

/// Mac printing (F1 design call 1). The drawing is printed as **vector** — the whole
/// drawing is rendered once to a single-page PDF through the SAME renderer the PDF
/// export uses (`MetafileRenderer.pdfData` for the original, `ScenePDF` for the edited
/// scene), and an `NSView` draws that PDF page into the printable area, fitted and
/// centred with aspect preserved. The page orientation is auto-chosen from the
/// drawing's aspect, and the standard print panel carries a "Scale: Fit to Page /
/// Actual Size" accessory.
@MainActor
enum MacPrint {
    /// Builds the vector PDF for the whole drawing (edited scene when editing has
    /// diverged, else the original prepared metafile), or `nil` when neither can be
    /// produced.
    static func makePDFData(
        source: OutputSource,
        prepared: MetafileRenderer.Prepared,
        editedScene: Scene?,
        options: RenderOptions
    ) -> Data? {
        switch source {
        case .editedScene:
            if let scene = editedScene { return ScenePDF.data(scene) }
            return MetafileRenderer.pdfData(prepared, options: options)
        case .original, .selectionSubset:
            // Print is never narrowed to a selection; a subset falls back to the whole.
            return MetafileRenderer.pdfData(prepared, options: options)
        }
    }

    /// Presents the standard print panel for `pdfData` (a single-page vector PDF),
    /// anchored to `window` when given. `naturalSize` drives the auto orientation and
    /// the fit maths; `jobName` is the print job title (the file name).
    static func present(pdfData: Data, naturalSize: CGSize, jobName: String, window: NSWindow?) {
        guard let provider = CGDataProvider(data: pdfData as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return }

        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.orientation = PrintLayout.orientation(for: naturalSize) == .landscape ? .landscape : .portrait
        // Draw the view 1:1 into the imageable area (no print-system scaling or
        // pagination), so the fit maths below alone position the drawing.
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true

        let printView = MacMetafilePrintView(page: page, naturalSize: naturalSize)
        printView.frame = CGRect(origin: .zero, size: info.imageablePageBounds.size)

        let operation = NSPrintOperation(view: printView, printInfo: info)
        operation.jobTitle = jobName
        operation.printPanel.options.insert([.showsPreview, .showsPaperSize, .showsOrientation, .showsScaling])
        operation.printPanel.addAccessoryController(PrintScaleAccessory(printView: printView))

        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    #if DEBUG
    /// Renders the print view for `pdfData` to a PNG at each scaling, for the F1 print
    /// screenshot when the system print panel itself cannot be captured. Returns the
    /// fit-to-page and actual-size page images on a US-Letter imageable area.
    static func debugRenderPNGs(pdfData: Data, naturalSize: CGSize) -> (fit: Data?, actual: Data?) {
        guard let provider = CGDataProvider(data: pdfData as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return (nil, nil) }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.orientation = PrintLayout.orientation(for: naturalSize) == .landscape ? .landscape : .portrait
        let size = info.imageablePageBounds.size
        func png(_ scaling: PrintLayout.Scaling) -> Data? {
            let view = MacMetafilePrintView(page: page, naturalSize: naturalSize)
            view.scaling = scaling
            view.frame = CGRect(origin: .zero, size: size)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            // White the paper so the capture reads as a printed page, not transparency.
            rep.pixelsWide > 0 ? () : ()
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: size)
            image.addRepresentation(rep)
            return rep.representation(using: .png, properties: [:])
        }
        return (png(.fitToPage), png(.actualSize))
    }
    #endif
}

/// The single-page print view: it draws a prepared vector PDF page into the printable
/// area, fitted and centred (`PrintLayout`). It never rasterises — the PDF page is
/// drawn straight into the print context, so the output stays vector.
final class MacMetafilePrintView: NSView {
    private let page: CGPDFPage
    private let naturalSize: CGSize
    /// Fit to page (default) or actual size; the accessory toggles it and the panel
    /// redraws the preview.
    var scaling: PrintLayout.Scaling = .fitToPage {
        didSet { needsDisplay = true }
    }

    init(page: CGPDFPage, naturalSize: CGSize) {
        self.page = page
        self.naturalSize = naturalSize
        super.init(frame: .zero)
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // One page, filling the whole view (which is sized to the imageable area), so the
    // fit maths alone position the drawing.
    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: 1)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect { bounds }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // A non-flipped NSView's context is bottom-left like a PDF page, so the page
        // draws upright with a plain translate+scale into the fitted target.
        let target = PrintLayout.drawRect(naturalSize: naturalSize, printable: bounds, scaling: scaling)
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: target.minX, y: target.minY)
        context.scaleBy(x: target.width / box.width, y: target.height / box.height)
        context.drawPDFPage(page)
        context.restoreGState()
    }
}

/// The print panel's "Scale" accessory (F1 design call 1): a Fit to Page / Actual Size
/// segmented control. Changing it updates the print view and refreshes the panel's
/// preview through `keyPathsForValuesAffectingPreview`.
final class PrintScaleAccessory: NSViewController, NSPrintPanelAccessorizing {
    private let printView: MacMetafilePrintView
    /// KVO-observed by the print panel (see `keyPathsForValuesAffectingPreview`): 0 =
    /// Fit to Page, 1 = Actual Size.
    @objc dynamic var scalingRaw: Int

    init(printView: MacMetafilePrintView) {
        self.printView = printView
        self.scalingRaw = printView.scaling == .fitToPage ? 0 : 1
        super.init(nibName: nil, bundle: nil)
        self.title = "Scale"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func loadView() {
        let label = NSTextField(labelWithString: "Scale:")
        let segmented = NSSegmentedControl(
            labels: ["Fit to Page", "Actual Size"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(changeScaling(_:)))
        segmented.selectedSegment = scalingRaw
        let stack = NSStackView(views: [label, segmented])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    @objc private func changeScaling(_ sender: NSSegmentedControl) {
        scalingRaw = sender.selectedSegment
        printView.scaling = scalingRaw == 0 ? .fitToPage : .actualSize
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> { ["scalingRaw"] }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [[.itemName: "Scale", .itemDescription: scalingRaw == 0 ? "Fit to Page" : "Actual Size"]]
    }
}
