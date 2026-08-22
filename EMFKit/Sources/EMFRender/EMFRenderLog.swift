import EMFParse
import Foundation

/// An EMF+ feature the playback renders APPROXIMATELY rather than exactly
/// (primer §8: best partial output plus an honest note). One case per
/// approximation the playback ships, so a viewer can tell precisely what was
/// simplified. Value-comparable and `Hashable` (used as a coalescing key).
public enum EMFPlusApproximation: Sendable, Equatable, Hashable {
    /// A hatch brush was rendered as a solid fill of its foreground colour.
    case hatchBrush
    /// A path-gradient brush was rendered as a flat fill of its centre colour.
    case pathGradientBrush
    /// A texture brush's fill was skipped — its bitmap pattern is not rendered;
    /// a representative solid colour is used wherever one is needed instead.
    case textureBrush
    /// A pen whose brush is not solid (gradient/hatch/texture) was stroked
    /// with a representative solid colour.
    case penNonSolidBrush
    /// A pen line cap outside flat/square/round (triangle or an anchor/custom
    /// cap) was drawn with a round cap.
    case penCap
    /// A clip CombineMode CoreGraphics cannot express (Union/XOR/Exclude/
    /// Complement) was applied as an intersection (best effort).
    case clipCombineMode
    /// A region combine node other than a plain union was resolved as a union
    /// of its two children (best-effort "render more").
    case regionCombine
    /// An EmfPlusOffsetClip was left unapplied (the clip was kept as-is).
    case offsetClip
    /// A page unit other than pixel was treated as pixels (no DPI conversion).
    case pageUnit
    /// A compositing mode other than SourceOver was kept as SourceOver.
    case compositingMode
    /// A graphics-state container was approximated by a save/restore of the
    /// full graphics state (with the container's rect transform applied).
    case container
    /// A linear-gradient brush used a tiling wrap mode ([MS-EMFPLUS] §2.1.1.33
    /// Tile/TileFlipX/TileFlipY/TileFlipXY); the fill clamps to the gradient
    /// axis instead of repeating the pattern beyond it.
    case linearGradientWrapMode
    /// A linear-gradient brush set BrushDataIsGammaCorrected ([MS-EMFPLUS]
    /// §2.2.2.24, flag 0x80); gamma-corrected interpolation is not reproduced —
    /// the ramp is interpolated linearly instead.
    case gradientGamma
    /// A DrawCurve requested a partial segment range — a non-zero Offset or a
    /// NumSegments short of the whole spline ([MS-EMFPLUS] §2.3.4.5); the entire
    /// open cardinal spline was drawn instead.
    case curveSegmentRange
    /// A DrawImage/DrawImagePoints referenced a bitmap whose PixelFormat
    /// ([MS-EMFPLUS] §2.1.1.24) is outside the supported set (16bpp, indexed,
    /// PARGB, 48/64bpp); the image was not drawn. Carries the raw format value.
    case imageBitmapPixelFormat(UInt32)
    /// A bitmap image had non-positive/oversized dimensions or a stride/payload
    /// too small for its declared pixels (§8 validation); it was not drawn.
    case imageInvalid
    /// A compressed image (§2.2.2.10) CoreGraphics could not decode — GIF/TIFF,
    /// an unknown magic, or a corrupt PNG/JPEG; it was not drawn.
    case imageCompressed
    /// A DrawImage/DrawImagePoints referenced a metafile-content image
    /// (§2.2.2.27); nested-metafile playback is out of phase-4 scope, so the
    /// image was not drawn.
    case imageMetafile
    /// A DrawImage/DrawImagePoints SrcUnit was not UnitTypePixel ([MS-EMFPLUS]
    /// §2.3.4.8/§2.3.4.9); the SrcRect was treated as pixels regardless.
    case imageSrcUnit
    /// A referenced EmfPlusImageAttributes (§2.2.1.5) requested a non-clamp wrap
    /// mode; it was not applied (the image is drawn once, clamped).
    case imageAttributes
    /// A DrawImage/DrawImagePoints pixel bitmap was decoded BELOW its native
    /// resolution to bound memory against the destination footprint (audit H1;
    /// the EMF+ analogue of `dibDownsampled`). No detail the destination could
    /// show was lost; the image still drew.
    case imageDownsampled
    /// A DrawImage/DrawImagePoints compressed image (§2.2.2.10) was larger than
    /// the destination-derived budget and could not be band-decoded, so it was
    /// skipped rather than fully materialised (audit H1). Distinct from
    /// `imageInvalid` (a broken image): the image is fine, just too large for
    /// this render (e.g. a big photo in a small Quick Look preview).
    case imageOversized
    /// A DrawImagePoints carried the EffectsApplied flag ([MS-EMFPLUS] §2.3.4.9):
    /// an image effect from a prior EmfPlusSerializableObject applies to the draw.
    /// Image effects are not implemented, so the image was drawn plain.
    case imageEffect
    /// A text run was drawn as a single left-to-right line, ignoring a non-default
    /// text-formatting feature it carried: an EmfPlusStringFormat ([MS-EMFPLUS]
    /// §2.2.1.9) trimming/wrap/tab-stop/hotkey/character-range setting, a
    /// right-to-left or vertical direction flag (§2.1.2.8), or a DrawDriverString
    /// vertical/realized-advance option (§2.1.2.3). Only string ALIGNMENT
    /// (StringAlignment/LineAlign) is honoured; the glyphs still drew.
    case stringFormatSimplified
    /// A path carried per-segment DashMode flags ([MS-EMFPLUS] §2.2.2.31): the
    /// segment-level dashing was not reproduced (the path drew solid). PathMarker
    /// flags are ignored WITHOUT a note — markers only affect GetPathPoints
    /// enumeration, never how a path is filled or stroked (audit M14).
    case pathDashSegment
}

