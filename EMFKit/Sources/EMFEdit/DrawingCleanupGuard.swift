import CoreGraphics
import Foundation

// MARK: - Render-equivalence guard for a clean-up / compatible copy (X1b item 2)
//
// Before a cleaned or compatible copy is offered, render the original and the candidate
// and compare them within the snapshot tolerance. If they differ beyond it the copy is
// lossy — the UI shows what differs (or refuses) rather than silently writing it. Pure;
// reuses the scene renderer and the pixel-diff helper.

public enum DrawingCleanupGuard {

    public struct Result: Sendable, Equatable {
        /// Whether the two renders match within tolerance.
        public var equivalent: Bool
        /// Fraction of pixels that differ, 0…1.
        public var changedFraction: Double
        /// Changed regions in image-pixel space (for "show what differs").
        public var regions: [CGRect]

        public init(equivalent: Bool, changedFraction: Double, regions: [CGRect]) {
            self.equivalent = equivalent
            self.changedFraction = changedFraction
            self.regions = regions
        }
    }

    /// The per-channel tolerance and max-differing-pixel budget the snapshot comparator
    /// uses: small quantisation differences pass, a real content change fails.
    public static let defaultChannelTolerance: UInt8 = 12
    public static let defaultMaxChangedFraction: Double = 0.003

    /// Renders both EMF byte blobs and reports whether they are render-equivalent. Nil
    /// when either blob can't be imported/rendered.
    public static func compareRenders(
        original: Data,
        candidate: Data,
        channelTolerance: UInt8 = defaultChannelTolerance,
        maxChangedFraction: Double = defaultMaxChangedFraction
    ) -> Result? {
        guard let a = render(original), let b = render(candidate) else { return nil }
        guard let diff = DrawingPixelDiff.compare(old: a, new: b, channelTolerance: channelTolerance, cellSize: 24) else { return nil }
        return Result(
            equivalent: diff.changedFraction <= maxChangedFraction,
            changedFraction: diff.changedFraction,
            regions: diff.regions)
    }

    /// Imports and renders an EMF to a CGImage at the standard compare scale.
    private static func render(_ data: Data) -> CGImage? {
        guard let scene = try? SceneImporter.import(data: data) else { return nil }
        return SceneRenderer.makeImage(scene, scale: 2)
    }
}
