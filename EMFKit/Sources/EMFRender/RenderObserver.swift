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

    public init(ops: [ResolvedDrawOp], pathConstructionIndices: Set<Int>, renderPath: RenderPathTaken, unitCount: Int, unitRoles: [UnitRole], unitTypes: [UInt32]) {
        self.ops = ops
        self.pathConstructionIndices = pathConstructionIndices
        self.renderPath = renderPath
        self.unitCount = unitCount
        self.unitRoles = unitRoles
        self.unitTypes = unitTypes
    }
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
    }

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
