import CoreGraphics
import EMFRender
import Foundation
import UniformTypeIdentifiers

/// The two export formats Emfy offers. Both render through EMFKit's one renderer,
/// so iOS produces byte-for-byte the same PNG and PDF the Mac app does.
enum ExportFormat: Sendable {
    case png
    case pdf

    var utType: UTType { self == .png ? .png : .pdf }
    var pathExtension: String { self == .png ? "png" : "pdf" }

    /// The Mac's own failure wording, reused verbatim (primer: use the Mac's
    /// wording where it exists — see `EMFDocumentView.exportPNG/exportPDF`).
    var failureMessage: String {
        self == .png ? MetafileExport.pngEncodeFailure : MetafileExport.pdfGenerateFailure
    }
}

/// Pure, framework-neutral export helpers shared by the viewer's Share menu and
/// the file-details export rows. Rendering reuses the Mac's exact export path —
/// `MetafileRenderer.makeImage(_:scale:)` + `EMFExport.pngData` for PNG, and
/// `MetafileRenderer.pdfData` for PDF — so the bytes and dimensions match the Mac
/// for the same file. Nothing here touches UIKit or the main actor; the callers
/// run it off-main and cancellably.
enum MetafileExport {
    /// The on-screen/export render scale the Mac uses (`EMFDocument.renderScale`).
    /// Keeping it identical is what guarantees byte-parity of the exported PNG;
    /// the renderer's own 16384-per-side / 32 MP caps apply on both platforms.
    static let renderScale: CGFloat = 2

    // The Mac's export failure strings (EMFDocumentView), reused for parity.
    static let pngEncodeFailure = "Emfy could not encode a PNG for this document."
    static let pdfGenerateFailure = "Emfy could not generate a PDF for this document."
    /// New wording — the Mac has no "Share File" action to borrow from.
    static let shareFileFailure = "Emfy couldn’t read the original file to share it."

    /// The exported bytes for `format`, or `nil` only on an allocation/encode
    /// failure. `Prepared` is `Sendable`, so this is safe to call from a detached
    /// task.
    static func data(for format: ExportFormat, prepared: MetafileRenderer.Prepared) -> Data? {
        switch format {
        case .png: return pngData(prepared)
        case .pdf: return pdfData(prepared)
        }
    }

    /// PNG bytes identical to the Mac's export: render at `renderScale`, then
    /// encode with the shared `EMFExport.pngData` (ImageIO).
    static func pngData(_ prepared: MetafileRenderer.Prepared) -> Data? {
        guard let (image, _) = MetafileRenderer.makeImage(prepared, scale: renderScale) else {
            return nil
        }
        return EMFExport.pngData(from: image)
    }

    /// Single-page true-vector PDF bytes, straight from EMFKit (same page sizing
    /// as the Mac).
    static func pdfData(_ prepared: MetafileRenderer.Prepared) -> Data? {
        MetafileRenderer.pdfData(prepared)
    }

    /// Writes `data` into a fresh, uniquely-named temporary directory under
    /// `fileName`, so the share sheet and Files show the right name and the
    /// extension-derived type. The caller removes the directory once the share
    /// finishes (`MetafileExportController.cleanupTemp`).
    static func writeTemporary(_ data: Data, fileName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(sanitisedFileName(fileName))
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Strips path separators from a file name so a crafted recents entry can't
    /// escape the temporary directory, and never yields an empty name.
    static func sanitisedFileName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Metafile" : cleaned
    }
}

/// Runs one off-main, cancellable export render and shows a spinner only if it
/// takes longer than ~0.3 s. Starting a new render cancels the previous one, and
/// a generation token keeps a stale render from touching the busy flag or
/// delivering a late result. `@State`-owned by each surface (the Share menu
/// controller and the file-details rows), so each presents its own spinner.
@MainActor
final class ExportTaskRunner {
    private var task: Task<Void, Never>?
    private var generation = 0

    /// - Parameters:
    ///   - setBusy: toggles the surface's "rendering" flag (drives the spinner).
    ///   - render: the pure, `Sendable` render, run on a detached task.
    ///   - done: receives the render result on the main actor; skipped if a newer
    ///     render has started or this one was cancelled.
    func run<T: Sendable>(
        setBusy: @escaping @MainActor (Bool) -> Void,
        render: @escaping @Sendable () -> T,
        done: @escaping @MainActor (T) -> Void
    ) {
        task?.cancel()
        generation &+= 1
        let generationAtStart = generation
        task = Task { @MainActor in
            let spinner = Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.3))
                guard !Task.isCancelled, generationAtStart == self.generation else { return }
                setBusy(true)
            }
            let value = await Task.detached(priority: .userInitiated, operation: render).value
            spinner.cancel()
            guard generationAtStart == self.generation else { return }
            setBusy(false)
            if Task.isCancelled { return }
            done(value)
        }
    }

    /// Cancels any in-flight render (e.g. the view disappeared). The caller
    /// resets its own busy flag.
    func cancel() {
        task?.cancel()
        task = nil
        generation &+= 1
    }
}
