import CoreGraphics
import EMFRender
import Testing

/// The step-through replay driver's pure render decisions (F5c): render once per
/// index (no re-render on a repeated same-index request) and the raster size cap.
@Suite struct RecordReplayLogicTests {

    @Test("Stepping to the same index twice renders once")
    func rendersOncePerIndex() {
        // First request for a fresh index renders.
        #expect(RecordReplayLogic.shouldRender(requested: 5, lastRequested: nil))
        // A repeated request for the SAME index does not render again.
        #expect(!RecordReplayLogic.shouldRender(requested: 5, lastRequested: 5))
        // A request for a DIFFERENT index renders.
        #expect(RecordReplayLogic.shouldRender(requested: 6, lastRequested: 5))
        // And stepping back to a previously-shown index renders it again (the raster
        // isn't retained across indices — only the current one is cached).
        #expect(RecordReplayLogic.shouldRender(requested: 5, lastRequested: 6))
    }

    @Test("The replay scale is capped so the raster's long side stays within budget")
    func capsRasterScale() {
        // A small page keeps the requested scale (long side 400 × 2 = 800 ≤ 4096).
        #expect(RecordReplayLogic.cappedScale(2, deviceLongSide: 400) == 2)
        // A large page is capped so the long side lands on the 4096 budget.
        let capped = RecordReplayLogic.cappedScale(2, deviceLongSide: 8192)
        #expect(capped == 0.5)
        #expect(capped * 8192 == 4096)
        // A degenerate device size falls back to the requested scale (floored).
        #expect(RecordReplayLogic.cappedScale(2, deviceLongSide: 0) == 2)
    }
}
