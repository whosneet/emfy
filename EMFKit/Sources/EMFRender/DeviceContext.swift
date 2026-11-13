import CoreGraphics
import EMFParse
import Foundation

/// The playback device context (primer §5): the GDI state machine records
/// mutate and drawing records consume. Pure state — it never touches a
/// CGContext, so every transition is unit-testable.
struct DeviceContext {

    /// The saveable DC state — exactly what EMR_SAVEDC snapshots and
    /// EMR_RESTOREDC brings back. The object table is deliberately NOT here:
    /// per [MS-EMF] §3.1.1.2 the object table belongs to the playback device
    /// context's lifetime, not to the saved-state stack.
    struct State: Equatable {
        var mapMode: MapMode = .text
        var windowOrg = PointL(x: 0, y: 0)
        var windowExt = SizeL(cx: 1, cy: 1)
        var viewportOrg = PointL(x: 0, y: 0)
        var viewportExt = SizeL(cx: 1, cy: 1)
        var world = CGAffineTransform.identity
        var bkMode: BackgroundMode = .opaque
        var polyFillMode: PolygonFillMode = .alternate
        /// Raw ROP2 mode; R2_COPYPEN (0x0D) is the GDI default. Stored for
        /// save/restore fidelity but never acted on: drawing always behaves
        /// as R2_COPYPEN (primer D5 — best partial output beats missing
        /// shapes).
        var rop2Raw: UInt32 = DeviceContext.rop2CopyPen
        /// Spec-literal unsigned miter limit ([MS-EMF] §2.3.11.21); GDI's
        /// default is 10.
        var miterLimit: UInt32 = 10
        /// Arc sweep direction (EMR_SETARCDIRECTION); GDI's default is
        /// AD_COUNTERCLOCKWISE, which is what the arc path builder draws by
        /// default — so the default state leaves every arc figure byte-identical.
        var arcDirection: ArcDirection = .counterclockwise
        /// Bitmap stretch mode (EMR_SETSTRETCHBLTMODE); GDI's default is
        /// BLACKONWHITE. For this vector viewer it drives only the interpolation
        /// quality of a shrunk bitmap — HALFTONE → smooth, everything else →
        /// nearest, so the default keeps bitmap output byte-identical.
        var stretchBltMode: StretchBltMode = .blackOnWhite
        /// Current position in LOGICAL units — mapped through whatever the
        /// transform is at consumption time, exactly as GDI stores it.
        var currentPosition = PointL(x: 0, y: 0)
        /// Selected pen — a resolved VALUE (see RenderObjects.swift), default
        /// BLACK_PEN.
        var pen: ResolvedPen = .cosmetic(StockObjects.black)
        /// Selected brush — a resolved value, default WHITE_BRUSH.
        var brush: ResolvedBrush = .solid(StockObjects.white)
        /// Selected font — a resolved value, `nil` until one is selected (the
        /// text drawer then falls back to the system font). Not part of the
        /// phase-2/3 set; added for phase-4 text playback.
        var font: ResolvedFont?
        /// Text foreground colour (EMR_SETTEXTCOLOR); GDI's default is black.
        var textColor: ColorRef = StockObjects.black
        /// Background colour (EMR_SETBKCOLOR); GDI's default is white. Painted
        /// behind text under bkMode OPAQUE or ETO_OPAQUE.
        var bkColor: ColorRef = StockObjects.white
        /// Text alignment mask (EMR_SETTEXTALIGN); GDI's default is
        /// (TA_LEFT, TA_TOP, TA_NOUPDATECP) == rawValue 0.
        var textAlign = TextAlign(rawValue: 0)
        /// The last VALID page→device scale (default: MM_TEXT's 1:1). A state
        /// record that would produce a zero-extent mapping logs and leaves
        /// this untouched — "keep the previous valid mapping".
        var scale = CoordinatePipeline.Scale(sx: 1, sy: 1)
        /// The current clipping region in DEVICE space. Part of the saved
        /// state: SaveDC snapshots it and RestoreDC brings it back, matching
        /// GDI's Regions state element ([MS-EMF] §3.1.1.2.1, saved by SaveDC).
        var clip = ClipRegion.none
    }

