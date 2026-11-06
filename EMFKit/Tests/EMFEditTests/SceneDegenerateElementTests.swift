import CoreGraphics
import EMFParse
import EMFRender
import EMFWrite
import Foundation
import Testing
@testable import EMFEdit

/// Slice E1b2d item 5: a zero-area invisible element round-trips — kept verbatim
/// when unedited, preserved (harmlessly invisible) when edited — so an edit never
/// silently drops it (corpus-local idx 150 had a zero-area rect dropped on edit).
struct SceneDegenerateElementTests {

    /// An EMF with a visible filled rect and a ZERO-AREA invisible rect drawn under
    /// NULL_PEN/NULL_BRUSH (0×0 at one corner, a 30×0 band at another), mirroring the
    /// degenerate content real exporters leave behind.
    private func fixture() throws -> Data {
        let page = RectL(left: 0, top: 0, right: 199, bottom: 199)
        let builder = EMFDocumentBuilder(bounds: page, frame: page, device: SizeL(cx: 0, cy: 0), millimeters: SizeL(cx: 0, cy: 0))
        let brush = try builder.allocateObjectHandle()
        try builder.append(.createBrushIndirect(CreateBrushPayload(ihBrush: brush, style: 0, color: ColorRef(red: 200, green: 40, blue: 40), hatch: 0)))
        try builder.append(.selectObject(.table(index: brush)))
        try builder.append(.rectangle(box: RectL(left: 20, top: 20, right: 120, bottom: 120)))
        // Zero-area invisible rects (NULL pen + brush): a 0×0 point and a 30×0 band.
        try builder.append(.selectObject(.stock(.nullPen)))
        try builder.append(.selectObject(.stock(.nullBrush)))
        try builder.append(.rectangle(box: RectL(left: 150, top: 150, right: 150, bottom: 150)))
        try builder.append(.rectangle(box: RectL(left: 40, top: 170, right: 70, bottom: 170)))
        return try builder.finish()
    }

    @Test func zeroAreaElementsAreLifted() throws {
        let scene = try SceneImporter.import(data: try fixture())
        let rects = scene.editableElements.filter { $0.kind == .rect }
        #expect(rects.count == 3, "expected 3 rect elements (1 visible + 2 zero-area), got \(rects.count)")
        let zeroArea = rects.filter { $0.boundsDevice.isNull || $0.boundsDevice.width == 0 || $0.boundsDevice.height == 0 }
        #expect(zeroArea.count == 2, "expected 2 zero-area elements, got \(zeroArea.count)")
    }

    @Test func uneditedKeepsZeroAreaVerbatim() throws {
        let data = try fixture()
        let scene = try SceneImporter.import(data: data)
        let result = try SceneExporter.export(scene, as: .emf)
        // Lossless overlay: an unchanged scene re-emits byte-identically.
        let expected = try EMFDocumentWriter.reEmit(try EMFFile.parse(data), source: data)
        #expect(result.data == expected, "unedited export dropped or changed content")
        let re = try SceneImporter.import(data: result.data)
        #expect(re.editableElements.filter { $0.kind == .rect }.count == 3, "a rect was lost on unedited round trip")
    }

    @Test func editedKeepsZeroAreaElements() throws {
        let data = try fixture()
        var scene = try SceneImporter.import(data: data)
        let before = scene.editableElements.count
        // Edit every element (translate) — the zero-area ones must survive the edit.
        try scene.translate(Set(scene.editableElements.map(\.id)), dx: 10, dy: 5)
        let result = try SceneExporter.export(scene, as: .emf)
        #expect(try EMFFile.parse(result.data).diagnostics.isEmpty, "edited export parsed with diagnostics")
        let re = try SceneImporter.import(data: result.data)
        #expect(re.editableElements.count == before,
                "edit dropped an element: \(re.editableElements.count) != \(before)")
        #expect(re.editableElements.filter { $0.kind == .rect }.count == 3, "a zero-area rect was dropped on edit")
    }
}
