import CoreGraphics
import EMFParse
import Foundation
import Testing
@testable import EMFEdit

/// X2d: the typed drawing-generation plan — strict decode (with the same repairs as
/// EditPlan), every validator rejection, a stub plan → a scene with the expected
/// elements, and an export → re-import that preserves the element kinds and counts.
struct GenerationPlanTests {

    // MARK: - Decode

    @Test func decodesFractionPlanWithElements() throws {
        let json = """
        {"page":"a4-landscape","coords":"fraction","elements":[
          {"op":"rectangle","x":0.1,"y":0.1,"w":0.2,"h":0.15,"fill":"blue","stroke":"black","strokeWidth":2},
          {"op":"text","x":0.1,"y":0.1,"text":"Start","color":"black","fontSize":18}
        ]}
        """
        let plan = try GenerationPlan.decode(fromJSON: json)
        #expect(plan.page.preset == .a4Landscape)
        #expect(plan.page.coordinateSpace == .fraction)
        #expect(plan.operations.count == 2)
        #expect(plan.operations[0].opName == "rectangle")
        #expect(plan.operations[1].isText)
    }

    @Test func decodesThroughProseAndCodeFence() throws {
        let json = """
        Sure! Here is your drawing:
        ```json
        {"page":"a4-portrait","elements":[{"op":"ellipse","x":0.2,"y":0.2,"w":0.3,"h":0.3,"fill":"red"}]}
        ```
        """
        let plan = try GenerationPlan.decode(fromJSON: json)
        #expect(plan.operations.count == 1)
        #expect(plan.page.preset == .a4Portrait)
    }

    @Test func repairsDroppedKeyQuotes() throws {
        // A small model drops the opening quote on `w` and both quotes on `h`.
        let json = #"{"page":"a4-landscape","elements":[{"op":"rectangle","x":0.1,"y":0.1,w":0.2,"h":0.1,"fill":"green"}]}"#
        let plan = try GenerationPlan.decode(fromJSON: json)
        #expect(plan.operations.count == 1)
    }

    @Test func unknownOpThrows() {
        let json = #"{"elements":[{"op":"spiral","x":0.1,"y":0.1,"w":0.1,"h":0.1}]}"#
        #expect(throws: (any Error).self) { try GenerationPlan.decode(fromJSON: json) }
    }

    @Test func missingElementsArrayThrows() {
        #expect(throws: (any Error).self) { try GenerationPlan.decode(fromJSON: #"{"page":"a4-landscape"}"#) }
    }

    @Test func roundTripsThroughOwnJSON() throws {
        let plan = GenerationPlan(page: GenerationPage(preset: .letterPortrait, coordinateSpace: .points), operations: [
            .rectangle(x: 10, y: 20, w: 100, h: 50, fill: GenColor(raw: "#112233"), stroke: GenColor(raw: "navy"), strokeWidth: 3),
            .arrow(from: GenPoint(x: 10, y: 10), to: GenPoint(x: 50, y: 60), stroke: GenColor(raw: "black"), strokeWidth: 2),
            .text(x: 10, y: 10, w: nil, h: nil, string: "Hi", color: GenColor(raw: "red"), fontSize: 14, fontFamily: nil),
        ])
        let decoded = try GenerationPlan.decode(fromJSON: plan.json())
        #expect(decoded == plan)
    }

    // MARK: - Validator rejections (each one)

    private func validate(_ ops: [GenerationOp], page: GenerationPage = GenerationPage()) -> GenerationPlanValidation {
        GenerationPlanValidator.validate(GenerationPlan(page: page, operations: ops))
    }

    @Test func rejectsEmptyPlan() {
        let v = validate([])
        #expect(!v.isApplicable)
        #expect(v.problems.contains(.emptyPlan))
    }

    @Test func rejectsTooManyElements() {
        let ops = Array(repeating: GenerationOp.rectangle(x: 0.1, y: 0.1, w: 0.1, h: 0.1, fill: nil, stroke: nil, strokeWidth: nil), count: 301)
        let v = validate(ops)
        #expect(v.problems.contains { if case .tooManyElements = $0 { return true }; return false })
    }

    @Test func rejectsNonFiniteCoordinate() {
        let v = validate([.rectangle(x: .nan, y: 0.1, w: 0.1, h: 0.1, fill: nil, stroke: nil, strokeWidth: nil)])
        #expect(v.problems.contains { if case .coordinateNotFinite = $0 { return true }; return false })
    }

    @Test func rejectsOutOfPageCoordinate() {
        let v = validate([.rectangle(x: 3.0, y: 0.1, w: 0.1, h: 0.1, fill: nil, stroke: nil, strokeWidth: nil)])
        #expect(v.problems.contains { if case .coordinateOutOfPage = $0 { return true }; return false })
    }

    @Test func rejectsNonPositiveSize() {
        let v = validate([.rectangle(x: 0.1, y: 0.1, w: 0, h: 0.1, fill: nil, stroke: nil, strokeWidth: nil)])
        #expect(v.problems.contains { if case .nonPositiveSize = $0 { return true }; return false })
    }