    /// R2_COPYPEN ([MS-WMF] §2.1.1.2 BinaryRasterOperation).
    static let rop2CopyPen: UInt32 = 0x0D
    /// Object-table capacity cap (primer §8: cap the table, reject absurd
    /// indices). Indices are 1-based; 0 is reserved for the metafile itself
    /// ([MS-EMF] §3.1.1.2).
    static let objectIndexCap: UInt32 = 65_536
    /// SaveDC stack depth cap; overflow drops the save with a log entry.
    static let saveStackCap = 512

    var state = State()
    private(set) var objects: [UInt32: TableObject] = [:]
    private(set) var saveStack: [State] = []
    /// Header metrics feed the fixed metric map modes' scale.
    let header: EMFHeader
    /// User-defined font substitutions consulted — before the built-in table —
    /// when a requested family is missing (S1b RenderOptions). Empty by default,
    /// so font resolution stays byte-identical to before the option.
    let fontSubstitutions: [FontSubstitution]

    /// Optional scene-import observer (E1). Nil on every normal render, so the
    /// hot path is untouched and every committed snapshot is byte-identical;
    /// only an import attaches one. When set, drawing records report their
    /// resolved operation and path brackets report their construction records.
    var observer: RenderObserver?

    /// Path-bracket construction state ([MS-EMF] §2.3.10). This is DC-level,
    /// NOT part of the saveable `State`: a bracket is a transient
    /// record-recording mode bounded by EMR_BEGINPATH … EMR_ENDPATH, orthogonal
    /// to the SaveDC/RestoreDC state stack.
    ///
    /// While `pathAccumulator` is non-nil a bracket is open and geometry
    /// records APPEND to it (in DEVICE space) instead of drawing. EMR_ENDPATH
    /// moves the accumulator into `currentPath`; the closing records
    /// (FILL/STROKE/STROKEANDFILLPATH, SELECTCLIPPATH) consume and clear it.
    private(set) var pathAccumulator: CGMutablePath?
    /// The last subpath's start point in DEVICE space, for EMR_CLOSEFIGURE.
    /// `nil` when no subpath is open.
    private var pathSubpathStart: CGPoint?
    /// The closed, selected path from EMR_ENDPATH, in DEVICE space; consumed
    /// (set back to nil) by the next fill/stroke/clip-from-path record.
    private(set) var currentPath: CGPath?

    /// True while an EMR_BEGINPATH bracket is open (geometry is recorded, not
    /// drawn).
    var isRecordingPath: Bool { pathAccumulator != nil }

    init(header: EMFHeader, fontSubstitutions: [FontSubstitution] = []) {
        self.header = header
        self.fontSubstitutions = fontSubstitutions
    }

    /// The current logical → device transform.
    var resolvedTransform: CGAffineTransform {
        CoordinatePipeline.resolvedTransform(
            world: state.world,
            scale: state.scale,
            windowOrg: state.windowOrg,
            viewportOrg: state.viewportOrg
        )
    }

    // MARK: - Record application