/// Which EMF+ stream reassembly/walk issue reached the render log (audit M7).
/// One case per `EMFPlusDiagnostic` ([MS-EMFPLUS] §2.3), payload dropped — the
/// parse-level diagnostics keep the offsets/sizes; the log keeps kind + count so
/// a viewer can say the EMF+ stream was truncated, clamped, or malformed.
public enum EMFPlusStreamIssueKind: Sendable, Equatable, Hashable {
    case commentDataSizeClamped
    case recordSizeTooSmall
    case recordSizeNotAligned
    case recordDataSizeExceedsSize
    case recordDataTruncated
    case trailingBytes
    case headerRecordMissing
    case headerUnexpectedSize
    case headerUnexpectedDataSize
    case recordCountCapped
    case recordSizeExcessPadding

    /// Maps a parse-level `EMFPlusDiagnostic` onto its render-log kind (1:1).
    init(_ diagnostic: EMFPlusDiagnostic) {
        switch diagnostic {
        case .commentDataSizeClamped: self = .commentDataSizeClamped
        case .recordSizeTooSmall: self = .recordSizeTooSmall
        case .recordSizeNotAligned: self = .recordSizeNotAligned
        case .recordDataSizeExceedsSize: self = .recordDataSizeExceedsSize
        case .recordDataTruncated: self = .recordDataTruncated
        case .recordSizeExcessPadding: self = .recordSizeExcessPadding
        case .trailingBytes: self = .trailingBytes
        case .headerRecordMissing: self = .headerRecordMissing
        case .headerUnexpectedSize: self = .headerUnexpectedSize
        case .headerUnexpectedDataSize: self = .headerUnexpectedDataSize
        case .recordCountCapped: self = .recordCountCapped
        }
    }
}

/// Which unresolved-object condition a draw hit (audit M7).
public enum EMFPlusObjectIssueKind: Sendable, Equatable, Hashable {
    /// A draw referenced a slot with no usable value — unbound, the wrong type,
    /// or a malformed decode (all read as nil through the typed accessors).
    case missingReference
    /// An EmfPlusObject named a table index outside 0–63; the object was dropped
    /// ([MS-EMFPLUS] §3.1.2 caps the table at 64 slots).
    case invalidID
    /// An EmfPlusObject's payload could not be decoded (`.malformed`); the slot
    /// still took the malformed value (stream truth), but nothing can use it.
    case undecodable
}

