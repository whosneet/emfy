import CoreGraphics
import CoreText
import EMFParse
import Foundation

// MARK: - Playback observation (E1 scene import)
//
// The editor must not reinterpret GDI/WMF/EMF+ a second time (CLAUDE.md "one
// interpreter"). Instead, EMFRender's existing playback — the only DC
// interpreter — reports each RESOLVED drawing operation to an optional
// observer. The observer is nil on every normal render, so the hot path and
// every committed snapshot are byte-for-byte unchanged; only an import attaches
// one. All capture work is gated behind `dc.observer != nil`.
//
// Geometry is reported in the file's DEVICE space (y-down, header rclBounds
// coordinates) — the stable space EMF/WMF records are authored in and the space
// the scene stores. The device→target fit and the single y-flip are applied
// later, once, by whoever draws the scene.

/// A single resolved drawing operation lifted from playback. One op corresponds
/// to one editable scene element (a rectangle, a text run, an image, a filled
/// path, …). It is `@unchecked Sendable` for the same reason `ResolvedFont` is:
/// its only reference-type members are immutable CoreGraphics/CoreText objects
/// (`CGPath`, `CTFont`) that are safe to read from any thread once built.
public struct ResolvedDrawOp: @unchecked Sendable {

    /// Which logical primitive produced this op. `path` is a path-bracket
    /// fill/stroke whose logical shape is only known as the accumulated device
    /// geometry.
    public enum Kind: Sendable, Equatable {
        case rectangle, ellipse, roundRect
        case polygon, polyline, line
        case arc, pie, chord, bezier
        case polyPolygon, polyPolyline
        case path
        case text, image
        /// A drawn record v1 does not lift to an editable element (SETPIXEL,
        /// PATBLT, a glyph-index text run): kept as passthrough but captured so
        /// it still replays pixel-faithfully.
        case passthrough
    }

    /// The source record indices this op was drawn from, ascending. For a plain
    /// shape this is one index; for a path bracket it spans BEGINPATH … the
    /// closer. EMF: indices into `EMFFile.records` (0 = EMR_HEADER). WMF:
    /// indices into the translated `WMFRenderProgram.payloads`.
    public let recordIndices: [Int]
    public let kind: Kind
    /// Resolved geometry in DEVICE space (y-down). For text/image this is the
    /// device-space bounds the primitive occupies (empty if unknown).
    public let deviceGeometry: CGPath
    /// The logical→device transform in effect (world × map-mode × origins).
    public let deviceTransform: CGAffineTransform
    /// The current clip in DEVICE space, or nil for the whole canvas.
    public let clipDeviceGeometry: CGPath?

    /// Solid fill colour, or nil when the brush is NULL / the primitive is not
    /// filled. v1 lifts solid fills only; hatch/pattern/gradient brushes that
    /// EMFRender already approximates as solid are lifted as that solid colour.
    public let fillColor: ColorRef?
    /// Even-odd (ALTERNATE) vs winding fill for a filled primitive.
    public let fillIsEvenOdd: Bool
    /// Resolved stroke, or nil when the pen is NULL / the primitive is not
    /// stroked.
    public let stroke: LiftedStroke?
    /// Lifted text, present only for `.text`.
    public let text: LiftedText?
    /// Lifted image, present only for `.image`.
    public let image: LiftedImage?

    // Replay internals (EMFRender-only): replaying an op re-runs the ORIGINAL
    // draw with the captured state, so a lifted element renders pixel-identical
    // to the source. Not exposed — the scene stores value types, not these.
    let replayState: DeviceContext.State
    let replayHeader: EMFHeader
    /// The original payload for a non-path op; nil for a path closer (whose
    /// geometry is `deviceGeometry`).
    let replayPayload: EMFRecordPayload?
}

/// Which playback engine drew a metafile, so the import knows how to interpret
/// `ResolvedDrawOp.recordIndices` and whether EMF+ content stays passthrough.
public enum RenderPathTaken: Sendable, Equatable {
    /// GDI playback. Indices are into `EMFFile.records` (0 = EMR_HEADER).
    case gdi
    /// WMF record playback. Indices are into the translated program's payloads.
    case wmf
    /// EMF+ drove output: v1 lifts nothing here (the file is passthrough).
    case emfPlus
}