    /// Applies one decoded payload to the DC. Returns `true` when the record
    /// was consumed here (state mutation, object management, or a logged
    /// skip); `false` when it is a drawing record the renderer must draw.
    mutating func apply(_ payload: EMFRecordPayload, log: inout EMFRenderLog) -> Bool {
        switch payload {
        // MARK: State records
        case .setMapMode(let mode):
            // An unknown value falls back to MM_TEXT in the pipeline; surface
            // that (previously silent — phase-2 backlog).
            if case .unknown(let raw) = mode {
                log.note(.unknownEnumValue(record: 17, rawValue: raw))
            }
            state.mapMode = mode
            recomputeScale(log: &log)
            return true

        case .setWindowExtEx(let extent):
            // Extents are honoured ONLY in MM_ISOTROPIC/MM_ANISOTROPIC —
            // GDI's SetWindowExtEx/SetViewportExtEx are documented no-ops in
            // every other mode, so the record is ignored there.
            guard extentsApply else { return true }
            state.windowExt = extent
            recomputeScale(log: &log)
            return true

        case .setViewportExtEx(let extent):
            guard extentsApply else { return true }
            state.viewportExt = extent
            recomputeScale(log: &log)
            return true

        case .setWindowOrgEx(let origin):
            // Origins offset in every map mode.
            state.windowOrg = origin
            return true

        case .setViewportOrgEx(let origin):
            state.viewportOrg = origin
            return true

        case .setBkMode(let mode):
            // Stored only: background mode affects dashed-gap/text-background
            // painting, which arrives with EMR_SETBKCOLOR in phase 4. An
            // unknown value keeps the current mode and logs (phase-2 backlog).
            if case .unknown(let raw) = mode {
                log.note(.unknownEnumValue(record: 18, rawValue: raw))
                return true
            }
            state.bkMode = mode
            return true

        case .setPolyFillMode(let mode):
            // Unknown values keep the current mode and log (previously silent
            // — phase-2 backlog); both defined values are handled.
            if case .unknown(let raw) = mode {
                log.note(.unknownEnumValue(record: 19, rawValue: raw))
                return true
            }
            state.polyFillMode = mode
            return true

        case .setROP2(let rawMode):
            state.rop2Raw = rawMode
            if rawMode != Self.rop2CopyPen {
                // Coalesced by mode so a file with tens of thousands of
                // SETROP2s yields one log line (phase-2 backlog).
                log.noteUnsupportedROP2(rawMode: rawMode)
            }
            return true

        case .setMiterLimit(let miterLimit):
            state.miterLimit = miterLimit
            return true

        case .setArcDirection(let direction):
            // An unknown value keeps the current direction and logs (log-and-skip).
            if case .unknown(let raw) = direction {
                log.note(.unknownEnumValue(record: 57, rawValue: raw))
                return true
            }
            state.arcDirection = direction
            return true

        case .setStretchBltMode(let mode):
            // Interpolation quality only; an unknown value keeps the current mode.
            if case .unknown(let raw) = mode {
                log.note(.unknownEnumValue(record: 21, rawValue: raw))
                return true
            }
            state.stretchBltMode = mode
            return true

        case .setWorldTransform(let xform):
            state.world = CoordinatePipeline.affine(from: xform)
            return true

        case .modifyWorldTransform(let payload):
            applyModifyWorldTransform(payload, log: &log)
            return true

        case .saveDC:
            if saveStack.count >= Self.saveStackCap {
                log.note(.saveDCStackOverflow)
            } else {
                saveStack.append(state)
            }
            return true

        case .restoreDC(let savedDC):
            applyRestoreDC(savedDC, log: &log)
            return true

        case .moveToEx(let point):
            state.currentPosition = point
            // Inside a bracket, EMR_MOVETOEX starts a new subpath at the point
            // (GDI advanced-mode); outside, it only moves the position.
            if isRecordingPath {
                startSubpath(at: point)
                observer?.noteBracketRecord()
            }
            return true

        case .intersectClipRect(let clip):
            // [MS-EMF] §2.3.2.3: Clip is a RectL in LOGICAL units. Transform to
            // device with the transform in effect and intersect the current
            // clip. (The spec excludes the lower/right edges; that sub-pixel
            // nicety is immaterial to a rasterising viewer and is not modelled.)
            let deviceRect = PathBuilder.cgRect(clip).applying(resolvedTransform)
            state.clip.intersect(.rects([deviceRect]))
            return true

        case .excludeClipRect(let clip):
            // [MS-WMF] §2.3.5.2 META_EXCLUDECLIPRECT: subtract the rectangle
            // (logical units, transformed to device) from the current clip.
            let deviceRect = PathBuilder.cgRect(clip).applying(resolvedTransform)
            state.clip.exclude(deviceRect)
            return true

        // MARK: Path brackets ([MS-EMF] §2.3.10) — construction state only.
        // The FILL/STROKE closers and SELECTCLIPPATH need a CGContext, so the
        // renderer drives them; they are NOT consumed here (return false). The
        // three construction records below carry no drawing and are consumed.
        case .beginPath:
            beginPathBracket(log: &log)
            observer?.beginBracket()
            return true

        case .endPath:
            endPathBracket()
            observer?.endBracket()
            return true

        case .closeFigure:
            closeFigure()
            observer?.noteBracketRecord()
            return true

        case .abortPath:
            // EMR_ABORTPATH (§2.3.10.1): discard any open bracket AND the
            // closed-but-unconsumed path. The construction records drew nothing,
            // so the importer folds them into state (not passthrough geometry).
            abortPath()
            observer?.abortBracket()
            return true

        case .selectClipPath(let mode):
            // EMR_SELECTCLIPPATH ([MS-EMF] §2.3.2.5): combine the current path
            // (already DEVICE space) with the clip per RegionMode. Pure state —
            // no CGContext needed.
            applySelectClipPath(mode, log: &log)
            return true

        case .extSelectClipRgn(let payload):
            // EMR_EXTSELECTCLIPRGN ([MS-EMF] §2.3.2.2): region rects are LOGICAL
            // units; transform to device via the transform in effect. Pure
            // state — no CGContext needed.
            applyExtSelectClipRgn(payload, log: &log)
            return true

        // The FILL/STROKE closers reach the renderer — they paint and need the
        // device→target transform plus the CGContext.
        case .fillPath, .strokeAndFillPath, .strokePath:
            return false

        // MARK: Object records
        case .createPen(let payload):
            let pen = ObjectResolver.resolve(payload, log: &log)
            store(.pen(pen), at: payload.ihPen, log: &log)
            return true

        case .extCreatePen(let payload):
            let pen = ObjectResolver.resolve(payload, log: &log)
            store(.pen(pen), at: payload.ihPen, log: &log)
            return true

        case .createBrushIndirect(let payload):
            let brush = ObjectResolver.resolve(payload, log: &log)
            store(.brush(brush), at: payload.ihBrush, log: &log)
            return true

        case .selectObject(let handle):
            applySelectObject(handle, log: &log)
            return true

        case .deleteObject(let handle):
            applyDeleteObject(handle, log: &log)
            return true

        // MARK: Text state ([MS-EMF] §2.3.11.25/.26/.10, §2.3.7.8)
        case .setTextAlign(let align):
            state.textAlign = align
            return true

        case .setTextColor(let color):
            state.textColor = color
            return true

        case .setBkColor(let color):
            state.bkColor = color
            return true

        case .extCreateFontIndirectW(let payload):
            // Resolve the LOGFONT to a base CTFont + attributes now; the text
            // drawer sizes it to the device at draw time (the transform can
            // change before the run — same reasoning as geometric pen widths).
            let font = FontMapper.resolve(payload.logFont, substitutions: fontSubstitutions, log: &log)
            store(.font(font), at: payload.ihFonts, log: &log)
            return true

        // MARK: Text / bitmap DRAWING records — the renderer's job (return false).
        case .extTextOutA, .extTextOutW, .smallTextOut, .gradientFill,
             .stretchDIBits, .bitBlt, .stretchBlt, .setDIBitsToDevice:
            return false

        // MARK: Fallback verdicts
        case .unimplemented(let type):
            log.noteUnimplemented(type: type)
            return true

        case .malformed(let type, _):
            log.note(.malformedRecord(type: type))
            return true

        // MARK: Drawing records — the renderer's job
        case .polyBezier, .polygon, .polyline, .polyBezierTo, .polylineTo,
             .polyPolyline, .polyPolygon,
             .ellipse, .rectangle, .roundRect, .arc, .arcTo, .lineTo,
             .polyBezier16, .polygon16, .polyline16, .polyBezierTo16,
             .polylineTo16, .polyPolyline16, .polyPolygon16,
             .pie, .chord, .setPixel, .patBlt:
            return false
        }
    }