/// The log-and-skip surface for a render pass (primer §8, §10.8).
///
/// Rendering never fails — it always produces best-effort output. Anything the
/// renderer could not fully honour lands here so a caller can tell exactly what
/// was skipped or approximated: unimplemented record types, malformed payloads,
/// unsupported ROP2 modes, region-combination modes CoreGraphics cannot
/// express, path-bracket faults, unknown brush/pen styles and enum values,
/// zero-extent mapping records, save/restore stack faults, and canvas clamps.
public struct EMFRenderLog: Sendable, Equatable {
    /// One logged event. Kept coarse and value-comparable so tests can assert
    /// the exact set of things a file exercised (the gate-file coverage pin).
    ///
    /// Two families are COALESCED (one entry carrying a count, appended on
    /// first occurrence and updated in place): `unimplementedRecord` and
    /// `unsupportedROP2`. Coalescing keeps a file with tens of thousands of a
    /// repeated skip (e.g. WS-B's 15.7k EMR_SETROP2) to a single log line.
    public enum Entry: Sendable, Equatable {
        /// A record type outside the render set was encountered and skipped.
        /// Includes EMF+ content (EMR_COMMENT, type 70) and EMR_EOF (type 14).
        /// `count` records of this `type` were skipped in total (coalesced).
        case unimplementedRecord(type: UInt32, count: Int)
        /// A record's payload failed EMFParse's own validation
        /// (`.malformed`); it was skipped.
        case malformedRecord(type: UInt32)
        /// A ROP2 mode other than R2_COPYPEN was selected on `count` records.
        /// Every affected shape is still drawn as if R2_COPYPEN (the agreed
        /// best-partial-output reading, D5). Coalesced by `rawMode`.
        case unsupportedROP2(rawMode: UInt32, count: Int)
        /// A brush style other than BS_SOLID / BS_NULL was requested; a solid
        /// fallback fill from the payload's ColorRef was used instead.
        case unsupportedBrushStyle(rawStyle: UInt32)
        /// A pen line style outside the supported set (PS_SOLID/DASH/DOT/
        /// DASHDOT/DASHDOTDOT/NULL/USERSTYLE) was requested — e.g.
        /// PS_INSIDEFRAME or PS_ALTERNATE; a solid line was drawn instead.
        /// `rawStyle` is the full PenStyle bit field.
        case unsupportedPenStyle(rawStyle: UInt32)
        /// A window or viewport extent was zero, which would divide by zero in
        /// the page→device mapping — or the header bounds were degenerate when
        /// `render(_:into:target:)` built its device→target fit. The previous
        /// (or a unit) mapping was kept.
        case zeroExtentMapping
        /// A clip-combination RegionMode that CoreGraphics cannot express —
        /// RGN_OR, RGN_XOR, or RGN_DIFF on EMR_SELECTCLIPPATH or
        /// EMR_EXTSELECTCLIPRGN (CG's clip is monotonic-intersection only). The
        /// current clip was left unchanged. `record` is the record type id
        /// (67 or 75); `rawMode` is the RegionMode value as read.
        case unsupportedClipMode(record: UInt32, rawMode: UInt32)
        /// A path closer or clip-from-path record (EMR_FILLPATH,
        /// EMR_STROKEPATH, EMR_STROKEANDFILLPATH, EMR_SELECTCLIPPATH) ran with
        /// no current path — no bracket had been closed, or a previous closer
        /// already consumed it. The record was skipped. `record` is the type id.
        case noCurrentPath(record: UInt32)
        /// EMR_BEGINPATH opened a path bracket while one was already open
        /// (forbidden by [MS-EMF] §2.3.10). The in-progress path was discarded
        /// and a fresh bracket started (best-effort recovery).
        case nestedBeginPath
        /// A record carried a defined-enum field whose value is outside the
        /// enumeration and was ignored, falling back to the current/default
        /// behaviour: EMR_SETMAPMODE (fell back to MM_TEXT),
        /// EMR_SETPOLYFILLMODE, or EMR_SETBKMODE (both kept the current value).
        /// `record` is the record type id; `rawValue` is the value as read.
        case unknownEnumValue(record: UInt32, rawValue: UInt32)
        /// A poly-bezier point count was not ≡ 1 (or 0 for the …To variants)
        /// mod 3; the well-formed prefix was rendered and the remainder
        /// dropped.
        case malformedBezier(pointCount: Int)
        /// A SELECTOBJECT / DELETEOBJECT named a table index that is absent or
        /// out of the supported range; the current selection was kept.
        case invalidObjectIndex(index: UInt32)
        /// An object-creation record would exceed the object-table capacity
        /// cap; it was ignored.
        case objectTableFull(index: UInt32)
        /// A stock object was named where none can be honoured: a font or
        /// palette stock in SELECTOBJECT (no DC state changed), an undefined
        /// stock value, or any stock named by DELETEOBJECT (forbidden by
        /// [MS-EMF] §2.3.8.3).
        case unsupportedStockObject(rawValue: UInt32)
        /// A RESTOREDC could not be satisfied: the saved-state stack was empty
        /// (underflow) or the requested relative index was unreachable.
        case restoreDCUnbalanced(savedDC: Int32)
        /// A SAVEDC pushed past the stack-depth cap; the save was dropped.
        case saveDCStackOverflow
        /// A ModifyWorldTransform mode outside MWT_IDENTITY/LEFTMULTIPLY/
        /// RIGHTMULTIPLY/SET was seen; the transform was left unchanged.
        case unsupportedWorldTransformMode(rawMode: UInt32)
        /// The header bounds (times scale) implied a `makeImage` canvas outside
        /// the caps: larger than the 16384-per-side cap, larger than the
        /// 32-Mpx total-area cap (aspect ratio then preserved), or non-positive.
        /// The canvas was clamped to the rendered size. `requestedWidth`/
        /// `requestedHeight` are the unclamped request; `renderedWidth`/
        /// `renderedHeight` are the final canvas.
        case canvasClamped(
            requestedWidth: Int,
            requestedHeight: Int,
            renderedWidth: Int,
            renderedHeight: Int
        )
        /// A requested font family did not resolve on this machine and a
        /// substitute was used (LOGFONT → CTFont mapping, primer §6 phase 4).
        /// Coalesced by `requested` family: one line per requested family that
        /// was remapped, carrying a count. `used` is the substitute face.
        case fontSubstituted(requested: String, used: String, count: Int)
        /// A stock FONT (SYSTEM_FONT, DEFAULT_GUI_FONT, …) was selected and
        /// resolved to the system font at an approximate size — the exact GDI
        /// stock-font metrics are Windows-specific. Coalesced by `rawValue`.
        case stockFontUsed(rawValue: UInt32, count: Int)
        /// An EMR_EXTTEXTOUTW run set ETO_GLYPH_INDEX: the string holds Windows
        /// glyph ids that do not map to the substituted macOS font, so the run
        /// was skipped (primer §6 phase 4). Coalesced.
        case glyphIndexTextSkipped(count: Int)
        /// A DIB the renderer could not draw — a compression, bit-count, or
        /// palette-usage the phase-4 raster path does not support — was skipped.
        /// Coalesced. `reason` is the parse-side unsupported verdict, or `nil`
        /// when the render path itself declined it (DIB_PAL_COLORS usage).
        case unsupportedDIB(reason: DIBUnsupportedReason?, count: Int)
        /// A raster operation other than SRCCOPY (and the sourceless
        /// BLACKNESS/WHITENESS/PATCOPY fills) was requested. Source blits with an
        /// unsupported source rop are drawn as a plain copy (best effort);
        /// sourceless blits with an unsupported rop are skipped. Coalesced by
        /// `rasterOperation`. ([MS-WMF] §2.1.1.31 TernaryRasterOperation.)
        case unsupportedRasterOp(rasterOperation: UInt32, count: Int)
        /// A blit carried a non-identity source-space transform (XformSrc),
        /// which the renderer ignores — source-space transforms are vanishingly
        /// rare ([MS-EMF] §2.2.28). Coalesced.
        case xformSrcIgnored(count: Int)
        /// One or more DIBs were decoded BELOW their native resolution to bound
        /// memory against the render target ("decode-in-bands"): the destination
        /// footprint was smaller than the source, so the decode sampled down
        /// (nearest-neighbor) instead of materialising the full-native bitmap.
        /// No detail the target could have shown is lost. Coalesced into a single
        /// count; `worstNativePixels`/`worstDecodedPixels` carry the largest
        /// source bitmap that was reduced and the pixel count it decoded to.
        case dibDownsampled(count: Int, worstNativePixels: Int, worstDecodedPixels: Int)
        /// An EMF+ record type the playback does not implement — the MultiFormat
        /// records (0x4005–0x4007), serializable objects and terminal-server
        /// records (0x4037–0x403A), any unknown type, and relative-point drawing
        /// records (the P flag) — was skipped. The rest of the file still plays.
        /// Coalesced by `type`.
        case emfPlusUnsupportedRecord(type: UInt16, count: Int)
        /// An EMF+ feature the playback rendered approximately rather than
        /// exactly (see `EMFPlusApproximation`). The shape still drew; only the
        /// fidelity of that one aspect was reduced. Coalesced by `feature`.
        case emfPlusApproximated(feature: EMFPlusApproximation, count: Int)
        /// An EMF+ stream reassembly/walk issue surfaced from parse-time
        /// diagnostics (audit M7): the EMF+ record stream was truncated, clamped,
        /// or malformed, so playback saw only a prefix (or nothing). Surfaced on
        /// BOTH branches — a dual file that fell back to GDI still reports its
        /// broken EMF+ half. Coalesced by `kind`.
        case emfPlusStreamIssue(kind: EMFPlusStreamIssueKind, count: Int)
        /// A record's body failed its reader/decode guards and was skipped (audit
        /// M7 / D4): a truncated/garbled drawing record (DrawString, FillRects,
        /// image), or a state/clip/transform record (SetWorldTransform,
        /// SetClipRect, EmfPlusSave, …). Coalesced by record `type`.
        case emfPlusRecordUndecodable(type: UInt16, count: Int)
        /// A drawing record referenced an object the table could not supply, or an
        /// EmfPlusObject could not be bound (audit M7 — see `EMFPlusObjectIssueKind`).
        /// Coalesced by `kind`.
        case emfPlusObjectIssue(kind: EMFPlusObjectIssueKind, count: Int)
        /// The EMF+ save/container maps hit their shared capacity cap (audit M1):
        /// at the cap, EmfPlusSave/BeginContainer stop storing (no eviction — a
        /// GDI+ stream nested this deep is already broken). A CAPACITY note, not
        /// lost content. Coalesced into a single count.
        case emfPlusSaveStackCapped(count: Int)
    }