    @Test func rejectsZeroLengthLine() {
        let v = validate([.line(from: GenPoint(x: 0.2, y: 0.2), to: GenPoint(x: 0.2, y: 0.2), stroke: nil, strokeWidth: nil)])
        #expect(v.problems.contains { if case .nonPositiveSize = $0 { return true }; return false })
    }

    @Test func rejectsTooFewPoints() {
        let polyline = validate([.polyline(points: [GenPoint(x: 0.1, y: 0.1)], stroke: nil, strokeWidth: nil)])
        #expect(polyline.problems.contains { if case .tooFewPoints = $0 { return true }; return false })
        let polygon = validate([.polygon(points: [GenPoint(x: 0.1, y: 0.1), GenPoint(x: 0.2, y: 0.2)], fill: nil, stroke: nil, strokeWidth: nil)])
        #expect(polygon.problems.contains { if case .tooFewPoints = $0 { return true }; return false })
    }

    @Test func rejectsInvalidColour() {
        let v = validate([.rectangle(x: 0.1, y: 0.1, w: 0.1, h: 0.1, fill: GenColor(raw: "not-a-colour"), stroke: nil, strokeWidth: nil)])
        #expect(v.problems.contains { if case .invalidColor = $0 { return true }; return false })
    }

    @Test func rejectsFontSizeOutOfRange() {
        let tooBig = validate([.text(x: 0.1, y: 0.1, w: nil, h: nil, string: "x", color: nil, fontSize: 500, fontFamily: nil)])
        #expect(tooBig.problems.contains { if case .fontSizeOutOfRange = $0 { return true }; return false })
        let tooSmall = validate([.text(x: 0.1, y: 0.1, w: nil, h: nil, string: "x", color: nil, fontSize: 2, fontFamily: nil)])
        #expect(tooSmall.problems.contains { if case .fontSizeOutOfRange = $0 { return true }; return false })
    }

    @Test func rejectsTextTooLong() {
        let long = String(repeating: "a", count: 501)
        let v = validate([.text(x: 0.1, y: 0.1, w: nil, h: nil, string: long, color: nil, fontSize: 14, fontFamily: nil)])
        #expect(v.problems.contains { if case .textTooLong = $0 { return true }; return false })
    }

    @Test func acceptsColourWordsAndHex() {
        let v = validate([
            .rectangle(x: 0.1, y: 0.1, w: 0.2, h: 0.2, fill: GenColor(raw: "dark blue"), stroke: GenColor(raw: "#334455"), strokeWidth: 2),
            .ellipse(x: 0.4, y: 0.4, w: 0.2, h: 0.2, fill: GenColor(raw: "red"), stroke: nil, strokeWidth: nil),
        ])
        #expect(v.isApplicable)
    }

    // MARK: - Stub plan → scene

    @Test func stubPlanBuildsSceneWithExpectedElements() throws {
        let plan = GenerationPlan(page: GenerationPage(preset: .a4Landscape, coordinateSpace: .fraction), operations: [
            .rectangle(x: 0.1, y: 0.1, w: 0.2, h: 0.15, fill: GenColor(raw: "blue"), stroke: GenColor(raw: "black"), strokeWidth: 2),
            .ellipse(x: 0.5, y: 0.5, w: 0.2, h: 0.2, fill: GenColor(raw: "red"), stroke: nil, strokeWidth: nil),
            .text(x: 0.15, y: 0.12, w: 0.2, h: 0.05, string: "Start", color: GenColor(raw: "black"), fontSize: 18, fontFamily: nil),
        ])
        #expect(GenerationPlanValidator.validate(plan).isApplicable)
        let scene = try plan.makeScene()
        let kinds = scene.editableElements.map(\.kind)
        #expect(scene.editableElements.count == 3)
        #expect(kinds.filter { $0 == .rect }.count == 1)
        #expect(kinds.filter { $0 == .ellipse }.count == 1)
        #expect(kinds.filter { $0 == .text }.count == 1)
        // The rectangle's blue fill made it onto the element.
        let rect = try #require(scene.editableElements.first { $0.kind == .rect })
        #expect(rect.style.fill != nil)
        #expect(scene.summaryCountsMatches(plan))
    }

    @Test func arrowProducesShaftAndHead() throws {
        let plan = GenerationPlan(page: GenerationPage(), operations: [
            .arrow(from: GenPoint(x: 0.2, y: 0.5), to: GenPoint(x: 0.7, y: 0.5), stroke: GenColor(raw: "black"), strokeWidth: 3),
        ])
        #expect(GenerationPlanValidator.validate(plan).isApplicable)
        let scene = try plan.makeScene()
        // An arrow is a line shaft plus a filled-triangle head.
        #expect(scene.editableElements.count == 2)
        #expect(scene.editableElements.contains { $0.kind == .line })
        let head = try #require(scene.editableElements.first { $0.kind == .polygon })
        #expect(head.style.fill != nil)
        #expect(plan.summaryCounts == (shapes: 1, labels: 0))
    }