    // MARK: - Helpers

    /// Window/viewport extents participate in the mapping only in the two
    /// arbitrary-unit modes.
    private var extentsApply: Bool {
        state.mapMode == .isotropic || state.mapMode == .anisotropic
    }

    /// Recomputes the page→device scale after a map-mode or extent change.
    /// A zero extent yields no valid scale: log and keep the previous one.
    private mutating func recomputeScale(log: inout EMFRenderLog) {
        if let scale = CoordinatePipeline.pageToDeviceScale(
            mapMode: state.mapMode,
            windowExt: state.windowExt,
            viewportExt: state.viewportExt,
            header: header
        ) {
            state.scale = scale
        } else {
            log.note(.zeroExtentMapping)
        }
    }

    // MARK: - Path bracket ([MS-EMF] §2.3.10)

    /// EMR_BEGINPATH: opens a fresh bracket. Per §2.3.10 path-bracket
    /// construction MUST NOT already be open; if it is, discard the in-progress
    /// path and start fresh (best-effort recovery) with a log entry.
    private mutating func beginPathBracket(log: inout EMFRenderLog) {
        if isRecordingPath {
            log.note(.nestedBeginPath)
        }
        pathAccumulator = CGMutablePath()
        pathSubpathStart = nil
    }

    /// EMR_ENDPATH: closes construction and selects the accumulated path as the
    /// current path. A stray ENDPATH with no open bracket leaves the existing
    /// `currentPath` untouched (rather than clobbering it with nil).
    private mutating func endPathBracket() {
        guard let accumulator = pathAccumulator else { return }
        currentPath = accumulator.copy()
        pathAccumulator = nil
        pathSubpathStart = nil
    }

