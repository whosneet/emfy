import CoreGraphics
import EMFParse
import Foundation
import WMFParse

/// The open-any-metafile entry point: it takes an already-sniffed
/// `OpenedMetafile` (EMF, WMF, or placeable WMF; gzip is unwrapped upstream),
/// parses it once into a `Prepared` value, and renders that — dispatching to the
/// EMF renderer, the embedded-EMF path, or the WMF translation + playback.
///
/// This is the single door the app and the Quick Look extensions call. EMF
/// output is unchanged — an `.emf` input goes straight to the existing
/// `EMFRenderer` API, byte-for-byte as before.
public enum MetafileRenderer {

    // MARK: - Prepared metafile

    /// A metafile parsed once from an `OpenedMetafile` and ready to size, render,
    /// and export. Producing it is where the single parse happens: both the
    /// natural size and every render/export use the already-decoded result, so a
    /// Quick Look preview (size the context, then draw into it) parses the file
    /// exactly once.
    public struct Prepared: Sendable {
        /// What is actually rendered: a decoded EMF (a standalone `.emf`, or a
        /// WMF's embedded EMF when that supersedes the records), or a translated
        /// WMF program.
        enum Content: Sendable {
            case emf(EMFFile)
            case wmfProgram(WMFRenderProgram)
        }

        /// Which rendering path this metafile takes — the partial-support notice
        /// differs between an EMF (EMF+ notice) and WMF record playback.
        public enum Kind: Sendable, Equatable {
            /// A decoded EMF (standalone, or a WMF's played-back embedded EMF).
            case emf
            /// WMF records translated and played through the shared renderer.
            case wmfRecords
        }

        /// The fate of a WMF's embedded EMF ([MS-WMF] §2.3.6.25), for the
        /// front-door note.
        public enum EmbeddedEMF: Sendable, Equatable {
            /// The input was an EMF, so the question does not apply.
            case notApplicable
            /// A WMF with no embedded-EMF escape records.
            case absent
            /// A WMF whose embedded EMF reassembled and parsed; it is rendered
            /// instead of the WMF records.
            case played
            /// A WMF carried embedded-EMF escapes that could not be used (an
            /// inconsistent sequence, or an EMF that failed to parse), so the WMF
            /// records were played instead.
            case rejected
        }

        /// The metafile's natural size in device pixels: the EMF header bounds
        /// (inclusive-inclusive, so right−left+1 × bottom−top+1), or the WMF
        /// program's device canvas. Never smaller than 1×1.
        public let naturalSize: CGSize
        /// Which rendering path this metafile takes.
        public let kind: Kind
        /// The fate of a WMF's embedded EMF.
        public let embeddedEMF: EmbeddedEMF

        let content: Content

        /// The parser diagnostics of the decoded EMF — a standalone `.emf`, or a
        /// WMF's played-back embedded EMF. Empty for WMF record playback (that
        /// path's advisory walk diagnostics live on `WMFFile`, which the app does
        /// not surface).
        public var emfDiagnostics: [EMFDiagnostic] {
            if case .emf(let file) = content { return file.diagnostics }
            return []
        }

        init(content: Content, kind: Kind, embeddedEMF: EmbeddedEMF) {
            self.content = content
            self.kind = kind
            self.embeddedEMF = embeddedEMF
            self.naturalSize = Prepared.naturalSize(of: content)
        }

        /// EMF: the header bounds. WMF: the program canvas. Int64 keeps the
        /// inclusive-inclusive +1 from overflowing a full-range `rclBounds` (§8).
        private static func naturalSize(of content: Content) -> CGSize {
            switch content {
            case .emf(let file):
                let b = file.header.bounds
                let width = Int64(b.right) - Int64(b.left) + 1
                let height = Int64(b.bottom) - Int64(b.top) + 1
                return CGSize(width: Double(max(1, width)), height: Double(max(1, height)))
            case .wmfProgram(let program):
                return CGSize(
                    width: Double(max(1, program.canvasWidth)),
                    height: Double(max(1, program.canvasHeight))
                )
            }
        }
    }

    // MARK: - Prepare