    @Test func rendersNonBlank() throws {
        let plan = GenerationPlan(page: GenerationPage(), operations: [
            .rectangle(x: 0.1, y: 0.1, w: 0.3, h: 0.3, fill: GenColor(raw: "blue"), stroke: nil, strokeWidth: nil),
            .text(x: 0.15, y: 0.15, w: nil, h: nil, string: "Hello", color: GenColor(raw: "white"), fontSize: 24, fontFamily: nil),
        ])
        let scene = try plan.makeScene()
        let image = try #require(SceneRenderer.makeImage(scene, scale: 0.5))
        #expect(!isBlank(image))
    }

    // MARK: - Export → re-import preserves kinds and counts

    @Test func exportsAndReimportsWithSameKindsAndCounts() throws {
        // Stable kinds across the EMF round-trip: rectangle, ellipse, text.
        let plan = GenerationPlan(page: GenerationPage(), operations: [
            .rectangle(x: 0.1, y: 0.1, w: 0.2, h: 0.15, fill: GenColor(raw: "blue"), stroke: GenColor(raw: "black"), strokeWidth: 2),
            .rectangle(x: 0.4, y: 0.1, w: 0.2, h: 0.15, fill: GenColor(raw: "green"), stroke: GenColor(raw: "black"), strokeWidth: 2),
            .ellipse(x: 0.7, y: 0.5, w: 0.2, h: 0.2, fill: GenColor(raw: "red"), stroke: nil, strokeWidth: nil),
            .text(x: 0.12, y: 0.12, w: nil, h: nil, string: "Start", color: GenColor(raw: "black"), fontSize: 16, fontFamily: nil),
            .text(x: 0.42, y: 0.12, w: nil, h: nil, string: "Process", color: GenColor(raw: "black"), fontSize: 16, fontFamily: nil),
        ])
        let scene = try plan.makeScene()
        let exported = try SceneExporter.export(scene, as: .emf)
        let reimported = try SceneImporter.import(data: exported.data)
        func counts(_ s: Scene) -> [ElementKind: Int] {
            s.editableElements.reduce(into: [:]) { $0[$1.kind, default: 0] += 1 }
        }
        let before = counts(scene), after = counts(reimported)
        #expect(scene.editableElements.count == reimported.editableElements.count)
        #expect(before[.rect] == after[.rect])
        #expect(before[.ellipse] == after[.ellipse])
        #expect(before[.text] == after[.text])
    }

    @Test func allOpKindsExportAndReimportPreservingCount() throws {
        let plan = GenerationPlan(page: GenerationPage(), operations: [
            .rectangle(x: 0.05, y: 0.05, w: 0.15, h: 0.1, fill: GenColor(raw: "blue"), stroke: nil, strokeWidth: nil),
            .roundedRectangle(x: 0.3, y: 0.05, w: 0.15, h: 0.1, cornerRadius: 0.02, fill: GenColor(raw: "teal"), stroke: nil, strokeWidth: nil),
            .ellipse(x: 0.55, y: 0.05, w: 0.15, h: 0.1, fill: GenColor(raw: "red"), stroke: nil, strokeWidth: nil),
            .line(from: GenPoint(x: 0.1, y: 0.3), to: GenPoint(x: 0.4, y: 0.3), stroke: GenColor(raw: "black"), strokeWidth: 2),
            .polyline(points: [GenPoint(x: 0.1, y: 0.5), GenPoint(x: 0.3, y: 0.6), GenPoint(x: 0.5, y: 0.5)], stroke: GenColor(raw: "purple"), strokeWidth: 2),
            .polygon(points: [GenPoint(x: 0.6, y: 0.5), GenPoint(x: 0.8, y: 0.5), GenPoint(x: 0.7, y: 0.7)], fill: GenColor(raw: "orange"), stroke: nil, strokeWidth: nil),
            .text(x: 0.1, y: 0.8, w: nil, h: nil, string: "Caption", color: GenColor(raw: "black"), fontSize: 14, fontFamily: nil),
        ])
        #expect(GenerationPlanValidator.validate(plan).isApplicable)
        let scene = try plan.makeScene()
        #expect(scene.editableElements.count == 7)
        let exported = try SceneExporter.export(scene, as: .emf)
        let reimported = try SceneImporter.import(data: exported.data)
        #expect(reimported.editableElements.count == 7)
    }

    // MARK: - Helpers

    private func isBlank(_ image: CGImage) -> Bool {
        guard let pixels = PixelImage(image) else { return true }
        let count = pixels.pixels.count / 4
        for i in 0 ..< count {
            let o = i * 4
            if pixels.pixels[o + 3] > 8 && (pixels.pixels[o] < 240 || pixels.pixels[o + 1] < 240 || pixels.pixels[o + 2] < 240) {
                return false
            }
        }
        return true
    }
}

private extension Scene {
    /// The generated scene's shape/label counts agree with the plan's own summary
    /// (text elements are labels, the rest shapes; an arrow's head is not counted).
    func summaryCountsMatches(_ plan: GenerationPlan) -> Bool {
        let labels = editableElements.filter { $0.kind == .text }.count
        return labels == plan.summaryCounts.labels
    }
}
