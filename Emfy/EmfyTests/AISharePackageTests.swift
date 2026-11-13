import CoreGraphics
import Foundation
import Testing

// A3b unit tests for the pure "Send to AI…" package builder: the render-scale rule,
// the edited-vs-original source decision, the OCR-included rule, the text cap, and the
// exact summary-text format. The platform glue (NSSharingServicePicker / UIActivity-
// ViewController) isn't tested here; everything that decides WHAT is sent is.

@Suite struct AISharePackageTests {

    // MARK: render scale

    @Test func smallDrawingRendersAtTwoX() {
        #expect(AISharePackage.renderScale(naturalSize: CGSize(width: 400, height: 300)) == 2)
    }

    @Test func largeDrawingIsCappedToTheLongSide() {
        // 3000 px long side at 2× would be 6000 px; the cap pulls it to 4096/3000.
        let scale = AISharePackage.renderScale(naturalSize: CGSize(width: 3000, height: 1000))
        #expect(scale == AISharePackage.maxLongSidePixels / 3000)
        #expect(3000 * scale <= AISharePackage.maxLongSidePixels)
    }

    @Test func justUnderTheCapStaysAtTwoX() {
        // 2048 px at 2× is exactly 4096 — the cap, still 2×.
        #expect(AISharePackage.renderScale(naturalSize: CGSize(width: 2048, height: 10)) == 2)
    }

    @Test func degenerateSizeFallsBackToTwoX() {
        #expect(AISharePackage.renderScale(naturalSize: .zero) == 2)
    }

    // MARK: source decision (always whole-drawing, never a subset)

    @Test func sourceUsesEditedSceneOnlyWhenDiverged() {
        #expect(AISharePackage.outputSource(isEditing: false, hasDiverged: false) == .original)
        #expect(AISharePackage.outputSource(isEditing: true, hasDiverged: false) == .original)
        #expect(AISharePackage.outputSource(isEditing: true, hasDiverged: true) == .editedScene)
    }

    // MARK: OCR-included rule

    @Test func ocrIncludedOnlyWhenEnabledAndCached() {
        #expect(AISharePackage.shouldIncludeOCR(ocrEnabled: true, hasCachedPictureText: true))
        #expect(!AISharePackage.shouldIncludeOCR(ocrEnabled: true, hasCachedPictureText: false))
        #expect(!AISharePackage.shouldIncludeOCR(ocrEnabled: false, hasCachedPictureText: true))
        #expect(!AISharePackage.shouldIncludeOCR(ocrEnabled: false, hasCachedPictureText: false))
    }

    @Test func combinedTextFoldsInPictureTextOnlyWhenIncluded() {
        let drawing = [run("Title", .drawing)]
        let picture = [run("Scanned caption", .picture)]
        let without = AISharePackage.combinedText(drawingRuns: drawing, pictureRuns: picture, includeOCR: false)
        #expect(without == "Title")
        let with = AISharePackage.combinedText(drawingRuns: drawing, pictureRuns: picture, includeOCR: true)
        #expect(with.contains("Title"))
        #expect(with.contains("Text in pictures:"))
        #expect(with.contains("Scanned caption"))
    }

    // MARK: text cap

    @Test func textUnderTheCapIsUnchanged() {
        let result = AISharePackage.cappedText("short")
        #expect(result.text == "short")
        #expect(!result.truncated)
    }

    @Test func textOverTheCapIsTruncated() {
        let long = String(repeating: "a", count: AISharePackage.maxTextCharacters + 500)
        let result = AISharePackage.cappedText(long)
        #expect(result.text.count == AISharePackage.maxTextCharacters)
        #expect(result.truncated)
    }

    // MARK: summary format

    @Test func summaryListsFileFormatPageSizeRecordsAndText() {
        let summary = AISharePackage.summary(
            fileName: "diagram.emf",
            format: "Enhanced Metafile",
            pageSizeMM: CGSize(width: 210, height: 297),
            recordCount: 42,
            allText: "Site plan\nLevel 2")
        #expect(summary == """
        diagram.emf

        Format: Enhanced Metafile
        Page size: 210.0 × 297.0 mm
        Records: 42

        Text in the drawing:
        Site plan
        Level 2
        """)
    }

    @Test func summaryOmitsPageSizeWhenUnknown() {
        let summary = AISharePackage.summary(
            fileName: "old.wmf", format: "Windows Metafile",
            pageSizeMM: nil, recordCount: 7, allText: "Hello")
        #expect(!summary.contains("Page size:"))
        #expect(summary.contains("Format: Windows Metafile"))
        #expect(summary.contains("Records: 7"))
    }

    @Test func summaryNotesWhenThereIsNoText() {
        let summary = AISharePackage.summary(
            fileName: "blank.emf", format: "Enhanced Metafile",
            pageSizeMM: nil, recordCount: 3, allText: "")
        #expect(summary.contains("Text in the drawing:\n(no text)"))
    }

    @Test func summaryAppendsATruncationNoteWhenTextIsCut() {
        let long = String(repeating: "x", count: AISharePackage.maxTextCharacters + 1)
        let summary = AISharePackage.summary(
            fileName: "big.emf", format: "Enhanced Metafile",
            pageSizeMM: nil, recordCount: 1, allText: long)
        #expect(summary.contains("[Text truncated at \(AISharePackage.maxTextCharacters) characters.]"))
    }

    // MARK: helpers

    private func run(_ text: String, _ source: DrawingTextRun.Source) -> DrawingTextRun {
        DrawingTextRun(text: text, boundsDevice: .zero, fontFamily: nil, fontSize: nil, source: source)
    }
}
