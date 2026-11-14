import CoreGraphics
import EMFEdit
import Foundation
import Testing

// C5f3: the on-device AI quality work.
//
// 1. The @Generable mirror plans (F3) map onto the SAME domain plans and go through the
//    SAME validators as the JSON path — including invalid values the validator rejects.
// 2. The describe quote-grounding post-check strips quotation marks from text that isn't
//    actually in the drawing, so an invented "quote" never shows as a quote.
// These are deterministic and run with no model.

// MARK: - @Generable edit-plan mapping (F3)

@Suite struct DrawingAIGenerableEditTests {

    @MainActor private func twoTextScene() throws -> (Scene, [Int]) {
        var scene = try SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 210, height: 160)))
        let grey = SceneColor(red: 0.6, green: 0.6, blue: 0.6)
        var ids: [Int] = []
        for (i, s) in ["Quarterly Results", "Regional Breakdown"].enumerated() {
            let id = SceneFactory.nextElementID(in: scene)
            scene.insert(SceneFactory.makeText(string: s, originDevice: CGPoint(x: 40, y: 80 + Double(i) * 40),
                                               family: "Helvetica", pointSize: 18, color: grey, id: id,
                                               deviceUnitsPerPoint: scene.deviceUnitsPerPoint), at: scene.elements.count)
            ids.append(id)
        }
        return (scene, ids)
    }

    @Test @MainActor func recolorFillMapsAndValidates() throws {
        guard #available(macOS 26, iOS 26, *) else { return }
        let (scene, ids) = try twoTextScene()
        let gen = GenEditPlan(operations: [
            GenEditOperation(op: .recolorFill, ids: ids, color: "#1F3A93"),
        ])
        let plan = try gen.toDomain()
        #expect(plan.operations.count == 1)
        if case .recolorFill(let got, let color) = plan.operations[0] {
            #expect(got == ids)
            #expect(color.hex == "#1F3A93")
        } else { Issue.record("expected recolorFill") }
        #expect(EditPlanValidator.validate(plan, in: scene).isApplicable)
    }

    @Test @MainActor func invalidColorMapsButValidatorRejects() throws {
        guard #available(macOS 26, iOS 26, *) else { return }
        let (scene, ids) = try twoTextScene()
        // The mapping does NOT validate — a garbage colour maps through, and the shared
        // validator is the gate that rejects it.
        let gen = GenEditPlan(operations: [
            GenEditOperation(op: .recolorFill, ids: ids, color: "not-a-colour"),
        ])
        let plan = try gen.toDomain()
        #expect(plan.operations.count == 1)
        let validation = EditPlanValidator.validate(plan, in: scene)
        #expect(!validation.isApplicable)
        #expect(validation.problems.contains { if case .invalidColor = $0 { return true } else { return false } })
    }

    @Test func opMissingRequiredFieldRejectsWholePlan() {
        guard #available(macOS 26, iOS 26, *) else { return }
        // C3–C7: a single unmappable op (recolorFill with no colour) rejects the WHOLE plan,
        // matching the strict JSON path, rather than silently dropping the bad op.
        let gen = GenEditPlan(operations: [
            GenEditOperation(op: .recolorFill, ids: [1]),
            GenEditOperation(op: .setText, id: 2),
            GenEditOperation(op: .delete),
        ])
        #expect(throws: GenMirrorError.self) { try gen.toDomain() }
    }

    @Test func allMappableOpsMapToDomainVocabulary() throws {
        guard #available(macOS 26, iOS 26, *) else { return }
        let gen = GenEditPlan(operations: [
            GenEditOperation(op: .align, ids: [1, 2], edge: .centerHorizontal),
            GenEditOperation(op: .distribute, ids: [1, 2, 3], axis: .vertical),
            GenEditOperation(op: .scale, ids: [4], factor: 1.3),
            GenEditOperation(op: .setFontSize, id: 5, points: 24),
        ])
        let ops = try gen.toDomain().operations
        #expect(ops.count == 4)
        #expect(ops[0] == .align(ids: [1, 2], edge: .centerHorizontal))
        #expect(ops[1] == .distribute(ids: [1, 2, 3], axis: .vertical))
        #expect(ops[2] == .scale(ids: [4], factor: 1.3))
        #expect(ops[3] == .setFontSize(id: 5, points: 24))
    }
}