    /// Every logged event, in the order it was raised. The coalesced families
    /// (unimplemented-record by type, unsupported-ROP2 by mode) appear once
    /// each, carrying a count.
    public private(set) var entries: [Entry] = []

    /// How many EMF+ records the playback walk consumed (audit M17). This is an
    /// observability stat, NOT a log entry: it is deliberately EXCLUDED from
    /// `Equatable` (two logs are equal iff their `entries` match), so it never
    /// affects the exact-entries tests. The fuzz floor asserts it is non-zero
    /// across the corpus so a regression that stops taking the EMF+ branch — or a
    /// walk that consumes nothing — is caught even when a textual dispatch mirror
    /// would still pass.
    public private(set) var emfPlusRecordsPlayed: Int = 0

    /// The upper bound on DISTINCT entries the log will hold — far above any
    /// real file or test (the whole render set is a few dozen record types, a
    /// handful of ROP2/rop values, a couple of missing font families). A
    /// hostile file with one distinct coalescing key per record (e.g. 276k
    /// records each with a different rasterOperation) is bounded here: past the
    /// cap NEW distinct keys are dropped, but counts on already-present keys
    /// keep incrementing so existing lines stay accurate. Both memory and
    /// per-call cost stay bounded (§8: never hang on a hostile file).
    static let maxDistinctEntries = 4096

