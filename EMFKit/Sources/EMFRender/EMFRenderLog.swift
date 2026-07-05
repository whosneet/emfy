import EMFParse
import Foundation

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
        /// The header bounds (times scale) implied a `makeImage` canvas larger
        /// than the 16384×16384 cap, or a non-positive one; the canvas was
        /// clamped to the rendered size.
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
    }

    /// Every logged event, in the order it was raised. The coalesced families
    /// (unimplemented-record by type, unsupported-ROP2 by mode) appear once
    /// each, carrying a count.
    public private(set) var entries: [Entry] = []

    public init() {}

    /// Total number of events, counting each coalesced entry once.
    public var count: Int { entries.count }

    /// True when nothing was skipped or approximated.
    public var isClean: Bool { entries.isEmpty }

    // MARK: - Recording (module-internal)

    /// Records one skipped record of `type`, coalescing repeats into a single
    /// counted entry so a 8,965-comment file yields one line, not 8,965.
    mutating func noteUnimplemented(type: UInt32) {
        for index in entries.indices {
            if case .unimplementedRecord(let t, let c) = entries[index], t == type {
                entries[index] = .unimplementedRecord(type: type, count: c + 1)
                return
            }
        }
        entries.append(.unimplementedRecord(type: type, count: 1))
    }

    /// Records one unsupported ROP2 selection of `rawMode`, coalescing repeats
    /// by mode so WS-B's 15.7k EMR_SETROP2 records yield one line, not 15,700.
    mutating func noteUnsupportedROP2(rawMode: UInt32) {
        for index in entries.indices {
            if case .unsupportedROP2(let m, let c) = entries[index], m == rawMode {
                entries[index] = .unsupportedROP2(rawMode: rawMode, count: c + 1)
                return
            }
        }
        entries.append(.unsupportedROP2(rawMode: rawMode, count: 1))
    }

    /// Records one font substitution, coalescing by requested family so a file
    /// with hundreds of runs in a missing family yields one line.
    mutating func noteFontSubstituted(requested: String, used: String) {
        for index in entries.indices {
            if case .fontSubstituted(let r, let u, let c) = entries[index], r == requested {
                entries[index] = .fontSubstituted(requested: requested, used: u, count: c + 1)
                return
            }
        }
        entries.append(.fontSubstituted(requested: requested, used: used, count: 1))
    }

    /// Records one stock-font selection, coalescing by `rawValue`.
    mutating func noteStockFontUsed(rawValue: UInt32) {
        for index in entries.indices {
            if case .stockFontUsed(let v, let c) = entries[index], v == rawValue {
                entries[index] = .stockFontUsed(rawValue: rawValue, count: c + 1)
                return
            }
        }
        entries.append(.stockFontUsed(rawValue: rawValue, count: 1))
    }

    /// Records one ETO_GLYPH_INDEX run skip, coalescing into a single count.
    mutating func noteGlyphIndexTextSkipped() {
        for index in entries.indices {
            if case .glyphIndexTextSkipped(let c) = entries[index] {
                entries[index] = .glyphIndexTextSkipped(count: c + 1)
                return
            }
        }
        entries.append(.glyphIndexTextSkipped(count: 1))
    }

    /// Records one unsupported-DIB skip, coalescing by `reason`.
    mutating func noteUnsupportedDIB(reason: DIBUnsupportedReason?) {
        for index in entries.indices {
            if case .unsupportedDIB(let r, let c) = entries[index], r == reason {
                entries[index] = .unsupportedDIB(reason: reason, count: c + 1)
                return
            }
        }
        entries.append(.unsupportedDIB(reason: reason, count: 1))
    }

    /// Records one unsupported raster operation, coalescing by value so a file
    /// of thousands of the same rop yields one line.
    mutating func noteUnsupportedRasterOp(rasterOperation: UInt32) {
        for index in entries.indices {
            if case .unsupportedRasterOp(let op, let c) = entries[index], op == rasterOperation {
                entries[index] = .unsupportedRasterOp(rasterOperation: rasterOperation, count: c + 1)
                return
            }
        }
        entries.append(.unsupportedRasterOp(rasterOperation: rasterOperation, count: 1))
    }

    /// Records one ignored source-space transform, coalescing into a count.
    mutating func noteXformSrcIgnored() {
        for index in entries.indices {
            if case .xformSrcIgnored(let c) = entries[index] {
                entries[index] = .xformSrcIgnored(count: c + 1)
                return
            }
        }
        entries.append(.xformSrcIgnored(count: 1))
    }

    /// Records any non-coalesced event verbatim.
    mutating func note(_ entry: Entry) {
        entries.append(entry)
    }
}