// MARK: - @Generable translations mapping (F3)

@Suite struct DrawingAIGenerableTranslateTests {

    @Test func translationsMapAndReconcile() throws {
        guard #available(macOS 26, iOS 26, *) else { return }
        let gen = GenTranslations(translations: [
            GenTranslation(id: 5, text: "Bonjour"),
            GenTranslation(id: 6, text: "Merci"),
        ])
        // Round-trips through the SAME strict decode + reconcile the JSON path uses.
        let entries = try? TextTranslation.decode(fromJSON: gen.toJSON())
        let decoded = try #require(entries)
        switch TextTranslation.reconcile(decoded, requested: [5, 6]) {
        case .success(let map):
            #expect(map[5] == "Bonjour")
            #expect(map[6] == "Merci")
        case .failure(let problem):
            Issue.record("reconcile failed: \(problem)")
        }
    }

    @Test func toJSONEscapesQuotesInText() {
        guard #available(macOS 26, iOS 26, *) else { return }
        let gen = GenTranslations(translations: [GenTranslation(id: 1, text: "say \"hi\"")])
        let entries = try? TextTranslation.decode(fromJSON: gen.toJSON())
        #expect(entries?.first?.text == "say \"hi\"")
    }
}

// MARK: - @Generable generation-plan mapping (F3)

@Suite struct DrawingAIGenerableGenerateTests {

    @Test func shapesMapAndValidate() throws {
        guard #available(macOS 26, iOS 26, *) else { return }
        let gen = GenGeneratePlan(page: .a4Landscape, elements: [
            GenGenerateOperation(op: .rectangle, x: 0.1, y: 0.1, w: 0.2, h: 0.15, fill: "light blue"),
            GenGenerateOperation(op: .text, x: 0.12, y: 0.14, text: "Start", color: "dark blue", fontSize: 16),
        ])
        let plan = try gen.toDomain()
        #expect(plan.page.coordinateSpace == .fraction)
        #expect(plan.operations.count == 2)
        #expect(GenerationPlanValidator.validate(plan).isApplicable)
    }

    @Test func invalidColorMapsButValidatorRejects() throws {
        guard #available(macOS 26, iOS 26, *) else { return }
        let gen = GenGeneratePlan(page: .a4Portrait, elements: [
            GenGenerateOperation(op: .rectangle, x: 0.1, y: 0.1, w: 0.2, h: 0.2, fill: "not-a-colour"),
        ])
        let validation = GenerationPlanValidator.validate(try gen.toDomain())
        #expect(!validation.isApplicable)
        #expect(validation.problems.contains { if case .invalidColor = $0 { return true } else { return false } })
    }

    @Test func lineAndPolylineMapPoints() throws {
        guard #available(macOS 26, iOS 26, *) else { return }
        let gen = GenGeneratePlan(page: .a4Landscape, elements: [
            GenGenerateOperation(op: .line, x1: 0.1, y1: 0.1, x2: 0.4, y2: 0.1, stroke: "black"),
            GenGenerateOperation(op: .polyline, points: [GenPointXY(x: 0.1, y: 0.2), GenPointXY(x: 0.3, y: 0.3)], stroke: "red"),
        ])
        let ops = try gen.toDomain().operations
        #expect(ops.count == 2)
        if case .line(let from, let to, _, _) = ops[0] {
            #expect(from == GenPoint(x: 0.1, y: 0.1))
            #expect(to == GenPoint(x: 0.4, y: 0.1))
        } else { Issue.record("expected line") }
        if case .polyline(let points, _, _) = ops[1] {
            #expect(points == [GenPoint(x: 0.1, y: 0.2), GenPoint(x: 0.3, y: 0.3)])
        } else { Issue.record("expected polyline") }
    }