    /// Maps each coalesced family's key to the index of its entry in `entries`,
    /// so a repeat is an O(1) lookup-and-bump instead of a full linear scan.
    /// Without this a file with n distinct keys costs ~n²/2 comparisons (n
    /// inserts each scanning the whole array) — the quadratic hang. Derived
    /// state: rebuilt deterministically from `entries`, never observed
    /// externally, and excluded from `Equatable` (two logs are equal iff their
    /// `entries` are — see `==`). `Entry` is not `Hashable` (it carries no key
    /// worth hashing for the non-coalesced cases), so the key is a small
    /// purpose-built enum.
    private var coalesceIndex: [CoalesceKey: Int] = [:]

    /// The identity of a coalesced entry — one case per coalesced family, so
    /// a lookup is O(1). Mirrors the eight `note*` families below.
    private enum CoalesceKey: Hashable {
        case unimplemented(UInt32)
        case rop2(UInt32)
        case fontSubstituted(String)
        case stockFont(UInt32)
        case glyphIndex
        /// Keyed on a stable surrogate of `DIBUnsupportedReason` (an EMFParse
        /// type that is not `Hashable` and must not be modified from here).
        case unsupportedDIB(DIBReasonKey)
        case rasterOp(UInt32)
        case xformSrc
        case dibDownsampled
        case emfPlusUnsupported(UInt16)
        case emfPlusApprox(EMFPlusApproximation)
        case emfPlusStreamIssue(EMFPlusStreamIssueKind)
        case emfPlusRecordUndecodable(UInt16)
        case emfPlusObjectIssue(EMFPlusObjectIssueKind)
        case emfPlusSaveStackCapped
    }