    /// EMR_ABORTPATH ([MS-EMF] §2.3.10.1): discards any open path bracket and
    /// the closed-but-unconsumed `currentPath`, returning the DC to the
    /// no-path-selected state. A no-op when nothing is open or selected.
    private mutating func abortPath() {
        pathAccumulator = nil
        pathSubpathStart = nil
        currentPath = nil
    }

    /// EMR_CLOSEFIGURE ([MS-EMF] §2.3.10): closes the open figure by drawing a
    /// line back to its first point. A no-op outside a bracket or with no open
    /// subpath.
    private mutating func closeFigure() {
        guard isRecordingPath else { return }
        pathAccumulator?.closeSubpath()
        // After CLOSEFIGURE a following line/curve starts a NEW figure, so the
        // subpath start is cleared; the next append will re-seed it from the
        // current position.
        pathSubpathStart = nil
    }

    /// Starts a new subpath in the accumulator at `logicalPoint` (device space
    /// via the current transform). Used by EMR_MOVETOEX inside a bracket.
    private mutating func startSubpath(at logicalPoint: PointL) {
        let device = PathBuilder.cgPoint(logicalPoint).applying(resolvedTransform)
        pathAccumulator?.move(to: device)
        pathSubpathStart = device
    }

    /// Ensures a subpath is open before appending a line/curve inside a
    /// bracket, seeding it from the current position when a fresh figure is
    /// starting (GDI implicitly begins the figure at the current point). Runs
    /// `body` with the accumulator and the logical→device transform, then
    /// records the resulting current position.
    ///
    /// `body` appends geometry in DEVICE space and returns the point the
    /// current position should advance to (`nil` to leave it unchanged).
    mutating func appendToPath(
        seedFromCurrentPosition: Bool,
        _ body: (CGMutablePath, CGAffineTransform) -> PointL?
    ) {
        guard let accumulator = pathAccumulator else { return }
        if seedFromCurrentPosition, pathSubpathStart == nil {
            let device = PathBuilder.cgPoint(state.currentPosition).applying(resolvedTransform)
            accumulator.move(to: device)
            pathSubpathStart = device
        }
        if let advanced = body(accumulator, resolvedTransform) {
            state.currentPosition = advanced
        }
    }

