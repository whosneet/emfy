import CoreGraphics
import EMFParse
import EMFRender
import Foundation

// MARK: - Building the AI context from a loaded drawing (A1a)
//
// Turns a drawing's bytes into the bounded `DrawingAIContext` (for grounding the
// prompt) and the `DrawingAIToolData` (for the read-only tools). It parses through
// EMFKit's one front door — exactly as the viewer, the Quick Look extensions and
// the F4 intents do — so there is no new interpreter, and runs off the main actor.
// Everything it produces is sanitised and bounded before it reaches the model.

enum DrawingAIContextProvider {
    /// The paired context + tool data for one drawing.
    struct Bundle: Sendable {
        var context: DrawingAIContext
        var toolData: DrawingAIToolData
    }

    /// Builds the context + tool data from a drawing's bytes. `unsupportedNotes` are
    /// the viewer's already-computed "What Emfy couldn't show" summaries, passed in
    /// so this doesn't re-derive the render log. Returns `nil` for a non-metafile.
    /// Safe to call from a detached task (`Sendable` result).
    static func make(data: Data, fileName: String, unsupportedNotes: [String]) -> Bundle? {
        guard let opened = try? OpenedMetafile.open(data),
              let prepared = MetafileRenderer.prepare(opened) else {
            return nil
        }
        let observation = MetafileRenderer.observe(prepared)
        let runs = DrawingTextExtractor.readingOrder(DrawingTextExtractor.extract(from: observation))
        let textLines = runs.filter { $0.source == .drawing }.map(\.text)
        let pictures = DrawingPictureEnumerator.pictures(from: observation)
        let recordCount = prepared.recordKinds.reduce(0) { $0 + $1.count }
        let info = DrawingInfo(
            format: MetafileFormatLabel.names(for: fileName).full,
            pageSizeMM: AppIntentDrawing.pageSizeMM(opened: opened),
            recordCount: recordCount,
            hasText: !textLines.isEmpty,
            hasPictures: !pictures.isEmpty
        )
        let context = DrawingAIContext.build(
            format: info.format,
            pageSizeMM: info.pageSizeMM,
            recordKinds: prepared.recordKinds,
            textRuns: textLines,
            hasPictures: info.hasPictures,
            unsupportedNotes: unsupportedNotes
        )
        let toolData = DrawingAIToolData(textLines: textLines, info: info, recordKinds: prepared.recordKinds)
        return Bundle(context: context, toolData: toolData)
    }
}