    /// A `Hashable` surrogate for `DIBUnsupportedReason?` (which is not itself
    /// `Hashable`), preserving its distinctions so distinct reasons stay
    /// separate log lines. `.none` stands for the render-declined (`nil`) case.
    private enum DIBReasonKey: Hashable {
        case none
        case compression(UInt32)
        case bitCount(UInt16)
        case paletteUsage(UInt32)

        init(_ reason: DIBUnsupportedReason?) {
            switch reason {
            case nil: self = .none
            case .compression(let c): self = .compression(Self.discriminator(c))
            case .bitCount(let b): self = .bitCount(b)
            case .paletteUsage(let u): self = .paletteUsage(u)
            }
        }

        /// A stable UInt32 identity for a `BitmapCompression` value, used only
        /// as a coalescing key (EMFParse's enum is not `Hashable` and must not
        /// be modified from here). Matches its [MS-WMF] §2.1.1.7 numbering, with
        /// `.other` carrying its own raw value offset out of that fixed range.
        static func discriminator(_ compression: BitmapCompression) -> UInt32 {
            switch compression {
            case .rgb: return 0x0000
            case .rle8: return 0x0001
            case .rle4: return 0x0002
            case .bitfields: return 0x0003
            case .jpeg: return 0x0004
            case .png: return 0x0005
            case .other(let raw): return raw
            }
        }
    }

    public init() {}

    /// Total number of events, counting each coalesced entry once.
    public var count: Int { entries.count }

    /// True when nothing was skipped or approximated.
    public var isClean: Bool { entries.isEmpty }

    // MARK: - Recording (module-internal)

    /// Records one skipped record of `type`, coalescing repeats into a single
    /// counted entry so a 8,965-comment file yields one line, not 8,965.
    mutating func noteUnimplemented(type: UInt32) {
        if let index = coalesceIndex[.unimplemented(type)],
           case .unimplementedRecord(_, let c) = entries[index] {
            entries[index] = .unimplementedRecord(type: type, count: c + 1)
            return
        }
        appendDistinct(.unimplementedRecord(type: type, count: 1), key: .unimplemented(type))
    }

    /// Records one unsupported ROP2 selection of `rawMode`, coalescing repeats
    /// by mode so WS-B's 15.7k EMR_SETROP2 records yield one line, not 15,700.
    mutating func noteUnsupportedROP2(rawMode: UInt32) {
        if let index = coalesceIndex[.rop2(rawMode)],
           case .unsupportedROP2(_, let c) = entries[index] {
            entries[index] = .unsupportedROP2(rawMode: rawMode, count: c + 1)
            return
        }
        appendDistinct(.unsupportedROP2(rawMode: rawMode, count: 1), key: .rop2(rawMode))
    }

    /// Records one font substitution, coalescing by requested family so a file
    /// with hundreds of runs in a missing family yields one line.
    mutating func noteFontSubstituted(requested: String, used: String) {
        if let index = coalesceIndex[.fontSubstituted(requested)],
           case .fontSubstituted(_, let u, let c) = entries[index] {
            entries[index] = .fontSubstituted(requested: requested, used: u, count: c + 1)
            return
        }
        appendDistinct(
            .fontSubstituted(requested: requested, used: used, count: 1),
            key: .fontSubstituted(requested)
        )
    }