/// A coarse record-partition bucket for one playback unit, classified from the
/// decoded payload type (NOT a second DC interpretation — no transform/object
/// state is computed). The importer uses it only for records that produced no
/// draw op and are not path construction.
public enum UnitRole: Sendable, Equatable {
    /// EMR_HEADER / EMR_EOF — structure, not an element.
    case structural
    /// DC state, object management, transforms, clipping, path brackets.
    case state
    /// A geometry/text/image/direct-draw record (it either produced an op or,
    /// in EMF+ mode, was a fallback that did not execute → passthrough).
    case drawing
    /// EMR_COMMENT — passthrough (carries EMF+ or private data).
    case comment
    /// Unimplemented or malformed — passthrough.
    case unknown
    /// A GDI record present in an EMF+ file but NOT executed by EMF+ playback —
    /// the GDI FALLBACK of a dual file (outside any GetDC window), or any GDI
    /// record the EMF+ engine skipped. It becomes no scene element: the E1b
    /// exporter regenerates the GDI fallback from the edited scene, so a lifted
    /// EMF+ file accounts for these records without double-drawing them.
    case fallback
}

/// The result of observing a prepared metafile's playback: the resolved ops and
/// the record partition inputs the importer needs.
public struct PlaybackObservation: @unchecked Sendable {
    /// The resolved drawing operations, in playback order.
    public let ops: [ResolvedDrawOp]
    /// Path-construction records that fed a clip or were never painted (state).
    public let pathConstructionIndices: Set<Int>
    /// Which engine drew.
    public let renderPath: RenderPathTaken
    /// The number of playback units: `EMFFile.records.count` for GDI/EMF+, or
    /// `WMFRenderProgram.payloads.count` for WMF — the partition's universe.
    public let unitCount: Int
    /// Per-unit coarse role, indexed like the playback units. Count == `unitCount`.
    public let unitRoles: [UnitRole]
    /// Per-unit record-type id (EMF `iType`; a WMF-translated unit's id is the
    /// EMR type for an un-decoded record, else 0). For passthrough reporting.
    public let unitTypes: [UInt32]
    /// EMF+ playback only: the lifted drawing entries in playback (z) order — one
    /// per EMF+ drawing record played, plus any GDI draw played inside a GetDC
    /// window. Empty for GDI/WMF (`ops` carries those). The importer builds one
    /// element per entry, in this order.
    public let plusEntries: [PlusEntry]

    public init(ops: [ResolvedDrawOp], pathConstructionIndices: Set<Int>, renderPath: RenderPathTaken, unitCount: Int, unitRoles: [UnitRole], unitTypes: [UInt32], plusEntries: [PlusEntry] = []) {
        self.ops = ops
        self.pathConstructionIndices = pathConstructionIndices
        self.renderPath = renderPath
        self.unitCount = unitCount
        self.unitRoles = unitRoles
        self.unitTypes = unitTypes
        self.plusEntries = plusEntries
    }
}

// MARK: - EMF+ lifted content (E1 scene import, slice E1a2)
//
// EMF+ drawing records lift into their own value types because the GDI
// `ResolvedDrawOp` is LOGFONT/ColorRef/DIB-centric: EMF+ carries ARGB with
// alpha, gradients, EMF+ fonts (family + emSize + unit), and image OBJECTS.
// Geometry is captured in DEVICE space (world→page applied), the stable space
// the scene stores; the scene renderer applies the device→target fit later.

/// The fill of a lifted EMF+ drawing op the scene can represent faithfully:
/// a solid ARGB colour, or a linear gradient. Hatch / path-gradient / texture
/// brushes are NOT represented here — their ops lift as passthrough.
public enum PlusFill: Sendable, Equatable {
    case solid(EMFPlusARGB)
    case linearGradient(PlusGradient)
}

/// A lifted EMF+ linear gradient ([MS-EMFPLUS] §2.2.2.24): colour stops and the
/// gradient axis, the axis endpoints already in DEVICE space (the brush
/// transform and world→device folded in at capture), so the scene renderer only
/// applies the device→target fit.
public struct PlusGradient: Sendable, Equatable {
    public struct Stop: Sendable, Equatable {
        public let location: Double
        public let color: EMFPlusARGB
        public init(location: Double, color: EMFPlusARGB) {
            self.location = location
            self.color = color
        }
    }
    public let stops: [Stop]
    public let startDevice: CGPoint
    public let endDevice: CGPoint
    /// WrapMode is a tiling mode ([MS-EMFPLUS] §2.1.1.33) rather than Clamp — the
    /// render clamps to the axis, so this only flags the approximation for E1b.
    public let tilesWrap: Bool

