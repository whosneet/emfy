import CoreGraphics
import Foundation

/// The current clipping region, held in DEVICE space (the coordinate space the
/// DC's logical→device transform maps into), so it is independent of the final
/// canvas fit and the y-flip — those are applied once, at draw time, by
/// composing with the device→target transform.
///
/// Every clip combination the renderer supports is an INTERSECTION:
/// - EMR_INTERSECTCLIPRECT always intersects ([MS-EMF] §2.3.2.3);
/// - EMR_SELECTCLIPPATH / EMR_EXTSELECTCLIPRGN support RGN_COPY (replace) and
///   RGN_AND (intersect); RGN_OR/XOR/DIFF are log-and-skip (CoreGraphics'
///   gstate clip is monotonic-intersection only and cannot express them).
///
/// So the region is an ordered list of primitives that are successively
/// intersected. Applying the clip replays them into a CGContext via repeated
/// `clip()` calls (CG intersects each with the running gstate clip). RGN_COPY
/// resets the list to a single primitive; RGN_AND appends one. An empty list
/// is "no clip" (the whole canvas).
struct ClipRegion: Equatable {

    /// One intersected clip primitive, in device space.
    enum Primitive: Equatable {
        /// The UNION of these device-space rectangles (a region's RectL array,
        /// or a single INTERSECTCLIPRECT rect). Applied with the nonzero
        /// winding rule so overlapping rects still clip to their union.
        case rects([CGRect])
        /// A device-space path (a path bracket selected as clip). Applied with
        /// the nonzero winding rule.
        case path(CGPath)
    }

    /// The primitives to intersect, in order. Empty means no clip.
    private(set) var primitives: [Primitive] = []

    /// The hard cap on stored primitives. `apply(to:)` replays the whole list on
    /// every draw, so an uncapped list makes drawing O(primitives × draws) — a
    /// hostile `[EMR_INTERSECTCLIPRECT, EMR_RECTANGLE] × N` stream would hang
    /// (§8: never hang). The common INTERSECTCLIPRECT chain now folds to a
    /// single rect (see `intersect`), so real files sit at 1–2 primitives; this
    /// only ever fires on abuse. Past the cap further intersections are dropped
    /// silently: the clip stays looser than the (pathological) true region would
    /// be — at worst a few extra pixels draw — which is valid best-effort partial
    /// output (§8: render more, never crash). There is no clean render-log
    /// channel here — `intersect` is on the COW-copied DC state and carries no
    /// log — so the drop is silent by design.
    static let maxPrimitives = 256

    /// The default (no) clip — the whole canvas. A computed property (not a
    /// stored static): `CGPath` is not `Sendable`, so `ClipRegion` cannot be,
    /// and a stored static would trip Swift 6's global-mutable-state check.
    static var none: ClipRegion { ClipRegion() }

    var isEmpty: Bool { primitives.isEmpty }

    /// Intersects the current region with `primitive` (INTERSECTCLIPRECT and
    /// RGN_AND).
    ///
    /// Consecutive SINGLE-rect intersections fold in place: clipping to r1 then
    /// r2 is exactly clipping to r1 ∩ r2 for axis-aligned rects, so an
    /// INTERSECTCLIPRECT chain collapses to one primitive instead of growing the
    /// replayed list (the anti-hang). `CGRect.intersection` returns `.null` for
    /// disjoint rects, which clips to nothing — the correct empty-clip result.
    /// Multi-rect primitives (a region's union) and `.path` primitives do NOT
    /// fold (they don't reduce to a single rect), and the fold only applies when
    /// the LAST primitive is itself a single rect, so unrelated primitives are
    /// never merged across.
    mutating func intersect(_ primitive: Primitive) {
        if case .rects(let new) = primitive, new.count == 1,
           case .rects(let last)? = primitives.last, last.count == 1 {
            primitives[primitives.count - 1] = .rects([last[0].intersection(new[0])])
            return
        }
        guard primitives.count < Self.maxPrimitives else { return }
        primitives.append(primitive)
    }

    /// Replaces the region with `primitive` (RGN_COPY).
    mutating func replace(with primitive: Primitive) {
        primitives = [primitive]
    }

    /// Applies the clip to `context`, transforming every device-space
    /// primitive into target space with `deviceToTarget` (the same transform
    /// geometry is drawn through). Each primitive intersects the running gstate
    /// clip. Callers wrap this in a gstate save/restore so the clip never
    /// leaks past the current draw.
    func apply(to context: CGContext, deviceToTarget: CGAffineTransform) {
        for primitive in primitives {
            switch primitive {
            case .rects(let rects):
                let path = CGMutablePath()
                for rect in rects {
                    path.addRect(rect, transform: deviceToTarget)
                }
                context.addPath(path)
                // Nonzero winding: the union of the added rectangles.
                context.clip()
            case .path(let devicePath):
                let path = CGMutablePath()
                path.addPath(devicePath, transform: deviceToTarget)
                context.addPath(path)
                context.clip()
            }
        }
    }
}