    /// Records one stock-font selection, coalescing by `rawValue`.
    mutating func noteStockFontUsed(rawValue: UInt32) {
        if let index = coalesceIndex[.stockFont(rawValue)],
           case .stockFontUsed(_, let c) = entries[index] {
            entries[index] = .stockFontUsed(rawValue: rawValue, count: c + 1)
            return
        }
        appendDistinct(.stockFontUsed(rawValue: rawValue, count: 1), key: .stockFont(rawValue))
    }

    /// Records one ETO_GLYPH_INDEX run skip, coalescing into a single count.
    mutating func noteGlyphIndexTextSkipped() {
        if let index = coalesceIndex[.glyphIndex],
           case .glyphIndexTextSkipped(let c) = entries[index] {
            entries[index] = .glyphIndexTextSkipped(count: c + 1)
            return
        }
        appendDistinct(.glyphIndexTextSkipped(count: 1), key: .glyphIndex)
    }

    /// Records one unsupported-DIB skip, coalescing by `reason`.
    mutating func noteUnsupportedDIB(reason: DIBUnsupportedReason?) {
        let key = CoalesceKey.unsupportedDIB(DIBReasonKey(reason))
        if let index = coalesceIndex[key],
           case .unsupportedDIB(_, let c) = entries[index] {
            entries[index] = .unsupportedDIB(reason: reason, count: c + 1)
            return
        }
        appendDistinct(.unsupportedDIB(reason: reason, count: 1), key: key)
    }

    /// Records one unsupported raster operation, coalescing by value so a file
    /// of thousands of the same rop yields one line.
    mutating func noteUnsupportedRasterOp(rasterOperation: UInt32) {
        if let index = coalesceIndex[.rasterOp(rasterOperation)],
           case .unsupportedRasterOp(_, let c) = entries[index] {
            entries[index] = .unsupportedRasterOp(rasterOperation: rasterOperation, count: c + 1)
            return
        }
        appendDistinct(
            .unsupportedRasterOp(rasterOperation: rasterOperation, count: 1),
            key: .rasterOp(rasterOperation)
        )
    }

    /// Records one ignored source-space transform, coalescing into a count.
    mutating func noteXformSrcIgnored() {
        if let index = coalesceIndex[.xformSrc],
           case .xformSrcIgnored(let c) = entries[index] {
            entries[index] = .xformSrcIgnored(count: c + 1)
            return
        }
        appendDistinct(.xformSrcIgnored(count: 1), key: .xformSrc)
    }

    /// Records one below-native DIB decode, coalescing into a single count and
    /// keeping the WORST (largest-source) reduction for playback honesty.
    mutating func noteDIBDownsampled(nativePixels: Int, decodedPixels: Int) {
        if let index = coalesceIndex[.dibDownsampled],
           case .dibDownsampled(let c, let worstNative, let worstDecoded) = entries[index] {
            if nativePixels > worstNative {
                entries[index] = .dibDownsampled(count: c + 1, worstNativePixels: nativePixels, worstDecodedPixels: decodedPixels)
            } else {
                entries[index] = .dibDownsampled(count: c + 1, worstNativePixels: worstNative, worstDecodedPixels: worstDecoded)
            }
            return
        }
        appendDistinct(
            .dibDownsampled(count: 1, worstNativePixels: nativePixels, worstDecodedPixels: decodedPixels),
            key: .dibDownsampled
        )
    }

    /// Records one skipped EMF+ record, coalescing by `type` so a file with
    /// thousands of the same unsupported EMF+ record yields one line.
    mutating func noteEMFPlusUnsupported(type: UInt16) {
        if let index = coalesceIndex[.emfPlusUnsupported(type)],
           case .emfPlusUnsupportedRecord(_, let c) = entries[index] {
            entries[index] = .emfPlusUnsupportedRecord(type: type, count: c + 1)
            return
        }
        appendDistinct(.emfPlusUnsupportedRecord(type: type, count: 1), key: .emfPlusUnsupported(type))
    }