    public init(stops: [Stop], startDevice: CGPoint, endDevice: CGPoint, tilesWrap: Bool) {
        self.stops = stops
        self.startDevice = startDevice
        self.endDevice = endDevice
        self.tilesWrap = tilesWrap
    }
}

/// A lifted EMF+ pen ([MS-EMFPLUS] §2.2.1.7). Colour is the resolved solid (a
/// non-solid pen brush is approximated to its representative colour, exactly as
/// playback does). Width is in the pen's world units; the device width is
/// derived at draw time from the element transform, matching `EMFPlusPaint`.
public struct PlusStroke: Sendable, Equatable {
    public let color: EMFPlusARGB
    public let width: Double
    public let dash: LiftedStroke.Dash
    public let cap: CGLineCap
    public let join: CGLineJoin
    public let miterLimit: Double

    public init(color: EMFPlusARGB, width: Double, dash: LiftedStroke.Dash, cap: CGLineCap, join: CGLineJoin, miterLimit: Double) {
        self.color = color
        self.width = width
        self.dash = dash
        self.cap = cap
        self.join = join
        self.miterLimit = miterLimit
    }
}

/// A lifted EMF+ text run ([MS-EMFPLUS] §2.3.4.14 EmfPlusDrawString). The font is
/// an EmfPlusFont (family + emSize + unit + style flags), carried alongside the
/// RESOLVED macOS family so the exporter can re-emit the requested one.
public struct PlusText: Sendable, Equatable {
    public let string: String
    /// The EMF+ font's requested family name.
    public let requestedFamily: String
    /// The resolved macOS family (CTFontCopyFamilyName).
    public let resolvedFamily: String
    public let emSize: Double
    /// [MS-EMFPLUS] §2.1.1.32 UnitType of `emSize`.
    public let sizeUnit: UInt32
    public let bold: Bool
    public let italic: Bool
    public let underline: Bool
    public let strikeOut: Bool
    public let color: EMFPlusARGB
    /// The layout rectangle mapped to DEVICE space.
    public let layoutRectDevice: CGRect
    /// The layout rectangle in WORLD (pre-`worldToDevice`) space — the record's own
    /// LayoutRect before mapping. An editor keeps this so a center/far-aligned or
    /// wrapped run re-emits with its real extent through the element transform
    /// ([MS-EMFPLUS] §2.3.4.14).
    public let layoutRectWorld: CGRect
    /// StringFormat essentials ([MS-EMFPLUS] §2.2.1.9), 0 when no format object.
    public let stringAlignment: UInt32
    public let lineAlignment: UInt32
    public let stringFormatFlags: UInt32

    public init(string: String, requestedFamily: String, resolvedFamily: String, emSize: Double, sizeUnit: UInt32, bold: Bool, italic: Bool, underline: Bool, strikeOut: Bool, color: EMFPlusARGB, layoutRectDevice: CGRect, layoutRectWorld: CGRect, stringAlignment: UInt32, lineAlignment: UInt32, stringFormatFlags: UInt32) {
        self.string = string
        self.requestedFamily = requestedFamily
        self.resolvedFamily = resolvedFamily
        self.emSize = emSize
        self.sizeUnit = sizeUnit
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikeOut = strikeOut
        self.color = color
        self.layoutRectDevice = layoutRectDevice
        self.layoutRectWorld = layoutRectWorld
        self.stringAlignment = stringAlignment
        self.lineAlignment = lineAlignment
        self.stringFormatFlags = stringFormatFlags
    }
}

/// A lifted EMF+ image draw ([MS-EMFPLUS] §2.3.4.8/.9). Carries the decoded
/// EMF+ image OBJECT (its raw bitmap/metafile bytes within) so E1b can re-encode
/// it, plus the destination in DEVICE space.
public struct PlusImage: Sendable, Equatable {
    public let image: EMFPlusImage
    /// The source rectangle in the image's own units (SrcRect, [MS-EMFPLUS]
    /// §2.3.4.8) — the crop the dest is filled from.
    public let srcRect: CGRect
    /// SrcUnit ([MS-EMFPLUS] §2.1.1.32), normally Pixel.
    public let srcUnit: Int32
    public let destRectDevice: CGRect
    /// The device-space destination PARALLELOGRAM (upper-left, upper-right,
    /// lower-right, lower-left) for an EmfPlusDrawImagePoints draw (§2.3.4.9); nil
    /// for an axis-aligned EmfPlusDrawImage. `destRectDevice` is its bounding box.
    /// Carried so an editor re-emits the exact placement rather than its box.
    public let destCornersDevice: [CGPoint]?