    /// Appends a self-contained figure (its own move/close, e.g. a polygon,
    /// rectangle, or ellipse) to the accumulator in device space. These do NOT
    /// seed from or advance the current position.
    mutating func appendFigureToPath(_ body: (CGMutablePath, CGAffineTransform) -> Void) {
        guard let accumulator = pathAccumulator else { return }
        body(accumulator, resolvedTransform)
        // A closed figure ends any implicit open subpath; the next line/curve
        // re-seeds from the current position.
        pathSubpathStart = nil
    }

    /// Consumes and returns the current path (device space) for a fill/stroke
    /// closer, clearing it — [MS-EMF]/GDI: FillPath, StrokePath, and
    /// StrokeAndFillPath discard the DC's current path after use. Returns nil
    /// when there is no current path (a closer with nothing to draw).
    mutating func consumeCurrentPath() -> CGPath? {
        defer { currentPath = nil }
        return currentPath
    }

    /// Folds a still-open bracket into `currentPath` when a fill/stroke closer
    /// runs without an intervening EMR_ENDPATH. GDI's FillPath/StrokePath/
    /// StrokeAndFillPath implicitly close the path bracket, so this mirrors
    /// EMR_ENDPATH: snapshot the accumulator and end construction.
    mutating func foldOpenBracketIntoCurrentPath() {
        guard isRecordingPath else { return }
        currentPath = pathAccumulator?.copy()
        pathAccumulator = nil
        pathSubpathStart = nil
    }

    // MARK: - Clipping ([MS-EMF] §2.3.2)

    /// EMR_SELECTCLIPPATH ([MS-EMF] §2.3.2.5): combine the current path with the
    /// clip. The path is CONSUMED (GDI selects the path bracket into the clip
    /// and the path is no longer current). RGN_COPY replaces, RGN_AND
    /// intersects; RGN_OR/XOR/DIFF are logged and leave the clip unchanged.
    /// A missing current path is a logged skip.
    private mutating func applySelectClipPath(_ mode: RegionMode, log: inout EMFRenderLog) {
        guard let path = consumeCurrentPath() else {
            log.note(.noCurrentPath(record: 67))
            return
        }
        // The path's construction records fed a clip, not a drawing element:
        // the import classifies them as state, not passthrough geometry.
        observer?.consumePathForClip()
        switch mode {
        case .copy:
            state.clip.replace(with: .path(path))
        case .and:
            state.clip.intersect(.path(path))
        case .or, .xor, .diff:
            log.note(.unsupportedClipMode(record: 67, rawMode: Self.regionModeRaw(mode)))
        case .unknown(let raw):
            log.note(.unsupportedClipMode(record: 67, rawMode: raw))
        }
    }

    /// EMR_EXTSELECTCLIPRGN ([MS-EMF] §2.3.2.2). COORDINATE NOTE: the region
    /// data is specified "in logical units" by [MS-EMF] §2.3.2.2 (contrary to
    /// the common assumption that GDI region data is device-space) — so the
    /// RectL array is transformed to device space with the transform in effect,
    /// exactly like EMR_INTERSECTCLIPRECT. The reset form (RGN_COPY with no
    /// region data) clears to the default clip (whole canvas). RGN_COPY
    /// replaces, RGN_AND intersects; RGN_OR/XOR/DIFF are logged and unchanged.
    private mutating func applyExtSelectClipRgn(
        _ payload: ExtSelectClipRgnPayload,
        log: inout EMFRenderLog
    ) {
        // Reset form: RGN_COPY with no rectangles → default (no) clip.
        if payload.mode == .copy, payload.rects.isEmpty, payload.bounds == nil {
            state.clip = .none
            return
        }

        let transform = resolvedTransform
        let deviceRects = payload.rects.map { PathBuilder.cgRect($0).applying(transform) }

        switch payload.mode {
        case .copy:
            state.clip.replace(with: .rects(deviceRects))
        case .and:
            state.clip.intersect(.rects(deviceRects))
        case .or, .xor, .diff:
            log.note(.unsupportedClipMode(record: 75, rawMode: Self.regionModeRaw(payload.mode)))
        case .unknown(let raw):
            log.note(.unsupportedClipMode(record: 75, rawMode: raw))
        }
    }