    @Test func shapeMissingSizeRejectsWholePlan() {
        guard #available(macOS 26, iOS 26, *) else { return }
        // C3–C7: one unmappable element (a rectangle with no w/h) rejects the whole plan.
        let gen = GenGeneratePlan(page: .a4Landscape, elements: [
            GenGenerateOperation(op: .rectangle, x: 0.1, y: 0.1), // no w/h
        ])
        #expect(throws: GenMirrorError.self) { try gen.toDomain() }
    }
}

// MARK: - Describe quote grounding (faithfulness)

@Suite struct DrawingDescribeGroundingTests {
    private let drawing = ["Confined space - atmospheric contaminants", "Permit required before entry"]

    @Test func keepsQuotesThatArePresent() {
        let input = "The sign reads \"Confined space\" at the top."
        #expect(DrawingDescribeGrounding.groundQuotes(in: input, drawingText: drawing) == input)
    }

    @Test func stripsMarksFromInventedQuotes() {
        let input = "It warns of a \"danger zone\" and lists hazards."
        let out = DrawingDescribeGrounding.groundQuotes(in: input, drawingText: drawing)
        #expect(out == "It warns of a danger zone and lists hazards.")
        #expect(!out.contains("\""))
    }

    @Test func handlesSmartQuotesAndKeepsWords() {
        let input = "Labelled \u{201C}flux capacitor\u{201D} prominently."
        let out = DrawingDescribeGrounding.groundQuotes(in: input, drawingText: drawing)
        #expect(out == "Labelled flux capacitor prominently.")
    }

    @Test func matchIsWhitespaceNormalisedAndCaseInsensitive() {
        // Spans two runs and differs in case/spacing, but is still "present".
        #expect(DrawingDescribeGrounding.isQuoteSupported("CONFINED   SPACE", inDrawingText: drawing))
        #expect(DrawingDescribeGrounding.isQuoteSupported("contaminants Permit required", inDrawingText: drawing))
        #expect(!DrawingDescribeGrounding.isQuoteSupported("evacuation plan", inDrawingText: drawing))
    }

    @Test func mixedQuotesStripOnlyUnsupported() {
        let input = "Shows \"Permit required\" and a \"fire exit\" marker."
        let out = DrawingDescribeGrounding.groundQuotes(in: input, drawingText: drawing)
        #expect(out == "Shows \"Permit required\" and a fire exit marker.")
    }

    @Test func noQuotesIsUnchanged() {
        let input = "A safety notice about confined spaces."
        #expect(DrawingDescribeGrounding.groundQuotes(in: input, drawingText: drawing) == input)
    }

    // FM-6: single smart quotes and guillemets are grounded too.
    @Test func handlesSingleSmartQuotesAndGuillemets() {
        let singles = "It says \u{2018}danger zone\u{2019} boldly."
        #expect(DrawingDescribeGrounding.groundQuotes(in: singles, drawingText: drawing) == "It says danger zone boldly.")
        let guillemets = "Marked \u{00AB}Permit required\u{00BB} here."
        #expect(DrawingDescribeGrounding.groundQuotes(in: guillemets, drawingText: drawing) == guillemets)   // present ⇒ kept
    }

    // FM-6: a quote is matched on word boundaries, so a short invented quote isn't
    // "supported" just by sitting inside a larger word.
    @Test func matchesOnWordBoundaries() {
        // "mit" sits inside "permit" but isn't a word there ⇒ not supported.
        #expect(!DrawingDescribeGrounding.isQuoteSupported("mit", inDrawingText: drawing))
        // The whole word "Permit" is supported.
        #expect(DrawingDescribeGrounding.isQuoteSupported("Permit", inDrawingText: drawing))
    }
}