    public init(image: EMFPlusImage, srcRect: CGRect, srcUnit: Int32, destRectDevice: CGRect, destCornersDevice: [CGPoint]? = nil) {
        self.image = image
        self.srcRect = srcRect
        self.srcUnit = srcUnit
        self.destRectDevice = destRectDevice
        self.destCornersDevice = destCornersDevice
    }
}

/// Why a drawing record lifted as a `passthrough` op rather than an editable one.
public enum PlusPassthroughKind: Sendable, Equatable {
    /// EmfPlusClear — a full-surface fill.
    case clear
    /// EmfPlusDrawDriverString — a glyph-index/positioned run.
    case driverString
    /// A fill brush (hatch/path-gradient/texture) or a pen the scene cannot
    /// reproduce exactly, or a missing paint object.
    case unsupportedBrush
    /// An undecodable record body or a missing referenced object.
    case undecodable
    /// Any other drawing record the scene cannot lift editably.
    case unsupportedRecord
}

/// A single resolved EMF+ drawing operation lifted from playback. `@unchecked
/// Sendable` for the same reason `ResolvedDrawOp` is: its only reference members
/// are immutable CoreGraphics objects safe to read from any thread once built.
public struct PlusDrawOp: @unchecked Sendable {
    /// The logical primitive, or `passthrough` for a drawing record the scene
    /// cannot represent faithfully (Clear, glyph-index driver string, an
    /// unsupported brush, an undecodable body) — kept, replayed, never dropped.
    public enum Kind: Sendable, Equatable {
        case rectangle, ellipse, polygon, polyline, line, pie, arc, path, bezier, curve
        case text, image, passthrough
    }
    public let kind: Kind
    /// The EMF+ record type ([MS-EMFPLUS] §2.1.1.1).
    public let recordType: UInt16
    /// The `EMFFile.records` index of the EMR_COMMENT container the EMF+ record's
    /// header starts in — the op's provenance for the record partition.
    public let commentRecordIndex: Int
    /// The index into `EMFPlusStream.records` — the scene renderer replays a
    /// text/image/passthrough op by re-running the file drawing ONLY this index.
    public let streamIndex: Int
    /// Resolved geometry in DEVICE space (world→page applied). For text/image the
    /// device-space footprint (the layout/destination rect).
    public let deviceGeometry: CGPath
    /// The world→device transform in effect (EMF+ world × page).
    public let worldToDevice: CGAffineTransform
    /// The current clip in DEVICE space, or nil for the whole canvas.
    public let clipDeviceGeometry: CGPath?
    public let fill: PlusFill?
    /// Even-odd (Alternate) vs winding fill rule for a filled op.
    public let fillEvenOdd: Bool
    public let stroke: PlusStroke?
    public let text: PlusText?
    public let image: PlusImage?
    /// Set only when `kind == .passthrough`, so the importer carries a precise
    /// reason code.
    public let passthroughReason: PlusPassthroughKind?

    public init(kind: Kind, recordType: UInt16, commentRecordIndex: Int, streamIndex: Int, deviceGeometry: CGPath, worldToDevice: CGAffineTransform, clipDeviceGeometry: CGPath?, fill: PlusFill? = nil, fillEvenOdd: Bool = true, stroke: PlusStroke? = nil, text: PlusText? = nil, image: PlusImage? = nil, passthroughReason: PlusPassthroughKind? = nil) {
        self.kind = kind
        self.recordType = recordType
        self.commentRecordIndex = commentRecordIndex
        self.streamIndex = streamIndex
        self.deviceGeometry = deviceGeometry
        self.worldToDevice = worldToDevice
        self.clipDeviceGeometry = clipDeviceGeometry
        self.fill = fill
        self.fillEvenOdd = fillEvenOdd
        self.stroke = stroke
        self.text = text
        self.image = image
        self.passthroughReason = passthroughReason
    }
}

/// One lifted EMF+ playback entry: an EMF+ drawing op, or a GDI op drawn inside a
/// GetDC window (which becomes an ordinary GDI element).
public enum PlusEntry: @unchecked Sendable {
    case gdi(ResolvedDrawOp)
    case plus(PlusDrawOp)
}