    /// The on-disk RegionMode value for a defined mode (log reporting only).
    private static func regionModeRaw(_ mode: RegionMode) -> UInt32 {
        switch mode {
        case .and: 0x01
        case .or: 0x02
        case .xor: 0x03
        case .diff: 0x04
        case .copy: 0x05
        case .unknown(let raw): raw
        }
    }

    /// EMR_MODIFYWORLDTRANSFORM ([MS-EMF] §2.3.12.1). GDI composes transforms
    /// in row-vector convention (point × matrix), the same convention as
    /// CGAffineTransform, where `a.concatenating(b)` = matrix product a·b =
    /// "apply a, then b". Therefore:
    /// - MWT_LEFTMULTIPLY — new = record × current — applies the RECORD first:
    ///   `record.concatenating(current)`.
    /// - MWT_RIGHTMULTIPLY — new = current × record — applies the record last:
    ///   `current.concatenating(record)`.
    private mutating func applyModifyWorldTransform(
        _ payload: ModifyWorldTransformPayload,
        log: inout EMFRenderLog
    ) {
        switch payload.mode {
        case .identity:
            // The record's transform data MUST be ignored.
            state.world = .identity
        case .leftMultiply:
            state.world = CoordinatePipeline.affine(from: payload.transform)
                .concatenating(state.world)
        case .rightMultiply:
            state.world = state.world
                .concatenating(CoordinatePipeline.affine(from: payload.transform))
        case .set:
            state.world = CoordinatePipeline.affine(from: payload.transform)
        case .unknown(let raw):
            log.note(.unsupportedWorldTransformMode(rawMode: raw))
        }
    }

    /// EMR_RESTOREDC ([MS-EMF] §2.3.11.6): SavedDC MUST be negative and is
    /// relative — −1 is the most recently saved state, −2 the one before it.
    /// Restoring to −n discards the n popped states (GDI semantics). Anything
    /// not satisfiable — non-negative values, or |SavedDC| deeper than the
    /// stack — is a logged skip.
    private mutating func applyRestoreDC(_ savedDC: Int32, log: inout EMFRenderLog) {
        // Int(Int32) never traps on a 64-bit platform, so -Int(savedDC) is
        // overflow-safe even for Int32.min (§8: no unchecked arithmetic).
        let depth = -Int(savedDC)
        guard savedDC < 0, depth <= saveStack.count else {
            log.note(.restoreDCUnbalanced(savedDC: savedDC))
            return
        }
        state = saveStack[saveStack.count - depth]
        saveStack.removeLast(depth)
    }

    /// Stores a created object, enforcing the index rules: index 0 is
    /// reserved ([MS-EMF] §3.1.1.2), indices at or above the cap are ignored
    /// (primer §8). Re-creating an occupied index overwrites it — real
    /// emitters recycle freed slots, and last-wins matches the table's role
    /// as a lookup, not an allocator.
    private mutating func store(
        _ object: TableObject,
        at index: UInt32,
        log: inout EMFRenderLog
    ) {
        guard index != 0 else {
            log.note(.invalidObjectIndex(index: index))
            return
        }
        guard index < Self.objectIndexCap else {
            log.note(.objectTableFull(index: index))
            return
        }
        objects[index] = object
    }

    /// EMR_SELECTOBJECT ([MS-EMF] §2.3.8.5): copy the object's RESOLVED VALUE
    /// into the DC. Absent/absurd table indices and unsupported stock objects
    /// keep the current selection with a log entry.
    private mutating func applySelectObject(_ handle: ObjectHandle, log: inout EMFRenderLog) {
        switch handle {
        case .table(let index):
            switch objects[index] {
            case .pen(let pen):
                state.pen = pen
            case .brush(let brush):
                state.brush = brush
            case .font(let font):
                state.font = font
            case nil:
                log.note(.invalidObjectIndex(index: index))
            }
        case .stock(let stock):
            switch StockObjects.resolve(stock) {
            case .pen(let pen):
                state.pen = pen
            case .brush(let brush):
                state.brush = brush
            case .font(let font, let raw):
                state.font = font
                log.noteStockFontUsed(rawValue: raw)
            case .unsupported(let raw):
                log.note(.unsupportedStockObject(rawValue: raw))
            }
        }
    }

