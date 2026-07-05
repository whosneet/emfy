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
        /// Current position in LOGICAL units — mapped through whatever the
        /// transform is at consumption time, exactly as GDI stores it.
        var currentPosition = PointL(x: 0, y: 0)
        /// Selected pen — a resolved VALUE (see RenderObjects.swift), default
        /// BLACK_PEN.
        var pen: ResolvedPen = .cosmetic(StockObjects.black)
        /// Selected brush — a resolved value, default WHITE_BRUSH.
        var brush: ResolvedBrush = .solid(StockObjects.white)
        /// The last VALID page→device scale (default: MM_TEXT's 1:1). A state
        /// record that would produce a zero-extent mapping logs and leaves
        /// this untouched — "keep the previous valid mapping".
        var scale = CoordinatePipeline.Scale(sx: 1, sy: 1)
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

    init(header: EMFHeader) {
        self.header = header
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
            // painting, which arrives with EMR_SETBKCOLOR in phase 4.
            state.bkMode = mode
            return true

        case .setPolyFillMode(let mode):
            // Unknown values keep the current mode (hostile-input fallback;
            // both defined values are handled).
            if case .unknown = mode { return true }
            state.polyFillMode = mode
            return true

        case .setROP2(let rawMode):
            state.rop2Raw = rawMode
            if rawMode != Self.rop2CopyPen {
                log.note(.unsupportedROP2(rawMode: rawMode))
            }
            return true

        case .setMiterLimit(let miterLimit):
            state.miterLimit = miterLimit
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
            return true

        case .intersectClipRect:
            // Decoded but deferred to phase 3; rendering continues unclipped.
            log.note(.clipDeferred)
            return true

        // MARK: Path brackets and clipping (decoded phase 3; playback is Task B)
        // Task A decodes these payloads; the renderer does not yet build path
        // brackets or apply clipping. Until Task B, they are consumed here as
        // deferred — rendering continues, geometry inside a bracket still draws
        // immediately (its own drawing arm), matching the phase-2 behaviour of
        // EMR_INTERSECTCLIPRECT above. No path is built and no clip is set.
        case .beginPath, .endPath, .closeFigure,
             .fillPath, .strokeAndFillPath, .strokePath,
             .selectClipPath, .extSelectClipRgn:
            log.note(.clipDeferred)
            return true

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

        // MARK: Fallback verdicts
        case .unimplemented(let type):
            log.noteUnimplemented(type: type)
            return true

        case .malformed(let type, _):
            log.note(.malformedRecord(type: type))
            return true

        // MARK: Drawing records — the renderer's job
        case .polyBezier, .polygon, .polyline, .polyBezierTo, .polylineTo,
             .ellipse, .rectangle, .roundRect, .arc, .lineTo,
             .polyBezier16, .polygon16, .polyline16, .polyBezierTo16,
             .polylineTo16, .polyPolyline16, .polyPolygon16:
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
            case nil:
                log.note(.invalidObjectIndex(index: index))
            }
        case .stock(let stock):
            switch StockObjects.resolve(stock) {
            case .pen(let pen):
                state.pen = pen
            case .brush(let brush):
                state.brush = brush
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
