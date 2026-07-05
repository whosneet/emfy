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

    /// The default (no) clip — the whole canvas. A computed property (not a
    /// stored static): `CGPath` is not `Sendable`, so `ClipRegion` cannot be,
    /// and a stored static would trip Swift 6's global-mutable-state check.
    static var none: ClipRegion { ClipRegion() }

    var isEmpty: Bool { primitives.isEmpty }

    /// Intersects the current region with `primitive` (INTERSECTCLIPRECT and
    /// RGN_AND).
    mutating func intersect(_ primitive: Primitive) {
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