    /// EMR_DELETEOBJECT ([MS-EMF] §2.3.8.3): frees a table slot. The current
    /// selections are untouched — they hold copies, so deleting a selected
    /// handle keeps drawing with the copy. Naming a stock object is forbidden
    /// by the spec and is a logged skip.
    private mutating func applyDeleteObject(_ handle: ObjectHandle, log: inout EMFRenderLog) {
        switch handle {
        case .table(let index):
            if objects.removeValue(forKey: index) == nil {
                log.note(.invalidObjectIndex(index: index))
            }
        case .stock(let stock):
            log.note(.unsupportedStockObject(rawValue: Self.rawStockValue(stock)))
        }
    }

    // MARK: - Partial-playback checkpoints (F5)

    /// A full snapshot of the playback DC taken at a safe boundary, so the
    /// step-through replay can resume playback from a cached raster without
    /// re-interpreting every earlier record. It captures the three pieces that
    /// survive a record boundary: the saveable `State`, the object table, and
    /// the SaveDC stack. Transient path-bracket construction is NOT captured —
    /// checkpoints are only taken where `isAtCleanPathBoundary` is true, so
    /// there is nothing in flight to restore.
    struct Checkpoint {
        var state: State
        var objects: [UInt32: TableObject]
        var saveStack: [State]
    }

    /// True when no path bracket is open (EMR_BEGINPATH … EMR_ENDPATH) and no
    /// closed-but-unconsumed path is pending — the only boundaries a checkpoint
    /// may be taken at, since `Checkpoint` carries no path-bracket state.
    var isAtCleanPathBoundary: Bool {
        pathAccumulator == nil && currentPath == nil && pathSubpathStart == nil
    }

    /// Captures the full resumable DC state at the current record boundary.
    func checkpoint() -> Checkpoint {
        Checkpoint(state: state, objects: objects, saveStack: saveStack)
    }

    /// Restores a checkpoint, discarding any in-flight path-bracket state (there
    /// is none to keep — checkpoints are only taken at a clean boundary).
    mutating func restore(_ checkpoint: Checkpoint) {
        state = checkpoint.state
        objects = checkpoint.objects
        saveStack = checkpoint.saveStack
        pathAccumulator = nil
        pathSubpathStart = nil
        currentPath = nil
    }

    /// The number of SaveDC states currently stacked — for the inspector's DC
    /// panel.
    var saveDepth: Int { saveStack.count }

    /// The number of live object-table entries — for the inspector's DC panel.
    var objectCount: Int { objects.count }

    /// The on-disk 0x8000_00xx value for a defined stock object (log
    /// reporting only).
    private static func rawStockValue(_ stock: StockObject) -> UInt32 {
        switch stock {
        case .whiteBrush: 0x8000_0000
        case .ltGrayBrush: 0x8000_0001
        case .grayBrush: 0x8000_0002
        case .dkGrayBrush: 0x8000_0003
        case .blackBrush: 0x8000_0004
        case .nullBrush: 0x8000_0005
        case .whitePen: 0x8000_0006
        case .blackPen: 0x8000_0007
        case .nullPen: 0x8000_0008
        case .oemFixedFont: 0x8000_000A
        case .ansiFixedFont: 0x8000_000B
        case .ansiVarFont: 0x8000_000C
        case .systemFont: 0x8000_000D
        case .deviceDefaultFont: 0x8000_000E
        case .defaultPalette: 0x8000_000F
        case .systemFixedFont: 0x8000_0010
        case .defaultGuiFont: 0x8000_0011
        case .dcBrush: 0x8000_0012
        case .dcPen: 0x8000_0013
        case .unknownStock(let raw): raw
        }
    }
}
