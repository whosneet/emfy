import Foundation

/// The log-and-skip surface for a render pass (primer §8, §10.8).
///
/// Rendering never fails — it always produces best-effort output. Anything the
/// renderer could not fully honour lands here so a caller can tell exactly what
/// was skipped or approximated: unimplemented record types, malformed payloads,
/// unsupported ROP2 modes, deferred clipping, unknown brush/pen styles,
/// zero-extent mapping records, save/restore stack faults, and canvas clamps.
public struct EMFRenderLog: Sendable, Equatable {
    /// One logged event. Kept coarse and value-comparable so tests can assert
    /// the exact set of things a file exercised (the gate-file coverage pin).
    public enum Entry: Sendable, Equatable {
        /// A record type outside the phase-2 render set was encountered and
        /// skipped. Includes EMF+ content (EMR_COMMENT, type 70) and EMR_EOF
        /// (type 14). `count` records of this `type` were skipped in total.
        case unimplementedRecord(type: UInt32, count: Int)
        /// A record's payload failed EMFParse's own validation
        /// (`.malformed`); it was skipped.
        case malformedRecord(type: UInt32)
        /// EMR_INTERSECTCLIPRECT was decoded but clipping is deferred to
        /// phase 3; rendering continued unclipped.
        case clipDeferred
        /// A ROP2 mode other than R2_COPYPEN was selected. The shape is still
        /// drawn as if R2_COPYPEN (the agreed best-partial-output reading, D5).
        case unsupportedROP2(rawMode: UInt32)
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
    }

    /// Every logged event, in the order it was raised (unimplemented-record
    /// entries are coalesced by type — one entry per type carrying a count).
    public private(set) var entries: [Entry] = []

    public init() {}

    /// Total number of events, counting each coalesced unimplemented-record
    /// entry once.
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

    /// Records any non-coalesced event verbatim.
    mutating func note(_ entry: Entry) {
        entries.append(entry)
    }
}