/// A resolved stroke in a scene-friendly value form (no CoreText/CoreGraphics
/// reference members). Widths and dash lengths are the pen's own logical/device
/// units; the final device width is computed when drawn, exactly as EMFRender
/// does, from `deviceTransform`.
public struct LiftedStroke: Sendable, Equatable {
    /// How the dash lengths are generated.
    public enum Dash: Sendable, Equatable {
        case solid
        case dash, dot, dashDot, dashDotDot
        /// PS_USERSTYLE absolute lengths ([MS-EMF] §2.2.20).
        case userStyle([UInt32])
    }
    public let color: ColorRef
    /// One device pixel wide regardless of the transform (PS_COSMETIC/width 0).
    public let isCosmetic: Bool
    /// Width in logical units; meaningful only when `isCosmetic` is false.
    public let width: Double
    public let dash: Dash
    public let cap: CGLineCap
    public let join: CGLineJoin
    /// Spec-literal unsigned miter limit ([MS-EMF] §2.3.11.21).
    public let miterLimit: UInt32
}

/// A lifted text run. Font family is the RESOLVED (post-substitution) macOS
/// family; logical height is carried unscaled so the scene is transform- and
/// resolution-independent, matching `ResolvedFont`.
public struct LiftedText: Sendable, Equatable {
    public let string: String
    /// Resolved font family (CTFontCopyFamilyName of the selected font).
    public let fontFamily: String
    /// The ORIGINAL requested face name (LOGFONT faceName) before substitution, so
    /// the exporter re-emits the font the file asked for (E1b). Empty for a stock
    /// font selection.
    public let requestedFamily: String
    /// Signed logical character/cell height (§2.2.13): < 0 em, > 0 cell, 0 default.
    public let logicalHeight: Int32
    public let bold: Bool
    public let italic: Bool
    public let underline: Bool
    public let strikeOut: Bool
    /// lfEscapement, tenths of a degree counterclockwise ([MS-EMF] §2.2.13).
    public let escapementTenths: Int32
    public let color: ColorRef
    /// The reference point in LOGICAL units (EmrText.Reference, or the current
    /// position under TA_UPDATECP).
    public let referenceLogical: PointL
    /// Text-alignment mask ([MS-EMF] §2.3.11.25).
    public let alignRawValue: UInt32
    /// The EmrText intercharacter-spacing array in LOGICAL units (one entry per
    /// UTF-16 code unit, [MS-EMF] §2.2.5): the exact per-glyph advances the file
    /// positioned the run with. Empty when the run carried none or used ETO_PDY
    /// (x/y pairs) — then the font's natural advances are used. Kept so an editor
    /// re-emits the condensed/expanded spacing Office and Visio bake into runs.
    public let advancesLogical: [UInt32]

    public init(string: String, fontFamily: String, requestedFamily: String, logicalHeight: Int32, bold: Bool, italic: Bool, underline: Bool, strikeOut: Bool, escapementTenths: Int32, color: ColorRef, referenceLogical: PointL, alignRawValue: UInt32, advancesLogical: [UInt32] = []) {
        self.string = string
        self.fontFamily = fontFamily
        self.requestedFamily = requestedFamily
        self.logicalHeight = logicalHeight
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikeOut = strikeOut
        self.escapementTenths = escapementTenths
        self.color = color
        self.referenceLogical = referenceLogical
        self.alignRawValue = alignRawValue
        self.advancesLogical = advancesLogical
    }
}

/// A lifted image draw. The source DIB bytes are carried so E1b can re-encode
/// them (as compressed PNG, per the E0 owner decision); the destination is in
/// LOGICAL units (mapped to device by `deviceTransform`).
public struct LiftedImage: Sendable, Equatable {
    /// Destination origin and size in LOGICAL units.
    public let destOrigin: PointL
    public let destSize: SizeL
    /// The source DIB, when one was present (nil for a sourceless rop fill).
    public let sourceDIB: DIB?
}

// MARK: - The observer sink

/// The accumulator EMFRender writes resolved drawing operations into during an
/// import. A `final class` so the value-type `DeviceContext` can carry a shared
/// reference without `inout` threading through every draw helper; writing is
/// internal, reading is public (the importer consumes `draws`).
public final class RenderObserver {

    /// Hard cap on captured ops — a hostile file with millions of tiny draws
    /// must not exhaust memory during import (§8). Past the cap, further draws
    /// are counted but not stored.
    public static let maxDraws = 2_000_000

