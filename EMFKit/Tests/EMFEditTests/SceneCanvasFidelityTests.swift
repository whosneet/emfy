import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import Testing
@testable import EMFEdit

/// Slice E1b2d items 1–2: the editor's UNEDITED render must match the viewer
/// exactly. `SceneRenderer.makeImage` shares `MetafileRenderer`'s canvas-sizing
/// rule (per-side cap THEN the 32 Mpx area cap — `EMFRenderer.canvasPixelSize`),
/// so the editor canvas is pixel-for-pixel the viewer's for every file, and the
/// unedited render is within 0.5% of the viewer's pixels.
struct SceneCanvasFidelityTests {

    static let budget = 0.005          // 0.5% differing pixels
    static let tolerance = 16

    /// Renders the source (viewer) and the UNEDITED scene (editor) at the same
    /// adaptive scale (a large page is capped so the sweep stays fast; fidelity is
    /// an area fraction, so a capped resolution still measures it). Nil when the
    /// file is not renderable at all (the viewer cannot prepare it either).
    private func measure(_ data: Data) -> (sameSize: Bool, frac: Double)? {
        guard let opened = try? OpenedMetafile.open(data),
              let prepared = MetafileRenderer.prepare(opened),
              let scene = try? SceneImporter.import(data: data) else { return nil }
        let maxDim = max(scene.pageSizeDevice.width, scene.pageSizeDevice.height)
        let scale = min(CGFloat(1), CGFloat(360) / max(maxDim, 1))
        guard let (src, _) = MetafileRenderer.makeImage(prepared, scale: scale),
              let scn = SceneRenderer.makeImage(scene, scale: scale) else { return nil }
        let diff = compareImages(scn, src, tolerance: Self.tolerance)
        return (diff.sameSize, diff.differingFraction)
    }

    /// Every committed fixture: identical canvas size AND ≤0.5% pixel difference.
    @Test func committedUneditedMatchesViewer() throws {
        let files = EditTestPaths.committedMetafiles()
        try #require(!files.isEmpty)
        for url in files {
            let data = try Data(contentsOf: url)
            guard let m = measure(data) else { Issue.record("\(url.lastPathComponent): render failed"); continue }
            #expect(m.sameSize, "\(url.lastPathComponent): editor canvas size differs from the viewer")
            #expect(m.frac <= Self.budget,
                    "\(url.lastPathComponent): \(String(format: "%.3f%%", m.frac * 100)) of pixels differ (budget 0.5%)")
        }
    }

    /// Every corpus-local file (gitignored, confidential, may be absent): identical
    /// canvas size AND ≤0.5% pixel difference for the unedited render. Reported by
    /// COUNT with anonymised outlier indices — a file name is never emitted. A file
    /// the VIEWER itself cannot prepare (the importer agrees it is unreadable) is
    /// skipped: that is item-4 territory, not a size/fidelity failure.
    @Test func corpusLocalUneditedMatchesViewer() throws {
        let files = EditTestPaths.localMetafiles()
        guard !files.isEmpty else { print("\n=== E1b2d corpus-local canvas/fidelity: absent (0 files) ==="); return }
        var measured = 0, sizeOK = 0, within = 0, skipped = 0
        var sizeOutliers: [Int] = []
        var pctOutliers: [(idx: Int, pct: Double)] = []
        for (idx, url) in files.enumerated() {
            guard let data = try? Data(contentsOf: url), let m = measure(data) else { skipped += 1; continue }
            measured += 1
            if m.sameSize { sizeOK += 1 } else { sizeOutliers.append(idx) }
            if m.sameSize, m.frac <= Self.budget { within += 1 }
            else if m.sameSize { pctOutliers.append((idx, m.frac)) }
        }
        let tops = pctOutliers.sorted { $0.pct > $1.pct }.prefix(10).map { "#\($0.idx)=\(String(format: "%.2f%%", $0.pct * 100))" }
        print("""

        === E1b2d corpus-local canvas/fidelity ===
        measured / size-identical / ≤0.5%  : \(measured) / \(sizeOK) / \(within)
        skipped (unreadable by the viewer)  : \(skipped)
        size outliers (index only)          : \(sizeOutliers)
        pixel outliers (index only)         : \(tops)
        """)
        #expect(sizeOK == measured, "canvas size differs for \(measured - sizeOK) corpus-local file(s): \(sizeOutliers)")
        #expect(within == measured, "unedited render > 0.5% for \(measured - within) corpus-local file(s): \(tops)")
    }
}
