import CoreGraphics
import Foundation
import Testing

// C3a slice-3 unit tests for the Mac tiled viewer's pure zoom maths (`ZoomMath`):
// the step zoom, the fit→magnification-range derivation, the "was it fitted" test,
// the anchor point, and the ⌘-scroll magnification. Like the rest of EmfyTests these
// compile the shared sources into a hostless logic bundle, so they run on macOS and
// the iOS simulator with no `import Emfy`.

@Suite struct ZoomMathTests {

    // MARK: clamped

    @Test func clampedHoldsWithinRange() {
        #expect(ZoomMath.clamped(0.5, min: 0.1, max: 8) == 0.5)
    }

    @Test func clampedPinsToBounds() {
        #expect(ZoomMath.clamped(0.01, min: 0.1, max: 8) == 0.1)
        #expect(ZoomMath.clamped(100, min: 0.1, max: 8) == 8)
    }

    @Test func clampedFallsBackToMinForNonFinite() {
        #expect(ZoomMath.clamped(.nan, min: 0.1, max: 8) == 0.1)
        #expect(ZoomMath.clamped(.infinity, min: 0.1, max: 8) == 0.1)
    }

    // MARK: step zoom (25% steps)

    @Test func stepInMultipliesBy125Percent() {
        #expect(abs(ZoomMath.stepIn(from: 1) - 1.25) < 1e-9)
        #expect(abs(ZoomMath.stepIn(from: 2) - 2.5) < 1e-9)
    }

    @Test func stepOutDividesBy125Percent() {
        #expect(abs(ZoomMath.stepOut(from: 1.25) - 1) < 1e-9)
        #expect(abs(ZoomMath.stepOut(from: 2.5) - 2) < 1e-9)
    }

    @Test func stepsAreInverse() {
        let start: CGFloat = 0.8
        #expect(abs(ZoomMath.stepOut(from: ZoomMath.stepIn(from: start)) - start) < 1e-9)
    }

    @Test func stepFromDegenerateInputIsSafe() {
        #expect(ZoomMath.stepIn(from: 0) == ZoomMath.zoomStep)
        #expect(ZoomMath.stepIn(from: .nan) == ZoomMath.zoomStep)
        #expect(ZoomMath.stepOut(from: 0) == 1)
    }

    @Test func steppedZoomClampsAtTheCeiling() {
        // From 7×, one step in would reach 8.75× but the scroll view range caps it.
        let next = ZoomMath.clamped(ZoomMath.stepIn(from: 7), min: 0.1, max: ZoomMath.maxZoom)
        #expect(next == 8)
    }

    // MARK: wasFitted

    @Test func wasFittedTrueNearFit() {
        #expect(ZoomMath.wasFitted(current: 0.5, fit: 0.5))
        #expect(ZoomMath.wasFitted(current: 0.505, fit: 0.5))
    }

    @Test func wasFittedFalseWhenZoomedIn() {
        #expect(!ZoomMath.wasFitted(current: 2, fit: 0.5))
        #expect(!ZoomMath.wasFitted(current: 0.6, fit: 0.5))
    }

    // MARK: fit → range

    @Test func minMagnificationIsFitOrActualSizeWhicheverSmaller() {
        #expect(ZoomMath.minMagnification(fit: 0.3) == 0.3)   // large picture: fit < 1
        #expect(ZoomMath.minMagnification(fit: 1) == 1)       // small picture: fit capped at 1
    }

    @Test func maxMagnificationIsEightButNeverBelowFit() {
        #expect(ZoomMath.maxMagnification(fit: 0.3) == 8)
        #expect(ZoomMath.maxMagnification(fit: 1) == 8)
    }

    // MARK: anchor

    @Test func visibleCentreIsTheRectMidpoint() {
        let centre = ZoomMath.visibleCentre(of: CGRect(x: 10, y: 20, width: 100, height: 40))
        #expect(centre == CGPoint(x: 60, y: 40))
    }

    // MARK: ⌘-scroll magnification

    @Test func scrollZoomInOnPositiveDelta() {
        let mag = ZoomMath.scrollZoomMagnification(current: 1, scrollDelta: 10, sensitivity: 0.01, min: 0.1, max: 8)
        #expect(mag > 1)
    }

    @Test func scrollZoomOutOnNegativeDelta() {
        let mag = ZoomMath.scrollZoomMagnification(current: 1, scrollDelta: -10, sensitivity: 0.01, min: 0.1, max: 8)
        #expect(mag < 1)
    }

    @Test func scrollZoomIsIdentityAtZeroDelta() {
        let mag = ZoomMath.scrollZoomMagnification(current: 2, scrollDelta: 0, min: 0.1, max: 8)
        #expect(abs(mag - 2) < 1e-9)
    }

    @Test func scrollZoomClampsIntoRange() {
        let high = ZoomMath.scrollZoomMagnification(current: 7, scrollDelta: 1000, min: 0.1, max: 8)
        #expect(high == 8)
        let low = ZoomMath.scrollZoomMagnification(current: 0.2, scrollDelta: -1000, min: 0.1, max: 8)
        #expect(low == 0.1)
    }

