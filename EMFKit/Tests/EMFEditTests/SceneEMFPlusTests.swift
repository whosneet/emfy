import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import Testing
@testable import EMFEdit

/// Slice E1a2 gate: EMF+ drawing records lift into editable scene elements (not a
/// single passthrough blob), the record partition stays complete and disjoint
/// including the new `fallback` bucket, and original requested font faces survive.
struct SceneEMFPlusTests {

    /// The committed EMF+ files (handmade-emfplus-* plus the dual gate file).
    private static let emfPlusFiles = [
        "handmade-emfplus-shapes.emf",
        "handmade-emfplus-text.emf",
        "handmade-emfplus-image.emf",
        "handmade-emfplus-dual.emf",
    ]

    private static func scene(_ name: String) throws -> Scene {
        let data = try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent(name))
        return try SceneImporter.import(data: data)
    }

    // MARK: - Partition (complete, disjoint, fallback accounted)

    @Test(arguments: emfPlusFiles)
    func emfPlusPartitionIsCompleteDisjointAndFallbackAccounted(_ name: String) throws {
        let scene = try Self.scene(name)
        try #require(scene.source.renderPath == .emfPlus, "\(name) did not take the EMF+ path")

        // Complete and disjoint over EVERY source record, including `fallback`.
        #expect(scene.partition.isComplete, "\(name): partition incomplete — \(scene.partition)")
        let p = scene.partition
        let buckets = [p.structural, p.state, p.drawing, p.passthrough, p.fallback]
        for i in 0 ..< buckets.count {
            for j in (i + 1) ..< buckets.count {
                #expect(buckets[i].isDisjoint(with: buckets[j]), "\(name): buckets \(i)/\(j) overlap")
            }
        }
        let union = buckets.reduce(into: Set<Int>()) { $0.formUnion($1) }
        #expect(union == Set(0 ..< scene.source.unitCount), "\(name): union is not the whole file")

        // The GDI fallback never becomes an element — the exporter regenerates it.
        let elementRecords = Set(scene.elements.flatMap { $0.provenance.sourceRecordIndices })
        #expect(p.fallback.isDisjoint(with: elementRecords), "\(name): a fallback record owns an element")
    }

    // MARK: - Lift (editable elements by kind)

    @Test func everyEMFPlusFileWithDrawingLiftsEditableElements() throws {
        for name in Self.emfPlusFiles {
            let scene = try Self.scene(name)
            // Each file has EMF+ drawing content, so the drawing bucket and the
            // editable element list are both non-empty (nothing is a whole-file blob).
            #expect(!scene.partition.drawing.isEmpty, "\(name): no drawing records lifted")
            #expect(!scene.editableElements.isEmpty, "\(name): zero editable elements")
        }
    }

    @Test func liftsEMFPlusShapesByKind() throws {
        let scene = try Self.scene("handmade-emfplus-shapes.emf")
        let kinds = scene.kindCounts
        #expect((kinds[.rect] ?? 0) >= 1, "expected filled rectangles")
        #expect((kinds[.ellipse] ?? 0) >= 1, "expected an ellipse")
        #expect(scene.elements.allSatisfy { $0.kind != .passthrough }, "shapes should lift fully editable")
    }

    // MARK: - EMF+ fill value types (solid + linear gradient with alpha)

    @Test func liftsEMFPlusLinearGradientFill() throws {
        let scene = try Self.scene("handmade-emfplus-shapes.emf")
        let gradients = scene.elements.compactMap { $0.style.fill?.gradient }
        try #require(!gradients.isEmpty, "no linear-gradient fill lifted from the shapes file")
        for gradient in gradients {
            #expect(gradient.stops.count >= 2, "a gradient needs at least two stops")
            #expect(gradient.startDevice != gradient.endDevice, "gradient axis is degenerate")
            // The alpha channel survives the lift (ARGB → SceneColor).
            #expect(gradient.stops.allSatisfy { $0.color.alpha >= 0 && $0.color.alpha <= 1 })
        }
    }

    @Test func liftsEMFPlusSolidFillsWithAlphaChannel() throws {
        let scene = try Self.scene("handmade-emfplus-shapes.emf")
        let solids = scene.elements.compactMap { element -> SceneColor? in
            guard let fill = element.style.fill, fill.gradient == nil else { return nil }
            return fill.color
        }
        try #require(!solids.isEmpty, "no solid fill lifted")
        // SceneColor carries a normalised alpha even for opaque EMF+ fills.
        #expect(solids.allSatisfy { $0.alpha >= 0 && $0.alpha <= 1 })
    }

    // MARK: - EMF+ images

    @Test func liftsEMFPlusImages() throws {
        let scene = try Self.scene("handmade-emfplus-image.emf")
        let images = scene.elements.compactMap { $0.kind == .image ? $0.image : nil }
        try #require(!images.isEmpty, "no EMF+ image lifted")
        for image in images {
            #expect(image.emfPlusImage != nil, "image element carries no EMF+ image object")
            #expect(image.sourceDIB == nil, "an EMF+ image must not carry a GDI DIB")
            #expect(image.destRectDevice.width > 0 && image.destRectDevice.height > 0, "degenerate destination")
        }
    }

    // MARK: - Fallback bucket (dual file)

    @Test func dualFileRoutesGDIFallbackToFallbackBucket() throws {
        let scene = try Self.scene("handmade-emfplus-dual.emf")
        // A dual file carries a complete GDI fallback the EMF+ engine does not
        // play; those records are accounted for in the fallback bucket, not lifted.
        #expect(!scene.partition.fallback.isEmpty, "dual file has no fallback records")
        #expect(!scene.editableElements.isEmpty, "dual file lifted no editable EMF+ content")
    }

    // MARK: - Original requested face names (E1b exports the file's font)

    @Test func gdiTextCarriesOriginalRequestedFaceNames() throws {
        let scene = try Self.scene("gate-p4-text.emf")
        let requested = Set(scene.elements.compactMap { $0.text?.requestedFamily })
        #expect(requested.contains("Arial"), "Arial not carried as a requested face")
        #expect(requested.contains("Times New Roman"), "Times New Roman not carried as a requested face")
        // GDI text has no EMF+ sizing.
        #expect(scene.elements.compactMap(\.text).allSatisfy { !$0.isEMFPlus })
    }

    @Test func emfPlusTextCarriesOriginalRequestedFaceAndEmSize() throws {
        let scene = try Self.scene("handmade-emfplus-text.emf")
        let texts = scene.elements.compactMap { $0.kind == .text ? $0.text : nil }
        try #require(!texts.isEmpty, "no EMF+ text lifted")
        for text in texts {
            #expect(text.isEMFPlus, "EMF+ text run not flagged")
            #expect(text.requestedFamily == "Arial", "EMF+ requested family not preserved: \(text.requestedFamily)")
            #expect(!text.fontFamily.isEmpty, "no resolved family")
            #expect(text.emSize > 0, "EMF+ text carries no em size")
            #expect(!text.string.isEmpty, "empty text run")
        }
    }

    // MARK: - Hostile EMF+ input (bounded, typed, never traps)

    @Test func truncatedEMFPlusFileStaysBounded() throws {
        let full = try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent("handmade-emfplus-dual.emf"))
        for fraction in [0.1, 0.3, 0.5, 0.7, 0.9] {
            let cut = Data(full.prefix(Int(Double(full.count) * fraction)))
            if let scene = try? SceneImporter.import(data: cut) {
                #expect(scene.partition.isComplete, "truncated-\(fraction): partition not complete")
                // Rendering the truncated scene is bounded and never traps.
                #expect(SceneRenderer.makeImage(scene) != nil)
            }
        }
    }
}