    /// Parses `opened` once into a `Prepared`. Returns `nil` for an unrecognised
    /// format or a header-less EMF/WMF — the "unreadable" case the consumers map
    /// to the corrupt-file alert / the generic Quick Look icon. Never a silently
    /// blank canvas for a parseable file.
    public static func prepare(_ opened: OpenedMetafile) -> Prepared? {
        switch opened.format {
        case .emf:
            guard let file = try? EMFFile.parse(opened.data) else { return nil }
            return Prepared(content: .emf(file), kind: .emf, embeddedEMF: .notApplicable)

        case .wmf, .placeableWMF:
            guard let wmf = try? WMFFile.parse(opened.data) else { return nil }
            let embedded = WMFEmbeddedEMF.reassemble(wmf)
            // A complete, consistent, parseable embedded EMF supersedes the WMF
            // records (owner decision); anything else falls back to the records.
            if case .reassembled(let bytes) = embedded,
               let file = try? EMFFile.parse(bytes) {
                return Prepared(content: .emf(file), kind: .emf, embeddedEMF: .played)
            }
            let fate: Prepared.EmbeddedEMF
            switch embedded {
            case .none: fate = .absent
            // `.rejected`, or `.reassembled` whose bytes failed `EMFFile.parse`:
            // escapes were present but unusable, so the WMF records played.
            case .rejected, .reassembled: fate = .rejected
            }
            return Prepared(content: .wmfProgram(WMFTranslator.translate(wmf)), kind: .wmfRecords, embeddedEMF: fate)

        case .gzip, .unknown:
            return nil
        }
    }

    // MARK: - Render a prepared metafile

    /// Renders `prepared` into a fresh white sRGB bitmap (× `scale`). Returns
    /// `nil` only on a bitmap allocation failure.
    public static func makeImage(
        _ prepared: Prepared,
        scale: CGFloat = 1
    ) -> (CGImage, EMFRenderLog)? {
        switch prepared.content {
        case .emf(let file):
            return EMFRenderer.makeImage(file, scale: scale)
        case .wmfProgram(let program):
            return renderProgramToImage(program, scale: scale)
        }
    }

    /// Plays `prepared` into `context`, mapping the metafile's device space onto
    /// `target`.
    public static func render(
        _ prepared: Prepared,
        into context: CGContext,
        target: CGRect
    ) -> EMFRenderLog {
        switch prepared.content {
        case .emf(let file):
            return EMFRenderer.render(file, into: context, target: target)
        case .wmfProgram(let program):
            return renderProgram(program, into: context, target: target)
        }
    }

    /// Renders `prepared` into a single-page, true-vector PDF and returns its
    /// bytes, or `nil` only if the PDF context cannot be created.
    ///
    /// EMF pages are sized from the header's physical frame exactly as before
    /// (byte-identical). A WMF has no physical frame, so its page is its device
    /// canvas at one point per pixel — the same fallback EMF uses for a
    /// degenerate frame.
    public static func pdfData(_ prepared: Prepared) -> Data? {
        let pageSize: CGSize
        switch prepared.content {
        case .emf(let file):
            pageSize = emfPageSize(file.header)
        case .wmfProgram(let program):
            pageSize = clampToPageRange(
                width: Double(max(1, program.canvasWidth)),
                height: Double(max(1, program.canvasHeight))
            )
        }

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return nil }

        context.beginPDFPage(nil)
        // White the page first — a metafile has no page background of its own.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(mediaBox)
        _ = render(prepared, into: context, target: mediaBox)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    // MARK: - Open-metafile convenience (parse each call)

    /// Convenience over `prepare` + `makeImage`: parses `opened` and renders it.
    /// Returns `nil` for an unrecognised or header-less input.
    public static func makeImage(
        _ opened: OpenedMetafile,
        scale: CGFloat = 1
    ) -> (CGImage, EMFRenderLog)? {
        guard let prepared = prepare(opened) else { return nil }
        return makeImage(prepared, scale: scale)
    }

    /// Convenience over `prepare` + `render`. For an unrecognised or header-less
    /// input this is a no-op (the context is untouched) and the log is empty.
    public static func render(
        _ opened: OpenedMetafile,
        into context: CGContext,
        target: CGRect
    ) -> EMFRenderLog {
        guard let prepared = prepare(opened) else { return EMFRenderLog() }
        return render(prepared, into: context, target: target)
    }

    // MARK: - WMF program playback