    @Test func scrollZoomSafeForNonFiniteInputs() {
        let mag = ZoomMath.scrollZoomMagnification(current: .nan, scrollDelta: 10, min: 0.1, max: 8)
        #expect(mag == 0.1)
    }

    @Test func scrollZoomScalesNonPreciseLineDeltas() {
        // One mouse-wheel line (delta 1) must zoom far more non-precise than precise,
        // or a notch would be ~1%. Non-precise scales the line by lineScrollPoints=10.
        let precise = ZoomMath.scrollZoomMagnification(current: 1, scrollDelta: 1, precise: true, min: 0.1, max: 8)
        let line = ZoomMath.scrollZoomMagnification(current: 1, scrollDelta: 1, precise: false, min: 0.1, max: 8)
        #expect(line > precise)
        #expect(abs(precise - CGFloat(exp(0.01))) < 1e-6)   // exp(1 * 0.01)
        #expect(abs(line - CGFloat(exp(0.10))) < 1e-6)       // exp(1 * 10 * 0.01)
    }

    // MARK: tiled levels of detail

    @Test func levelsGrowWithPageSizeToKeepTheCoarsestLevelSmall() {
        // Small pages need only the base + magnified levels plus one reduced.
        #expect(ZoomMath.tiledLevelsOfDetail(forLongSide: 100) == 5)   // bias 4 + base, ratio<=1
        #expect(ZoomMath.tiledLevelsOfDetail(forLongSide: 377) == 6)   // +1 reduced (377/2=188<=256)
        // The C2 display cap (16384): 6 reduced levels -> coarsest 16384/64 = 256.
        #expect(ZoomMath.tiledLevelsOfDetail(forLongSide: 16384) == 11)
    }

    @Test func levelsStayWithinTheFourToFourteenClamp() {
        #expect(ZoomMath.tiledLevelsOfDetail(forLongSide: 1) == 5)                 // never below minLevels 4
        #expect(ZoomMath.tiledLevelsOfDetail(forLongSide: 100, bias: 0) == 4)      // tiny total clamps up to 4
        #expect(ZoomMath.tiledLevelsOfDetail(forLongSide: 1_000_000_000) == 14)    // huge clamps down to 14
    }

    @Test func derivedLevelsDrawTheWholePageAtOrBelowTheCoarsestLongSide() {
        // The coarsest level = base / 2^(levels - 1 - bias); assert it is <= 256.
        for side: CGFloat in [377, 1024, 4096, 16384] {
            let levels = ZoomMath.tiledLevelsOfDetail(forLongSide: side)
            let reduced = levels - 1 - 4
            let coarsest = side / pow(2, CGFloat(reduced))
            #expect(coarsest <= 256 + 1e-6)
        }
    }

    // MARK: adaptive tile size (P2b) — policy lives in ViewerFit (cross-platform)

    @Test func cheapDocumentsKeepTheHistoricalTile() {
        // An ordinary file of a few thousand records is untouched: 512, not expensive.
        #expect(ViewerFit.isExpensiveToReplay(playbackOps: 0) == false)
        #expect(ViewerFit.isExpensiveToReplay(playbackOps: 2_000) == false)
        #expect(ViewerFit.isExpensiveToReplay(playbackOps: 49_999) == false)
        #expect(ViewerFit.tileSide(forPlaybackOps: 0) == ViewerFit.defaultTileSide)
        #expect(ViewerFit.tileSide(forPlaybackOps: 2_000) == 512)
    }

    @Test func expensiveDocumentsGetLargeTiles() {
        // The measured heavy targets (~276k–278k records) cross the threshold.
        #expect(ViewerFit.isExpensiveToReplay(playbackOps: 50_000) == true)
        #expect(ViewerFit.isExpensiveToReplay(playbackOps: 276_264) == true)
        #expect(ViewerFit.isExpensiveToReplay(playbackOps: 277_901) == true)
        #expect(ViewerFit.tileSide(forPlaybackOps: 50_000) == ViewerFit.largeTileSide)
        #expect(ViewerFit.tileSide(forPlaybackOps: 277_901) == 1024)
    }

    // MARK: placeholder scale (P2b)

    @Test func placeholderNeverUpscalesASmallPage() {
        #expect(ViewerFit.placeholderScale(forLongSide: 100) == 1)
        #expect(ViewerFit.placeholderScale(forLongSide: ViewerFit.maxPlaceholderLongEdge) == 1)
    }

    @Test func placeholderCapsALargePageToTheLongEdge() {
        let scale = ViewerFit.placeholderScale(forLongSide: 3072)
        #expect(abs(scale - 0.5) < 1e-9)                        // 1536 / 3072
        #expect(3072 * scale == ViewerFit.maxPlaceholderLongEdge)
    }

    @Test func placeholderScaleIsSafeForDegenerateInput() {
        #expect(ViewerFit.placeholderScale(forLongSide: .nan) == 1)
        #expect(ViewerFit.placeholderScale(forLongSide: 0) == 1)
    }
}
