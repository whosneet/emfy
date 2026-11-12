import CoreGraphics
import Foundation

/// The editing grid geometry (E3e design call 2): a 10 mm primary grid, optionally
/// subdivided when the on-screen spacing is large. Editor-only; never exported.
enum EditorGrid {
    /// The primary grid spacing in millimetres.
    static let majorMM: CGFloat = 10

    /// The primary grid spacing in device units for a given device resolution.
    static func deviceSpacing(deviceUnitsPerInch: CGFloat) -> CGFloat {
        majorMM / 25.4 * deviceUnitsPerInch
    }

    /// How many subdivisions to draw per major cell given the major cell's ON-SCREEN size
    /// in points: 1 (no subdivision) until the cell is large, then 2 mm (5) and 1 mm (10)
    /// lines, so the grid stays legible but crisp at any zoom.
    static func subdivisions(onScreenMajorPoints: CGFloat) -> Int {
        if onScreenMajorPoints >= 120 { return 10 }
        if onScreenMajorPoints >= 56 { return 5 }
        return 1
    }

    /// The finest displayed spacing (device units) — the primary spacing divided by the
    /// subdivision count — which is also what a drag snaps to.
    static func displayedSpacing(deviceUnitsPerInch: CGFloat, onScreenMajorPoints: CGFloat) -> CGFloat {
        deviceSpacing(deviceUnitsPerInch: deviceUnitsPerInch) / CGFloat(subdivisions(onScreenMajorPoints: onScreenMajorPoints))
    }
}

/// Pure snapping solver for moving, resizing and drawing (E3e design call 3). It snaps
/// the moving object's edges and centre to a set of candidate lines — the grid, other
/// elements' edges and centres, and the page edges and centre ("smart guides") — and
/// reports which guide lines to draw.
///
/// Everything is device-space scalars, independent per axis, so it unit-tests without a
/// view. For speed the caller pre-collects the candidate edges ONCE per drag (`Candidates`)
/// and calls `snap` per pointer event; each call is a handful of binary searches, so it
/// stays well under the 4 ms-per-event budget even on a 15.7k-element scene.
enum EditorSnap {

    /// The candidate lines a drag can snap to, collected once at the start of the drag.
    /// `xs`/`ys` are explicit candidate coordinates (other elements' and the page's left/
    /// centre/right and top/middle/bottom); `gridSpacing` adds the grid analytically (its
    /// lines are never enumerated). All in device units.
    struct Candidates: Equatable {
        /// Sorted candidate x coordinates (vertical guide lines).
        let xs: [CGFloat]
        /// Sorted candidate y coordinates (horizontal guide lines).
        let ys: [CGFloat]
        /// The device-space grid spacing, or nil when the grid is off.
        let gridSpacing: CGFloat?

        init(xs: [CGFloat], ys: [CGFloat], gridSpacing: CGFloat?) {
            self.xs = xs.sorted()
            self.ys = ys.sorted()
            self.gridSpacing = (gridSpacing ?? 0) > 0 ? gridSpacing : nil
        }

        static let empty = Candidates(xs: [], ys: [], gridSpacing: nil)
    }

    /// The outcome of a snap: the device-space adjustment to add to the raw drag and the
    /// device-space coordinates of the guide lines to draw (empty when nothing snapped).
    struct Result: Equatable {
        var dx: CGFloat
        var dy: CGFloat
        var guideXs: [CGFloat]
        var guideYs: [CGFloat]

        static let none = Result(dx: 0, dy: 0, guideXs: [], guideYs: [])
        var snapped: Bool { dx != 0 || dy != 0 || !guideXs.isEmpty || !guideYs.isEmpty }
    }

    /// Snaps the given candidate edge values on each axis. `xEdges`/`yEdges` are the moving
    /// object's edge coordinates eligible to snap on that axis — a move passes all three
    /// (min/mid/max), a resize passes only the dragged edge(s), a draw passes the growing
    /// corner. Returns the single best (closest within `threshold`) adjustment per axis.
    static func snap(xEdges: [CGFloat], yEdges: [CGFloat], candidates: Candidates, threshold: CGFloat) -> Result {
        guard threshold > 0 else { return .none }
        let (dx, guideXs) = solveAxis(edges: xEdges, lines: candidates.xs, grid: candidates.gridSpacing, threshold: threshold)
        let (dy, guideYs) = solveAxis(edges: yEdges, lines: candidates.ys, grid: candidates.gridSpacing, threshold: threshold)
        return Result(dx: dx, dy: dy, guideXs: guideXs, guideYs: guideYs)
    }

    /// Convenience for a MOVE: every edge (min/mid/max) is free to snap on both axes.
    static func snapMove(_ rect: CGRect, candidates: Candidates, threshold: CGFloat) -> Result {
        let r = rect.standardized
        return snap(
            xEdges: [r.minX, r.midX, r.maxX],
            yEdges: [r.minY, r.midY, r.maxY],
            candidates: candidates, threshold: threshold
        )
    }

    // MARK: - Internals

    /// The best (smallest, within `threshold`) offset for one axis, plus the guide lines
    /// that coincide with a moving edge once that offset is applied.
    private static func solveAxis(edges: [CGFloat], lines: [CGFloat], grid: CGFloat?, threshold: CGFloat) -> (CGFloat, [CGFloat]) {
        guard !edges.isEmpty else { return (0, []) }
        var best: CGFloat?
        for edge in edges {
            if let line = nearest(to: edge, in: lines) {
                consider(line - edge, threshold: threshold, into: &best)
            }
            if let g = grid {
                let line = (edge / g).rounded() * g
                consider(line - edge, threshold: threshold, into: &best)
            }
        }
        guard let offset = best else { return (0, []) }

        // Guides: any candidate (or grid) line a moving edge lands exactly on after the shift.
        let eps = Swift.max(threshold * 0.1, 1e-4)
        var guides: [CGFloat] = []
        for edge in edges {
            let shifted = edge + offset
            if let line = nearest(to: shifted, in: lines), abs(line - shifted) <= eps { guides.append(line) }
            if let g = grid {
                let line = (shifted / g).rounded() * g
                if abs(line - shifted) <= eps { guides.append(line) }
            }
        }
        return (offset, dedup(guides))
    }

    /// Keeps `candidate` as the best offset when it is within `threshold` and strictly
    /// closer than the current best (ties keep the earlier edge's result).
    private static func consider(_ candidate: CGFloat, threshold: CGFloat, into best: inout CGFloat?) {
        guard abs(candidate) <= threshold else { return }
        if best == nil || abs(candidate) < abs(best!) { best = candidate }
    }

    /// The element of the sorted `lines` closest to `value` (binary search), or nil when
    /// `lines` is empty.
    private static func nearest(to value: CGFloat, in lines: [CGFloat]) -> CGFloat? {
        guard !lines.isEmpty else { return nil }
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        // `lo` is the first element >= value; the nearest is lo or lo-1.
        var candidate = lines[Swift.min(lo, lines.count - 1)]
        if lo > 0, abs(lines[lo - 1] - value) < abs(candidate - value) { candidate = lines[lo - 1] }
        return candidate
    }

    /// Collapses near-duplicate guide coordinates (two candidates at the same place).
    private static func dedup(_ values: [CGFloat]) -> [CGFloat] {
        var out: [CGFloat] = []
        for v in values.sorted() where out.last.map({ abs($0 - v) > 1e-4 }) ?? true { out.append(v) }
        return out
    }
}
