import CoreGraphics
import EMFEdit
import Foundation
import Testing

// X1b item 1: the two-version comparison. The element diff matches by id/kind (edits
// preserve ids) then by position, and reports move / recolour / re-text / add / delete
// correctly; an identical scene diffs to nothing. The pixel-diff helper's regions cover
// the edited area.

@MainActor
private func makeComparisonFixtureScene() throws -> Scene {
    var scene = try SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 210, height: 297)))
    let dup = scene.deviceUnitsPerPoint
    let black = SceneColor(red: 0, green: 0, blue: 0)

    let textID = SceneFactory.nextElementID(in: scene)
    scene.insert(SceneFactory.makeText(
        string: "Quarterly report", originDevice: CGPoint(x: 40, y: 80), family: "Helvetica",
        pointSize: 18, color: black, id: textID, deviceUnitsPerPoint: dup), at: scene.elements.count)

    let rectID = SceneFactory.nextElementID(in: scene)
    scene.insert(SceneFactory.makeShape(
        kind: .rect, rectDevice: CGRect(x: 40, y: 200, width: 200, height: 120),
        style: SceneStyle(fill: SceneFill(color: SceneColor(red: 0.85, green: 0, blue: 0), evenOdd: false), stroke: nil),
        id: rectID), at: scene.elements.count)

    let ellipseID = SceneFactory.nextElementID(in: scene)
    scene.insert(SceneFactory.makeShape(
        kind: .ellipse, rectDevice: CGRect(x: 300, y: 200, width: 120, height: 120),
        style: SceneStyle(fill: SceneFill(color: SceneColor(red: 0, green: 0.4, blue: 0.9), evenOdd: false), stroke: nil),
        id: ellipseID), at: scene.elements.count)
    return scene
}

private func elementID(_ scene: Scene, kind: ElementKind) -> Int? {
    scene.elements.first { $0.kind == kind }?.id
}

@Suite struct DrawingComparisonTests {

    // MARK: - Identical scene

    @Test @MainActor
    func identicalSceneDiffsToNothing() throws {
        let scene = try makeComparisonFixtureScene()
        let diff = DrawingComparison(old: scene, new: scene)
        #expect(diff.isEmpty)
        #expect(diff.changes.isEmpty)
    }

    // MARK: - Move

    @Test @MainActor
    func moveIsReportedAsPositionChange() throws {
        let old = try makeComparisonFixtureScene()
        var new = old
        let id = try #require(elementID(new, kind: .rect))
        try new.translate([id], dx: 60, dy: 40)

        let diff = DrawingComparison(old: old, new: new)
        #expect(diff.changedCount == 1)
        let change = try #require(diff.changes.first { $0.kind == .changed })
        #expect(change.id == id)
        #expect(change.attributes.contains(.position))
        #expect(!change.attributes.contains(.geometry))
    }

    // MARK: - Recolour

    @Test @MainActor
    func recolourIsReportedAsFillColourChange() throws {
        let old = try makeComparisonFixtureScene()
        var new = old
        let id = try #require(elementID(new, kind: .ellipse))
        try new.setFill([id], SceneFill(color: SceneColor(red: 0.1, green: 0.8, blue: 0.2), evenOdd: false))

        let diff = DrawingComparison(old: old, new: new)
        #expect(diff.changedCount == 1)
        let change = try #require(diff.changes.first { $0.id == id })
        #expect(change.attributes == [.fillColor])
        #expect(change.summary.contains("→"))
    }

    // MARK: - Re-text

    @Test @MainActor
    func reTextIsReportedAsTextChange() throws {
        let old = try makeComparisonFixtureScene()
        var new = old
        let id = try #require(elementID(new, kind: .text))
        try new.setText(id, "Annual report")

        let diff = DrawingComparison(old: old, new: new)
        let change = try #require(diff.changes.first { $0.id == id })
        #expect(change.attributes.contains(.text))
    }

    // MARK: - Add

    @Test @MainActor
    func addedElementIsReported() throws {
        let old = try makeComparisonFixtureScene()
        var new = old
        let id = SceneFactory.nextElementID(in: new)
        new.insert(SceneFactory.makeShape(
            kind: .rect, rectDevice: CGRect(x: 40, y: 400, width: 100, height: 60),
            style: SceneStyle(fill: SceneFill(color: SceneColor(red: 0.2, green: 0.2, blue: 0.2), evenOdd: false), stroke: nil),
            id: id), at: new.elements.count)

        let diff = DrawingComparison(old: old, new: new)
        #expect(diff.addedCount == 1)
        let added = try #require(diff.changes.first { $0.kind == .added })
        #expect(added.id == id)
        #expect(added.summary.hasPrefix("Added"))
    }

    // MARK: - Delete

    @Test @MainActor
    func removedElementIsReported() throws {
        let old = try makeComparisonFixtureScene()
        var new = old
        let id = try #require(elementID(new, kind: .ellipse))
        try new.delete([id])

        let diff = DrawingComparison(old: old, new: new)
        #expect(diff.removedCount == 1)
        let removed = try #require(diff.changes.first { $0.kind == .removed })
        #expect(removed.id == id)
        #expect(removed.summary.hasPrefix("Removed"))
    }

    // MARK: - Several edits at once

    @Test @MainActor
    func multipleEditsAreEachReported() throws {
        let old = try makeComparisonFixtureScene()
        var new = old
        let rectID = try #require(elementID(new, kind: .rect))
        let textID = try #require(elementID(new, kind: .text))
        try new.translate([rectID], dx: 30, dy: 0)
        try new.setText(textID, "Changed heading")
        try new.delete([try #require(elementID(new, kind: .ellipse))])

        let diff = DrawingComparison(old: old, new: new)
        #expect(diff.changedCount == 2)
        #expect(diff.removedCount == 1)
        #expect(diff.addedCount == 0)
    }

    // MARK: - Pixel diff

    @Test @MainActor
    func pixelDiffIsEmptyForIdenticalRenders() throws {
        let scene = try makeComparisonFixtureScene()
        let image = try #require(SceneRenderer.makeImage(scene, scale: 1))
        let diff = try #require(DrawingPixelDiff.compare(old: image, new: image))
        #expect(diff.isEmpty)
        #expect(diff.regions.isEmpty)
    }

    @Test @MainActor
    func pixelDiffRegionsCoverTheEdit() throws {
        let old = try makeComparisonFixtureScene()
        var new = old
        let id = try #require(elementID(new, kind: .ellipse))
        try new.setFill([id], SceneFill(color: SceneColor(red: 0.1, green: 0.9, blue: 0.2), evenOdd: false))

        let oldImage = try #require(SceneRenderer.makeImage(old, scale: 1))
        let newImage = try #require(SceneRenderer.makeImage(new, scale: 1))
        let diff = try #require(DrawingPixelDiff.compare(old: oldImage, new: newImage))
        #expect(!diff.isEmpty)
        #expect(!diff.regions.isEmpty)

        // The edited ellipse's device centre, mapped into image-pixel space, must fall
        // inside one of the reported regions.
        let page = new.pageBoundsDevice
        let element = try #require(new.elements.first { $0.id == id })
        let sx = Double(newImage.width) / Double(page.width)
        let sy = Double(newImage.height) / Double(page.height)
        let px = (element.boundsDevice.midX - page.minX) * sx
        let py = (element.boundsDevice.midY - page.minY) * sy
        let point = CGPoint(x: px, y: py)
        #expect(diff.regions.contains { $0.insetBy(dx: -1, dy: -1).contains(point) })
    }
}
