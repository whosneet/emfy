import CoreGraphics
import EMFParse
import EMFRender
import EMFWrite
import Foundation
import Testing
import WMFParse
@testable import EMFEdit

/// Regression for the E1b1-review finding (robustness fix 5a): the WMF overlay
/// mapped every synthesised block through the window the PREAMBLE established.
/// When a file changes its window mid-stream (SETWINDOWEXT/ORG), an element drawn
/// after the change is captured in device space under the NEW mapping. The
/// self-contained block sets its own window, so the base-window choice cancels
/// for POSITION — but NOT for the geometric pen width (geometry scales with the
/// block's window, the pen width does not), so an edited stroked element after a
/// mid-stream window change rendered with the wrong line width. The overlay now
/// uses the window actually in effect where the element draws.
struct SceneWMFMidStreamWindowTests {

    static let tolerance = 16

    /// A placeable WMF whose window extent HALVES mid-stream, with a thick-stroked
    /// filled rectangle before and after the change. The second rectangle is drawn
    /// at twice the device scale of the first.
    private func midStreamWindowWMF() throws -> Data {
        let b = WMFDocumentBuilder(boundingBox: WMFRect16(left: 0, top: 0, right: 200, bottom: 200), unitsPerInch: 96)
        try b.append(.setMapMode(8))                               // MM_ANISOTROPIC
        try b.append(.setWindowOrg(PointL(x: 0, y: 0)))
        try b.append(.setWindowExt(SizeL(cx: 200, cy: 200)))
        _ = try b.append(.createPenIndirect(style: 0, width: 6, color: ColorRef(red: 0, green: 0, blue: 0)))
        _ = try b.append(.createBrushIndirect(style: 0, color: ColorRef(red: 200, green: 200, blue: 200), hatch: 0))
        try b.append(.selectObject(index: 0))                     // pen
        try b.append(.selectObject(index: 1))                     // brush
        try b.append(.rectangle(RectL(left: 20, top: 20, right: 70, bottom: 70)))   // rect A
        try b.append(.setWindowExt(SizeL(cx: 100, cy: 100)))      // mid-stream: logical now maps 2× to device
        try b.append(.rectangle(RectL(left: 20, top: 20, right: 70, bottom: 70)))   // rect B (after the change)
        return try b.finish()
    }

    @Test func editAfterMidStreamWindowChangeExportsCorrectly() throws {
        let data = try midStreamWindowWMF()
        var scene = try SceneImporter.import(data: data)
        #expect(scene.source.renderPath == .wmf, "must take the true WMF overlay path, not embedded-EMF")

        let rects = scene.elements.filter { $0.kind == .rect }
        try #require(rects.count == 2, "expected 2 rectangles, got \(rects.count)")
        // B is drawn under the halved window, so its device footprint is 2× A's.
        #expect(rects[1].boundsDevice.width > rects[0].boundsDevice.width * 1.5,
                "rect B should be drawn larger (halved window): A=\(rects[0].boundsDevice) B=\(rects[1].boundsDevice)")
        let bID = rects[1].id
        let bBoxBefore = rects[1].boundsDevice

        // Translate B (an edit → B is synthesised in the overlay) and export.
        let dx = 5.0, dy = 5.0
        try scene.translate([bID], dx: dx, dy: dy)
        let exported = try SceneExporter.export(scene, as: .wmf)

        // The exported file, rendered by the full WMF interpreter, must match the
        // edited scene — including B's stroke WIDTH, which is only correct when the
        // block maps through the window in effect at B. Under the old base-window
        // mapping B's rendered line width was ~2× off, pushing this past 5%.
        guard let scImg = SceneRenderer.makeImage(scene, scale: 2),
              let expOpened = try? OpenedMetafile.open(exported.data),
              let expImg = MetafileRenderer.makeImage(expOpened, scale: 2)?.0
        else { Issue.record("render failed"); return }
        let d = compareImages(expImg, scImg, tolerance: Self.tolerance)
        #expect(d.sameSize)
        #expect(d.differingFraction <= 0.03,
                "render(export) vs render(editedScene) \(d.differingFraction * 100)% (budget 3%); a base-window regression lands near 6%")

        // Position round-trips (window-independent) and rect A is untouched verbatim.
        let reimported = try SceneImporter.import(data: exported.data)
        let reRects = reimported.elements.filter { $0.kind == .rect }
        try #require(reRects.count == 2)
        let expected = bBoxBefore.offsetBy(dx: dx, dy: dy)
        #expect(abs(reRects[1].boundsDevice.minX - expected.minX) <= 2 && abs(reRects[1].boundsDevice.minY - expected.minY) <= 2,
                "B position \(reRects[1].boundsDevice) vs expected \(expected)")
        #expect(abs(reRects[0].boundsDevice.minX - rects[0].boundsDevice.minX) <= 2,
                "rect A moved on re-emit: \(rects[0].boundsDevice) -> \(reRects[0].boundsDevice)")
    }
}