    /// Records one EMF+ approximation, coalescing by `feature`.
    mutating func noteEMFPlusApproximated(_ feature: EMFPlusApproximation) {
        if let index = coalesceIndex[.emfPlusApprox(feature)],
           case .emfPlusApproximated(_, let c) = entries[index] {
            entries[index] = .emfPlusApproximated(feature: feature, count: c + 1)
            return
        }
        appendDistinct(.emfPlusApproximated(feature: feature, count: 1), key: .emfPlusApprox(feature))
    }

    /// Records one EMF+ stream reassembly/walk issue, coalescing by `kind` (audit M7).
    mutating func noteEMFPlusStreamIssue(_ kind: EMFPlusStreamIssueKind) {
        if let index = coalesceIndex[.emfPlusStreamIssue(kind)],
           case .emfPlusStreamIssue(_, let c) = entries[index] {
            entries[index] = .emfPlusStreamIssue(kind: kind, count: c + 1)
            return
        }
        appendDistinct(.emfPlusStreamIssue(kind: kind, count: 1), key: .emfPlusStreamIssue(kind))
    }

    /// Records one undecodable drawing record, coalescing by record `type` (audit M7).
    mutating func noteEMFPlusRecordUndecodable(type: UInt16) {
        if let index = coalesceIndex[.emfPlusRecordUndecodable(type)],
           case .emfPlusRecordUndecodable(_, let c) = entries[index] {
            entries[index] = .emfPlusRecordUndecodable(type: type, count: c + 1)
            return
        }
        appendDistinct(.emfPlusRecordUndecodable(type: type, count: 1), key: .emfPlusRecordUndecodable(type))
    }

    /// Records one unresolved-object issue, coalescing by `kind` (audit M7).
    mutating func noteEMFPlusObjectIssue(_ kind: EMFPlusObjectIssueKind) {
        if let index = coalesceIndex[.emfPlusObjectIssue(kind)],
           case .emfPlusObjectIssue(_, let c) = entries[index] {
            entries[index] = .emfPlusObjectIssue(kind: kind, count: c + 1)
            return
        }
        appendDistinct(.emfPlusObjectIssue(kind: kind, count: 1), key: .emfPlusObjectIssue(kind))
    }

    /// Records one save/container-map overflow, coalescing into a single count (audit M1).
    mutating func noteEMFPlusSaveStackCapped() {
        if let index = coalesceIndex[.emfPlusSaveStackCapped],
           case .emfPlusSaveStackCapped(let c) = entries[index] {
            entries[index] = .emfPlusSaveStackCapped(count: c + 1)
            return
        }
        appendDistinct(.emfPlusSaveStackCapped(count: 1), key: .emfPlusSaveStackCapped)
    }

    /// Records any non-coalesced event verbatim.
    mutating func note(_ entry: Entry) {
        guard entries.count < Self.maxDistinctEntries else { return }
        entries.append(entry)
    }

    /// Adds to the EMF+ records-played counter (audit M17): the playback walk calls
    /// it once per consumed record, and makeImage's re-feed once to carry the total
    /// into the delivered log.
    mutating func addEMFPlusRecordsPlayed(_ count: Int = 1) {
        emfPlusRecordsPlayed += count
    }

    /// Appends a first-occurrence coalesced entry and records its index in the
    /// map, unless the distinct-entry cap has been reached — past the cap a new
    /// distinct key is dropped silently (its key is never mapped, so a later
    /// repeat of it is also dropped; already-mapped keys keep counting). This
    /// keeps ordering (first-occurrence) and every non-pathological file's
    /// entry list byte-identical while making a hostile file's memory and
    /// per-call cost bounded.
    private mutating func appendDistinct(_ entry: Entry, key: CoalesceKey) {
        guard entries.count < Self.maxDistinctEntries else { return }
        coalesceIndex[key] = entries.count
        entries.append(entry)
    }

    // MARK: - Equatable

    /// Two logs are equal exactly when their `entries` match (same events, same
    /// order, same counts). `coalesceIndex` is derived state — deterministically
    /// rebuilt from `entries`, so it is always equal when `entries` are equal —
    /// and is deliberately excluded so a private implementation detail never
    /// affects equality (and the exact-array tests keep comparing `entries`
    /// alone). Hand-written because the synthesized `==` would also compare the
    /// map.
    public static func == (lhs: EMFRenderLog, rhs: EMFRenderLog) -> Bool {
        lhs.entries == rhs.entries
    }
}
