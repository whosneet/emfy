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

    /// One record-type tally for the diagnostic report: a human-readable record
    /// name and how many records of that kind the metafile carries. Structure
    /// only — a count of record types, never any drawing content, text, or
    /// object data. EMF names are the `EMR_*` enumeration ([MS-EMF] §2.1.1); WMF
    /// names the `META_*` enumeration ([MS-WMF] §2.1.1.1); an undefined type id
    /// is named "Unknown (…)".
    public struct RecordKindCount: Sendable, Equatable {
        public let name: String
        public let count: Int

        public init(name: String, count: Int) {
            self.name = name
            self.count = count
        }
    }

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
            /// A WMF whose embedded EMF reassembled and parsed, but the user chose
            /// to play the WMF records instead (`RenderOptions.useEmbeddedEMF ==
            /// false`). The "Drawn from" row can then say the records were used
            /// despite a usable EMF being present.
            case declined
        }

        /// The metafile's natural size in device pixels: the EMF header bounds
        /// (inclusive-inclusive, so right−left+1 × bottom−top+1), or the WMF
        /// program's device canvas. Never smaller than 1×1.
        public let naturalSize: CGSize
        /// The device-space page rectangle in the file's own coordinates: EMF
        /// header bounds `(left, top, right−left+1, bottom−top+1)` (y-down,
        /// inclusive-inclusive), or `(0, 0, canvasW, canvasH)` for WMF. Its
        /// `size` equals `naturalSize`; its `origin` is the non-zero header
        /// left/top the scene import needs to rebuild the device→target fit.
        public let deviceBounds: CGRect
        /// Which rendering path this metafile takes.
        public let kind: Kind
        /// The fate of a WMF's embedded EMF.
        public let embeddedEMF: EmbeddedEMF
        /// Whether the metafile that will be rendered is an EMF+ **dual** file —
        /// it carries a complete GDI (EMF) description alongside the EMF+ one
        /// (EmfPlusHeader Dual flag, [MS-EMFPLUS] §2.3.3.3). Only then does
        /// `RenderOptions.emfPlusArbitration == .gdi` have any effect, so the app
        /// uses this to offer or explain that choice. Always false for WMF record
        /// playback and for a non-dual or pure-GDI EMF.
        public let hasGDICopy: Bool
        /// Record counts grouped by type, for the diagnostic report. The EMF
        /// record inventory for an EMF (or a WMF's played-back embedded EMF); the
        /// WMF record inventory for WMF record playback. Sorted by type id
        /// ascending. Structure only — never drawing content.
        public let recordKinds: [RecordKindCount]

        let content: Content

        /// The record-inspector list rows for a translated WMF program (F5b),
        /// built from its source `WMFFile` at prepare time because the program
        /// keeps only translated payloads. Empty for EMF content, whose rows
        /// `recordRefs()` derives on demand from the retained `EMFFile`.
        let wmfRecordRefList: [RecordRef]

        /// The parser diagnostics of the decoded EMF — a standalone `.emf`, or a
        /// WMF's played-back embedded EMF. Empty for WMF record playback (that
        /// path's advisory walk diagnostics live on `WMFFile`, which the app does
        /// not surface).
        public var emfDiagnostics: [EMFDiagnostic] {
            if case .emf(let file) = content { return file.diagnostics }
            return []
        }

        init(
            content: Content,
            kind: Kind,
            embeddedEMF: EmbeddedEMF,
            hasGDICopy: Bool,
            recordKinds: [RecordKindCount],
            wmfRecordRefList: [RecordRef] = []
        ) {
            self.content = content
            self.kind = kind
            self.embeddedEMF = embeddedEMF
            self.hasGDICopy = hasGDICopy
            self.recordKinds = recordKinds
            self.wmfRecordRefList = wmfRecordRefList
            self.deviceBounds = Prepared.deviceBounds(of: content)
            self.naturalSize = deviceBounds.size
        }

        /// EMF: the header bounds rectangle. WMF: the program canvas at origin
        /// zero. Int64 keeps the inclusive-inclusive +1 from overflowing a
        /// full-range `rclBounds` (§8); the size is floored at 1×1.
        private static func deviceBounds(of content: Content) -> CGRect {
            switch content {
            case .emf(let file):
                let b = file.header.bounds
                let width = Int64(b.right) - Int64(b.left) + 1
                let height = Int64(b.bottom) - Int64(b.top) + 1
                return CGRect(
                    x: Double(b.left), y: Double(b.top),
                    width: Double(max(1, width)), height: Double(max(1, height))
                )
            case .wmfProgram(let program):
                return CGRect(
                    x: 0, y: 0,
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
    public static func prepare(_ opened: OpenedMetafile, options: RenderOptions = .default) -> Prepared? {
        switch opened.format {
        case .emf:
            guard let file = try? EMFFile.parse(opened.data) else { return nil }
            return Prepared(content: .emf(file), kind: .emf, embeddedEMF: .notApplicable,
                            hasGDICopy: isDualEMFPlus(file), recordKinds: emfRecordKinds(file))

        case .wmf, .placeableWMF:
            guard let wmf = try? WMFFile.parse(opened.data) else { return nil }
            let embedded = WMFEmbeddedEMF.reassemble(wmf)
            // A complete, consistent, parseable embedded EMF normally supersedes
            // the WMF records (owner decision) — unless the user declined it
            // (option 4, RenderOptions.useEmbeddedEMF == false), in which case the
            // records play but `Prepared` still records that a usable EMF existed.
            if case .reassembled(let bytes) = embedded,
               let file = try? EMFFile.parse(bytes) {
                if options.useEmbeddedEMF {
                    return Prepared(content: .emf(file), kind: .emf, embeddedEMF: .played,
                                    hasGDICopy: isDualEMFPlus(file), recordKinds: emfRecordKinds(file))
                }
                return Prepared(content: .wmfProgram(WMFTranslator.translate(wmf)), kind: .wmfRecords,
                                embeddedEMF: .declined, hasGDICopy: false, recordKinds: wmfRecordKinds(wmf),
                                wmfRecordRefList: Prepared.wmfRecordRefs(wmf))
            }
            let fate: Prepared.EmbeddedEMF
            switch embedded {
            case .none: fate = .absent
            // `.rejected`, or `.reassembled` whose bytes failed `EMFFile.parse`:
            // escapes were present but unusable, so the WMF records played.
            case .rejected, .reassembled: fate = .rejected
            }
            return Prepared(content: .wmfProgram(WMFTranslator.translate(wmf)), kind: .wmfRecords,
                            embeddedEMF: fate, hasGDICopy: false, recordKinds: wmfRecordKinds(wmf),
                            wmfRecordRefList: Prepared.wmfRecordRefs(wmf))

        case .gzip, .unknown:
            return nil
        }
    }

    /// Whether `file` is an EMF+ **dual** file (EmfPlusHeader Dual flag 0x0001,
    /// [MS-EMFPLUS] §2.3.3.3): it carries a complete GDI copy, so option 3's
    /// `.gdi` arbitration applies. Drives `Prepared.hasGDICopy`. Uses the
    /// bounded, header-only `emfPlusIsDual()` — it never reassembles the EMF+
    /// stream, so preparing a large EMF+ file does no extra full-stream work.
    private static func isDualEMFPlus(_ file: EMFFile) -> Bool {
        file.emfPlusIsDual()
    }

    // MARK: - Record inventory (diagnostic report)

    /// The EMF record inventory with each type resolved to its `EMR_*` name
    /// (undefined ids named "Unknown (type …)"), preserving the inventory's
    /// type-id-ascending order. Counts only; no record payload is read.
    private static func emfRecordKinds(_ file: EMFFile) -> [RecordKindCount] {
        file.recordInventory().map { entry in
            RecordKindCount(
                name: EMFRecordType.name(for: entry.type) ?? "Unknown (type \(entry.type))",
                count: entry.count
            )
        }
    }

    /// The WMF record inventory with each RecordFunction resolved to its `META_*`
    /// name (undefined functions named "Unknown (function 0x…)").
    private static func wmfRecordKinds(_ file: WMFFile) -> [RecordKindCount] {
        file.recordInventory().map { entry in
            RecordKindCount(
                name: WMFRecordType.name(for: entry.function) ?? String(format: "Unknown (function 0x%04X)", entry.function),
                count: entry.count
            )
        }
    }

    // MARK: - Render a prepared metafile

    /// Renders `prepared` into a fresh sRGB bitmap (× `scale`) on `background`
    /// (opaque white by default, matching every render before this option;
    /// `.transparent` leaves the page clear). Returns `nil` only on a bitmap
    /// allocation failure.
    public static func makeImage(
        _ prepared: Prepared,
        scale: CGFloat = 1,
        background: RenderBackground = .white,
        options: RenderOptions = .default
    ) -> (CGImage, EMFRenderLog)? {
        switch prepared.content {
        case .emf(let file):
            return EMFRenderer.makeImage(file, scale: scale, background: background, options: options)
        case .wmfProgram(let program):
            return renderProgramToImage(program, scale: scale, background: background, options: options)
        }
    }

    /// Plays `prepared` into `context`, mapping the metafile's device space onto
    /// `target`.
    public static func render(
        _ prepared: Prepared,
        into context: CGContext,
        target: CGRect,
        options: RenderOptions = .default
    ) -> EMFRenderLog {
        switch prepared.content {
        case .emf(let file):
            return EMFRenderer.render(file, into: context, target: target, options: options)
        case .wmfProgram(let program):
            return renderProgram(program, into: context, target: target, options: options)
        }
    }

    /// Renders `prepared` into a single-page, true-vector PDF and returns its
    /// bytes, or `nil` only if the PDF context cannot be created.
    ///
    /// EMF pages are sized from the header's physical frame exactly as before
    /// (byte-identical). A WMF has no physical frame, so its page is its device
    /// canvas at one point per pixel — the same fallback EMF uses for a
    /// degenerate frame.
    ///
    /// Honours options 2 (font substitutions), 3 (EMF+ arbitration, via the
    /// render call), and 4 (already baked into `prepared`). Option 1
    /// (antialiasing) is MEANINGLESS for vector PDF output — there is no raster
    /// coverage to smooth — so it is neutralised here, keeping default PDF output
    /// byte-identical.
    public static func pdfData(_ prepared: Prepared, options: RenderOptions = .default) -> Data? {
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
        // Antialiasing has no raster meaning for vector PDF output; neutralise it
        // so option 1 never embeds a smoothing hint into the PDF (2/3/4 still honoured).
        var pdfOptions = options
        pdfOptions.antialiasing = .smooth
        _ = render(prepared, into: context, target: mediaBox, options: pdfOptions)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    // MARK: - Open-metafile convenience (parse each call)

    /// Convenience over `prepare` + `makeImage`: parses `opened` and renders it.
    /// Returns `nil` for an unrecognised or header-less input.
    public static func makeImage(
        _ opened: OpenedMetafile,
        scale: CGFloat = 1,
        background: RenderBackground = .white,
        options: RenderOptions = .default
    ) -> (CGImage, EMFRenderLog)? {
        guard let prepared = prepare(opened, options: options) else { return nil }
        return makeImage(prepared, scale: scale, background: background, options: options)
    }

    /// Convenience over `prepare` + `render`. For an unrecognised or header-less
    /// input this is a no-op (the context is untouched) and the log is empty.
    public static func render(
        _ opened: OpenedMetafile,
        into context: CGContext,
        target: CGRect,
        options: RenderOptions = .default
    ) -> EMFRenderLog {
        guard let prepared = prepare(opened, options: options) else { return EMFRenderLog() }
        return render(prepared, into: context, target: target, options: options)
    }

    // MARK: - Scene-import observation (E1)

    /// Plays `prepared` with a `RenderObserver` attached and returns the
    /// resolved drawing operations plus the record-partition inputs the editor's
    /// importer needs. This reuses the ONE DC interpreter — it never
    /// reinterprets records — so the lifted ops are exactly what a render draws.
    ///
    /// Playback goes into a throwaway 1×1 context: every captured value is in
    /// DEVICE space or is DC state, independent of the target size, so the
    /// pixels are discarded and import does no canvas-sized allocation.
    ///
    /// An EMF+ file (EMF+ drawing records present and not forced to GDI) draws
    /// via EMF+; v1 does not lift EMF+, so `renderPath == .emfPlus` with no ops
    /// — the importer keeps that content as passthrough.
    public static func observe(_ prepared: Prepared, options: RenderOptions = .default) -> PlaybackObservation {
        let observer = RenderObserver()
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            switch prepared.content {
            case .emf(let file):
                return PlaybackObservation(ops: [], pathConstructionIndices: [], renderPath: .gdi, unitCount: file.records.count, unitRoles: emfUnitRoles(file), unitTypes: file.records.map(\.type))
            case .wmfProgram(let program):
                return PlaybackObservation(ops: [], pathConstructionIndices: [], renderPath: .wmf, unitCount: program.payloads.count, unitRoles: program.payloads.map(payloadRole), unitTypes: program.payloads.map(payloadEMRType))
            }
        }
        let target = CGRect(x: 0, y: 0, width: 1, height: 1)

        switch prepared.content {
        case .emf(let file):
            // Same EMF+ arbitration as `EMFRenderer.render` ([MS-EMFPLUS]
            // §1.3.1): if EMF+ drawing records play, the GDI loop never runs.
            let plus = file.emfPlusStream()
            let forceGDI = options.emfPlusArbitration == .gdi && (plus.header?.isDual ?? false)
            if !forceGDI, plus.records.contains(where: \.isDrawing) {
                // EMF+ drives output: render with the observer so each EMF+ drawing
                // record lifts into `plusEntries` (slice E1a2). The GDI fallback is
                // not played — the observer records it as `fallback`.
                _ = EMFRenderer.render(file, into: context, target: target, options: options, observer: observer)
                return PlaybackObservation(
                    ops: [],
                    pathConstructionIndices: observer.pathConstructionIndices,
                    renderPath: .emfPlus,
                    unitCount: file.records.count,
                    unitRoles: emfPlusUnitRoles(file, fallback: observer.emfPlusFallbackGDI),
                    unitTypes: file.records.map(\.type),
                    plusEntries: observer.plusEntries
                )
            }
            _ = EMFRenderer.render(file, into: context, target: target, options: options, observer: observer)
            return PlaybackObservation(
                ops: observer.draws,
                pathConstructionIndices: observer.pathConstructionIndices,
                renderPath: .gdi,
                unitCount: file.records.count,
                unitRoles: emfUnitRoles(file),
                unitTypes: file.records.map(\.type)
            )
        case .wmfProgram(let program):
            _ = renderProgram(program, into: context, target: target, options: options, observer: observer)
            return PlaybackObservation(
                ops: observer.draws,
                pathConstructionIndices: observer.pathConstructionIndices,
                renderPath: .wmf,
                unitCount: program.payloads.count,
                unitRoles: program.payloads.map(payloadRole),
                unitTypes: program.payloads.map(payloadEMRType)
            )
        }
    }

    /// Replays ONLY the EMF+ drawing records at `streamIndices` of `prepared`
    /// into `context`, mapping the metafile's device space onto `target` (slice
    /// E1a2). The scene renderer uses this to reproduce a lifted EMF+ text/image/
    /// passthrough element: every EMF+ state/object record executes so the
    /// transform, clip and object table build up correctly, but only the selected
    /// stream indices paint, at the exact z-moment the renderer calls this. A
    /// non-EMF prepared metafile is a no-op (the context is untouched).
    public static func replayEMFPlus(
        _ prepared: Prepared,
        streamIndices: Set<Int>,
        into context: CGContext,
        target: CGRect,
        options: RenderOptions = .default
    ) {
        guard case .emf(let file) = prepared.content else { return }
        _ = EMFRenderer.render(file, into: context, target: target, options: options, emfPlusDrawFilter: streamIndices)
    }

    /// The EMR type id for a translated WMF unit, used only for passthrough
    /// reporting: an un-decoded record carries its type, everything else 0.
    private static func payloadEMRType(_ payload: EMFRecordPayload) -> UInt32 {
        switch payload {
        case .unimplemented(let type): return type
        case .malformed(let type, _): return type
        default: return 0
        }
    }

    /// Per-record coarse roles for an EMF. EMR_HEADER (1) / EMR_EOF (14) are
    /// structural and EMR_COMMENT (70) is a passthrough comment, decided by type;
    /// everything else is classified from its decoded payload.
    private static func emfUnitRoles(_ file: EMFFile) -> [UnitRole] {
        file.records.indices.map { i in
            switch file.records[i].type {
            case 1, 14: return .structural
            case 70: return .comment
            default: return payloadRole(file.payload(of: file.records[i]))
            }
        }
    }

    /// Per-record coarse roles for an EMF+ file (slice E1a2). Structure records
    /// are structural, EMR_COMMENT is a comment (EMF+ data — the importer decides
    /// drawing/state from the lifted ops), a GDI record the walk did not play is
    /// the `fallback` role, and a GDI record played in a GetDC window is
    /// classified from its payload.
    private static func emfPlusUnitRoles(_ file: EMFFile, fallback: Set<Int>) -> [UnitRole] {
        file.records.indices.map { i in
            switch file.records[i].type {
            case 1, 14: return .structural
            case 70: return .comment
            default: return fallback.contains(i) ? .fallback : payloadRole(file.payload(of: file.records[i]))
            }
        }
    }

    /// Buckets a decoded payload for the record partition. Exhaustive so a new
    /// payload case forces a decision here.
    static func payloadRole(_ payload: EMFRecordPayload) -> UnitRole {
        switch payload {
        case .setWindowExtEx, .setWindowOrgEx, .setViewportExtEx, .setViewportOrgEx,
             .setMapMode, .setBkMode, .setPolyFillMode, .setROP2, .saveDC, .restoreDC,
             .setWorldTransform, .modifyWorldTransform, .setMiterLimit, .setArcDirection,
             .intersectClipRect, .excludeClipRect, .createPen, .extCreatePen,
             .createBrushIndirect, .selectObject, .deleteObject, .beginPath, .endPath,
             .closeFigure, .selectClipPath, .extSelectClipRgn, .moveToEx,
             .setTextAlign, .setTextColor, .setBkColor, .extCreateFontIndirectW:
            return .state
        case .polyBezier, .polygon, .polyline, .polyBezierTo, .polylineTo,
             .ellipse, .rectangle, .roundRect, .arc, .arcTo, .lineTo,
             .polyBezier16, .polygon16, .polyline16, .polyBezierTo16, .polylineTo16,
             .polyPolyline16, .polyPolygon16, .pie, .chord, .setPixel, .patBlt,
             .fillPath, .strokeAndFillPath, .strokePath,
             .extTextOutW, .stretchDIBits, .bitBlt, .stretchBlt, .setDIBitsToDevice:
            return .drawing
        case .unimplemented, .malformed:
            return .unknown
        }
    }

    // MARK: - WMF program playback

    /// Renders a translated WMF program into a fresh white sRGB bitmap sized
    /// from the program's device canvas (× `scale`).
    private static func renderProgramToImage(
        _ program: WMFRenderProgram,
        scale: CGFloat,
        background: RenderBackground = .white,
        options: RenderOptions = .default
    ) -> (CGImage, EMFRenderLog)? {
        // The caller-supplied scale is sanitised (not hostile file data); the
        // program canvas is already clamped by the translator. The per-side +
        // area clamp is the shared `EMFRenderer.canvasPixelSize`, so a WMF scene
        // sizes identically in the viewer and the editor's `SceneRenderer`.
        let (w, h) = EMFRenderer.canvasPixelSize(
            deviceWidth: Double(program.canvasWidth), deviceHeight: Double(program.canvasHeight), scale: scale
        )

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

        // `.white` paints the historical opaque page; `.transparent` leaves the
        // premultiplied-alpha canvas clear (S1a Export › PNG background).
        if background == .white {
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }

        let log = renderProgram(program, into: context, target: CGRect(x: 0, y: 0, width: w, height: h), options: options)
        guard let image = context.makeImage() else { return nil }
        return (image, log)
    }

    /// Plays a translated WMF program into `context`. The program's canvas is
    /// the device space; the preamble payloads carry the logical→device mapping,
    /// so the renderer reuses `DeviceContext`/`playGDIRecord` unchanged.
    private static func renderProgram(
        _ program: WMFRenderProgram,
        into context: CGContext,
        target: CGRect,
        options: RenderOptions = .default,
        observer: RenderObserver? = nil
    ) -> EMFRenderLog {
        var log = EMFRenderLog()
        let header = syntheticHeader(width: program.canvasWidth, height: program.canvasHeight)
        let base = EMFRenderer.deviceToTarget(header: header, target: target, log: &log)
        var dc = DeviceContext(header: header, fontSubstitutions: options.fontSubstitutions)
        dc.observer = observer

        context.saveGState()
        defer { context.restoreGState() }

        // Crisp antialiasing (option 1): off at canvas level for the pure-GDI WMF
        // loop. WMF carries no EMF+, so options 3 is inapplicable here. Set only
        // for `.crisp`, keeping `.smooth` output byte-identical.
        if options.antialiasing == .crisp {
            context.setShouldAntialias(false)
        }

        // Index is into `program.payloads` so an import can map an op to its WMF
        // playback unit (E1 provenance).
        for index in program.payloads.indices {
            observer?.currentRecordIndex = index
            EMFRenderer.playGDIRecord(program.payloads[index], into: context, dc: &dc, base: base, log: &log)
        }
        observer?.finalize()
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
}