    /// The resolved drawing operations, in playback order.
    public internal(set) var draws: [ResolvedDrawOp] = []
    /// How many draws were produced in total (including any dropped past the cap).
    public internal(set) var drawCount = 0
    /// Record indices consumed into a path bracket that fed a CLIP or was never
    /// painted — i.e. path-construction records that belong to no drawing
    /// element. The importer classifies these as state.
    public internal(set) var pathConstructionIndices: Set<Int> = []

    // MARK: EMF+ capture (slice E1a2)

    /// True during EMF+ playback: captured GDI ops (GetDC windows) are ALSO
    /// recorded into `plusEntries` so their playback order is preserved relative
    /// to the EMF+ ops. False on the pure-GDI loop, which consumes `draws`.
    var plusMode = false
    /// The lifted EMF+ playback entries in z-order (EMF+ ops and GetDC GDI ops).
    public internal(set) var plusEntries: [PlusEntry] = []
    /// `EMFFile.records` indices of GDI records the EMF+ walk did NOT play (the
    /// dual-file GDI fallback). The observe step turns these into `.fallback`
    /// roles so the importer keeps them out of the element list.
    public internal(set) var emfPlusFallbackGDI: Set<Int> = []

    public init() {}

    // The index of the record currently being played; set by the playback loop
    // before each record so draw helpers can stamp provenance.
    var currentRecordIndex = 0
    // Indices of an open path bracket (BEGINPATH … not yet ENDPATH).
    private var openBracketIndices: [Int]?
    // Indices of a closed-but-unconsumed path (after ENDPATH, before a closer or
    // SELECTCLIPPATH consumes it).
    private var pendingPathIndices: [Int] = []

    func append(_ op: ResolvedDrawOp) {
        drawCount += 1
        guard draws.count < Self.maxDraws else { return }
        draws.append(op)
        // In EMF+ mode, a GetDC-window GDI draw joins the unified z-ordered list.
        if plusMode, plusEntries.count < Self.maxDraws { plusEntries.append(.gdi(op)) }
    }

    /// Records one lifted EMF+ drawing op into the unified z-ordered list.
    func appendPlus(_ op: PlusDrawOp) {
        drawCount += 1
        guard plusEntries.count < Self.maxDraws else { return }
        plusEntries.append(.plus(op))
    }

    /// Notes a GDI record the EMF+ walk encountered with no GetDC window open —
    /// the GDI fallback, kept out of the scene element list.
    func noteFallbackGDI(_ index: Int) { emfPlusFallbackGDI.insert(index) }

    // MARK: Path-bracket bookkeeping

    func beginBracket() { openBracketIndices = [currentRecordIndex] }
    func noteBracketRecord() {
        if openBracketIndices != nil { openBracketIndices?.append(currentRecordIndex) }
    }
    func endBracket() {
        var indices = openBracketIndices ?? []
        indices.append(currentRecordIndex)
        pendingPathIndices = indices
        openBracketIndices = nil
    }

    /// Provenance for a path closer: the construction records plus the closer,
    /// de-duplicated and sorted. Clears the pending/open path.
    func consumePathForDraw() -> [Int] {
        var indices = Set(pendingPathIndices)
        if let open = openBracketIndices { indices.formUnion(open) }   // fold: no ENDPATH
        indices.insert(currentRecordIndex)
        pendingPathIndices = []
        openBracketIndices = nil
        return indices.sorted()
    }

    /// EMR_ABORTPATH discarded the bracket: its construction records drew
    /// nothing, so — like a clip-consumed path — they are folded into state.
    func abortBracket() {
        pathConstructionIndices.formUnion(pendingPathIndices)
        if let open = openBracketIndices { pathConstructionIndices.formUnion(open) }
        pathConstructionIndices.insert(currentRecordIndex)
        pendingPathIndices = []
        openBracketIndices = nil
    }

    /// A SELECTCLIPPATH consumed the path: its construction records are state.
    func consumePathForClip() {
        pathConstructionIndices.formUnion(pendingPathIndices)
        if let open = openBracketIndices { pathConstructionIndices.formUnion(open) }
        pathConstructionIndices.insert(currentRecordIndex)
        pendingPathIndices = []
        openBracketIndices = nil
    }

    /// Fold any unconsumed path construction into the state set (end of playback).
    func finalize() {
        pathConstructionIndices.formUnion(pendingPathIndices)
        if let open = openBracketIndices { pathConstructionIndices.formUnion(open) }
        pendingPathIndices = []
        openBracketIndices = nil
    }
}