    /// Renders a translated WMF program into a fresh white sRGB bitmap sized
    /// from the program's device canvas (× `scale`).
    private static func renderProgramToImage(
        _ program: WMFRenderProgram,
        scale: CGFloat
    ) -> (CGImage, EMFRenderLog)? {
        // The caller-supplied scale is sanitised (not hostile file data); the
        // program canvas is already clamped by the translator.
        let safeScale = scale.isFinite && scale > 0 ? Double(scale) : 1
        let width = clampDimension(Double(program.canvasWidth) * safeScale)
        let height = clampDimension(Double(program.canvasHeight) * safeScale)
        let (w, h) = clampArea(width: width, height: height)

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: w,
                  height: h,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let log = renderProgram(program, into: context, target: CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = context.makeImage() else { return nil }
        return (image, log)
    }

    /// Plays a translated WMF program into `context`. The program's canvas is
    /// the device space; the preamble payloads carry the logical→device mapping,
    /// so the renderer reuses `DeviceContext`/`playGDIRecord` unchanged.
    private static func renderProgram(
        _ program: WMFRenderProgram,
        into context: CGContext,
        target: CGRect
    ) -> EMFRenderLog {
        var log = EMFRenderLog()
        let header = syntheticHeader(width: program.canvasWidth, height: program.canvasHeight)
        let base = EMFRenderer.deviceToTarget(header: header, target: target, log: &log)
        var dc = DeviceContext(header: header)

        context.saveGState()
        defer { context.restoreGState() }

        for payload in program.payloads {
            EMFRenderer.playGDIRecord(payload, into: context, dc: &dc, base: base, log: &log)
        }
        return log
    }

    /// A minimal EMF header whose bounds are the WMF device canvas (0,0)-(w-1,
    /// h-1) and whose reference-device metrics are zero, so the DC's metric map
    /// modes fall back to 96 DPI. Everything else is a drawing-irrelevant
    /// default.
    private static func syntheticHeader(width: Int, height: Int) -> EMFHeader {
        EMFHeader(
            bounds: RectL(left: 0, top: 0, right: Int32(max(1, width) - 1), bottom: Int32(max(1, height) - 1)),
            frame: RectL(left: 0, top: 0, right: 0, bottom: 0),
            recordSignature: 0x464D_4520,
            version: 0x0001_0000,
            bytes: 0,
            records: 0,
            handles: 0,
            nDescription: 0,
            offDescription: 0,
            nPalEntries: 0,
            device: SizeL(cx: 0, cy: 0),
            millimeters: SizeL(cx: 0, cy: 0),
            extension1: nil,
            extension2: nil,
            description: nil,
            variant: .base
        )
    }

    // MARK: - PDF page sizing
    //
    // Replicates the EMF physical-frame page sizing so PDF export is byte-
    // identical to before now that it routes through this entry point.

    /// One point is 1/72 inch; one inch is 25.4 mm. `rclFrame` is in hundredths
    /// of a millimetre ([MS-EMF] §2.2.9), inclusive-inclusive.
    private static let pointsPerFrameUnit = 72.0 / 25.4 / 100.0
    /// PDF's spec maximum page side is 200 inches = 14400 pt.
    private static let maxPageSide = 14400.0

    /// The EMF document's physical page size in points, from the header frame.
    /// Falls back to the device-pixel bounds (at 1 pt/px) when the frame is
    /// degenerate, then to a 1×1 box, always clamped into the safe PDF range.
    private static func emfPageSize(_ header: EMFHeader) -> CGSize {
        let frame = header.frame
        let widthUnits = Int64(frame.right) - Int64(frame.left) + 1
        let heightUnits = Int64(frame.bottom) - Int64(frame.top) + 1
        if widthUnits > 0, heightUnits > 0 {
            let w = Double(widthUnits) * pointsPerFrameUnit
            let h = Double(heightUnits) * pointsPerFrameUnit
            if w >= 1, h >= 1 { return clampToPageRange(width: w, height: h) }
        }
        let bounds = header.bounds
        let bw = Int64(bounds.right) - Int64(bounds.left) + 1
        let bh = Int64(bounds.bottom) - Int64(bounds.top) + 1
        if bw > 0, bh > 0 {
            return clampToPageRange(width: Double(bw), height: Double(bh))
        }
        return CGSize(width: 1, height: 1)
    }

    /// Clamps a candidate page size into `[1, maxPageSide]` on each axis,
    /// scaling both axes by the same factor when a dimension overshoots so the
    /// aspect ratio is preserved.
    private static func clampToPageRange(width: Double, height: Double) -> CGSize {
        let w = max(width, 1)
        let h = max(height, 1)
        let overshoot = max(w / maxPageSide, h / maxPageSide, 1)
        return CGSize(width: w / overshoot, height: h / overshoot)
    }

    // MARK: - Canvas clamps (§8)
    //
    // Mirror EMFRenderer.makeImage's caps for the scaled WMF canvas. The
    // program canvas is already clamped by the translator at scale 1; these
    // bound the post-scale size.

    private static let canvasDimensionCap = 16_384
    private static let canvasAreaCap = 32_000_000

    private static func clampDimension(_ requested: Double) -> Int {
        guard requested.isFinite else { return canvasDimensionCap }
        let rounded = requested.rounded()
        if rounded < 1 { return 1 }
        if rounded > Double(canvasDimensionCap) { return canvasDimensionCap }
        return Int(rounded)
    }

    private static func clampArea(width: Int, height: Int) -> (width: Int, height: Int) {
        let area = width * height
        guard area > canvasAreaCap else { return (width, height) }
        let scale = (Double(canvasAreaCap) / Double(area)).squareRoot()
        return (
            max(1, Int((Double(width) * scale).rounded(.down))),
            max(1, Int((Double(height) * scale).rounded(.down)))
        )
    }
}
