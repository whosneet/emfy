import CoreGraphics
import Foundation
import Testing

// F1 unit tests for the pure Copy/drag representation plan (`DrawingClipboard`) and
// the edited-scene-vs-original source decision (`OutputSource`) shared by Print and
// Copy.

@Suite struct DrawingClipboardTests {

    // MARK: representations

    @Test func wholeUneditedEMFOffersPDFPNGAndOriginal() {
        let reps = DrawingClipboard.representations(
            naturalSize: CGSize(width: 400, height: 300),
            pngScale: 2, areaCap: ExportScale.areaCap,
            isEdited: false, isSubset: false, originalType: .emf)
        #expect(reps == [.pdf, .png(width: 800, height: 600, scale: 2), .originalEMF])
    }

    @Test func editedDrawingDropsTheOriginal() {
        let reps = DrawingClipboard.representations(
            naturalSize: CGSize(width: 400, height: 300),
            pngScale: 2, areaCap: ExportScale.areaCap,
            isEdited: true, isSubset: false, originalType: .emf)
        #expect(reps == [.pdf, .png(width: 800, height: 600, scale: 2)])
        #expect(!reps.contains(.originalEMF))
    }

    @Test func selectionSubsetDropsTheOriginal() {
        let reps = DrawingClipboard.representations(
            naturalSize: CGSize(width: 100, height: 100),
            pngScale: 2, areaCap: ExportScale.areaCap,
            isEdited: true, isSubset: true, originalType: .emf)
        #expect(!reps.contains(.originalEMF))
    }

    @Test func nonEMFOriginalIsNeverOffered() {
        // A WMF document: the original bytes are a WMF, not the EMF type, so Copy only
        // puts the rendered PDF + PNG.
        let reps = DrawingClipboard.representations(
            naturalSize: CGSize(width: 100, height: 100),
            pngScale: 2, areaCap: ExportScale.areaCap,
            isEdited: false, isSubset: false, originalType: .other)
        #expect(!reps.contains(.originalEMF))
    }

    @Test func pngSizeIsReducedToTheAreaCap() {
        // A large drawing at 3× would exceed the 32 MP cap; the PNG is reduced to the
        // largest multiplier that fits (the same rule as every other export).
        let big = CGSize(width: 6000, height: 4000)   // base area 24 MP
        let reps = DrawingClipboard.representations(
            naturalSize: big, pngScale: 3, areaCap: ExportScale.areaCap,
            isEdited: false, isSubset: false, originalType: .other)
        guard case .png(let w, let h, let scale) = reps[1] else {
            Issue.record("expected a PNG representation"); return
        }
        #expect(Int64(w) * Int64(h) <= Int64(ExportScale.areaCap))
        #expect(scale < 3)   // reduced from the requested 3×
    }

    @Test func includesOriginalOnlyForUneditedWholeEMF() {
        #expect(DrawingClipboard.includesOriginal(isEdited: false, isSubset: false, originalType: .emf))
        #expect(!DrawingClipboard.includesOriginal(isEdited: true, isSubset: false, originalType: .emf))
        #expect(!DrawingClipboard.includesOriginal(isEdited: false, isSubset: true, originalType: .emf))
        #expect(!DrawingClipboard.includesOriginal(isEdited: false, isSubset: false, originalType: .other))
    }

    // MARK: output source (edited vs original)

    @Test func wholeDrawingUsesEditedSceneOnlyWhenDiverged() {
        #expect(OutputSource.wholeDrawing(isEditing: false, hasDiverged: false) == .original)
        #expect(OutputSource.wholeDrawing(isEditing: true, hasDiverged: false) == .original)
        #expect(OutputSource.wholeDrawing(isEditing: true, hasDiverged: true) == .editedScene)
    }

    @Test func copyNarrowsToSelectionSubsetInEditMode() {
        #expect(OutputSource.forCopy(isEditing: true, hasDiverged: true, selection: [1, 2]) == .selectionSubset([1, 2]))
        // No selection → the whole-drawing rule applies.
        #expect(OutputSource.forCopy(isEditing: true, hasDiverged: true, selection: []) == .editedScene)
        #expect(OutputSource.forCopy(isEditing: false, hasDiverged: false, selection: []) == .original)
    }

    @Test func copySubsetNeedsEditMode() {
        // A selection set that somehow survives outside edit mode never narrows output.
        #expect(OutputSource.forCopy(isEditing: false, hasDiverged: false, selection: [1]) == .original)
    }
}
