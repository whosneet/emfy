import AppKit
import EMFEdit
import EMFRender
import SwiftUI

/// Drives the Mac viewer's Export and Share (C3b scope 4, 5), hoisted out of the
/// inspector so Export works with the inspector closed. One per open document,
/// owned by `MacViewerPane`.
///
/// Every PNG/PDF render runs off-main and cancellably through `ExportTaskRunner`,
/// surfacing a spinner only past ~0.3 s, and the bytes come from the shared
/// `MetafileExport.data` — identical to the long-standing export path. Export opens
/// a `fileExporter`; Share stages a temp file under `ExportTemp`'s `EmfyExport-`
/// prefix (so the launch sweep reclaims it) and presents an `NSSharingServicePicker`.
///
/// `NSSharingServicePicker` is used rather than `ShareLink` because the render must
/// finish — off-main, cancellable, with our spinner — *before* anything is
/// presented; `ShareLink` owns the tap and presents immediately, so it can't host
/// that step (the same reasoning as the iOS viewer's share sheet).
@MainActor
@Observable
final class MacViewerExporter {
    /// Drives the "preparing" spinner for both Export and Share.
    var isRendering = false
    /// Non-nil presents the "Export Failed" alert.
    var errorMessage: String?

    // Export-to-file state, bound to `MacViewerPane`'s `fileExporter`s.
    var isExportingPNG = false
    var isExportingPDF = false
    var isExportingSVG = false
    var pngDocument = PNGExportDocument(data: Data())
    var pdfDocument = PDFExportDocument(data: Data())
    var svgDocument = SVGExportDocument(data: Data())
    // "Save a Copy as EMF…" from the WMF save confirmation (E2a-5). Reuses the plain
    // `MetafileCopyDocument` (write-only data under the chosen name).
    var isExportingSceneEMF = false
    var sceneCopyDocument = MetafileCopyDocument(data: Data())

    /// Non-nil presents the share picker (consumed by `MacSharePresenter`).
    var sharePayload: MacSharePayload?
    /// Non-nil presents the "Send to AI…" share picker (consumed by `MacAISharePresenter`).
    var aiSharePayload: MacAISharePayload?

    @ObservationIgnored private let runner = ExportTaskRunner()
    /// The in-flight "Share File" resolve/stage task, so a repeat tap cancels it.
    @ObservationIgnored private var shareOriginalTask: Task<Void, Never>?
    /// The in-flight SVG resolve+import+serialise task, so a repeat tap cancels it.
    @ObservationIgnored private var svgTask: Task<Void, Never>?
    /// The in-flight "Send to AI…" resolve/render task, so a repeat tap cancels it.
    @ObservationIgnored private var aiShareTask: Task<Void, Never>?
    /// The temp directory of the file currently staged for sharing.
    @ObservationIgnored private var tempCleanupURL: URL?
    /// The temp directory of the original file staged for a Send-to-AI opt-in.
    @ObservationIgnored private var aiTempCleanupURL: URL?

    // MARK: - Export to file

    /// Opens the file exporter for an already-serialised EMF copy of the edited scene
    /// ("Save a Copy as EMF…", E2a-5).
    func exportSceneCopy(data: Data) {
        sceneCopyDocument = MetafileCopyDocument(data: data)
        isExportingSceneEMF = true
    }

    /// Renders `format` off-main, then opens the `fileExporter` for it. `scale`
    /// and `background` carry the Export settings into the PNG render (S1a-6).
    func exportToFile(
        _ format: ExportFormat,
        prepared: MetafileRenderer.Prepared,
        scale: CGFloat,
        background: RenderBackground,
        options: RenderOptions
    ) {
        runner.run(
            setBusy: { [weak self] busy in self?.isRendering = busy },
            render: { MetafileExport.data(for: format, prepared: prepared, scale: scale, background: background, options: options) },
            done: { [weak self] data in
                guard let self else { return }
                guard let data else { self.errorMessage = format.failureMessage; return }
                switch format {
                case .png:
                    self.pngDocument = PNGExportDocument(data: data)
                    self.isExportingPNG = true
                case .pdf:
                    self.pdfDocument = PDFExportDocument(data: data)
                    self.isExportingPDF = true
                }
            }
        )
    }

    // MARK: - SVG export (F2)

    /// Exports the scene to SVG and opens the `fileExporter` for it. Unlike PNG/PDF,
    /// SVG is built from the imported scene (`SceneImporter` → `SceneSVGExporter`), so
    /// it resolves the original bytes and serialises off-main through `runSVG`.
    func exportSVGToFile(entry: RecentEntry, store: RecentsStore) {
        runSVG(entry: entry, store: store) { [weak self] data in
            self?.svgDocument = SVGExportDocument(data: data)
            self?.isExportingSVG = true
        }
    }

    /// Shares the scene as SVG under "<base>.svg".
    func shareSVG(entry: RecentEntry, store: RecentsStore, baseName: String) {
        runSVG(entry: entry, store: store) { [weak self] data in
            self?.presentShare(data: data, fileName: "\(baseName).svg", failure: SVGExport.generateFailure)
        }
    }

    /// Resolves the original bytes, imports the scene and serialises SVG off-main,
    /// then delivers the bytes on the main actor. A spinner shows past ~0.3 s; one SVG
    /// job at a time, and a repeat tap cancels the prior one. The fidelity warnings on
    /// the result are not surfaced yet — carried to E2 (see the brief).
    private func runSVG(entry: RecentEntry, store: RecentsStore, deliver: @escaping @MainActor (Data) -> Void) {
        runner.cancel()
        svgTask?.cancel()
        isRendering = false
        svgTask = Task { @MainActor in
            let spinner = Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.3))
                if !Task.isCancelled { self.isRendering = true }
            }
            defer {
                spinner.cancel()
                self.isRendering = false
            }
            guard let original = try? await store.resolveData(for: entry) else {
                if !Task.isCancelled { self.errorMessage = SVGExport.generateFailure }
                return
            }
            if Task.isCancelled { return }
            let produced = await Task.detached(priority: .userInitiated) { SVGExport.data(from: original) }.value
            if Task.isCancelled { return }
            guard let produced else { self.errorMessage = SVGExport.generateFailure; return }
            deliver(produced.data)
        }
    }

    // MARK: - Share

    /// Shares the original bytes (.emf/.wmf/.emz/.wmz) under their real file name.
    func shareOriginal(entry: RecentEntry, store: RecentsStore) {
        runner.cancel()
        shareOriginalTask?.cancel()
        isRendering = false
        shareOriginalTask = Task { @MainActor in
            let spinner = Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.3))
                if !Task.isCancelled { self.isRendering = true }
            }
            defer {
                spinner.cancel()
                self.isRendering = false
            }
            do {
                let data = try await store.resolveData(for: entry)
                if Task.isCancelled { return }
                presentShare(data: data, fileName: entry.displayName, failure: MetafileExport.shareFileFailure)
            } catch {
                if !Task.isCancelled { errorMessage = MetafileExport.shareFileFailure }
            }
        }
    }

    /// Renders `format` off-main, then presents the share picker with "<base>.<ext>".
    /// `scale` and `background` carry the Export settings into the PNG render (S1a-6).
    func share(
        _ format: ExportFormat,
        prepared: MetafileRenderer.Prepared,
        baseName: String,
        scale: CGFloat,
        background: RenderBackground,
        options: RenderOptions
    ) {
        runner.run(
            setBusy: { [weak self] busy in self?.isRendering = busy },
            render: { MetafileExport.data(for: format, prepared: prepared, scale: scale, background: background, options: options) },
            done: { [weak self] data in
                guard let self else { return }
                guard let data else { self.errorMessage = format.failureMessage; return }
                self.presentShare(
                    data: data,
                    fileName: "\(baseName).\(format.pathExtension)",
                    failure: format.failureMessage
                )
            }
        )
    }

    // MARK: - Send to AI… (A3b)

    /// Packages the drawing for an AI app the user already has — a 2× PNG and a plain-text
    /// summary (file name, format, page size, record count, Copy All Text) — and hands them
    /// to `NSSharingServicePicker`. Emfy sends nothing over the network. `includeOriginal`
    /// (default off, set in the pre-sheet) also attaches the original file. Renders off-main
    /// through `AISharePackageProducer`; a spinner shows past ~0.3 s.
    func sendToAI(
        entry: RecentEntry,
        store: RecentsStore,
        source: OutputSource,
        prepared: MetafileRenderer.Prepared,
        editedScene: EMFEdit.Scene?,
        allText: String,
        recordCount: Int,
        background: RenderBackground,
        options: RenderOptions,
        includeOriginal: Bool
    ) {
        runner.cancel()
        aiShareTask?.cancel()
        isRendering = false
        let fileName = entry.displayName
        aiShareTask = Task { @MainActor in
            let spinner = Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.3))
                if !Task.isCancelled { self.isRendering = true }
            }
            defer {
                spinner.cancel()
                self.isRendering = false
            }
            guard let data = try? await store.resolveData(for: entry) else {
                if !Task.isCancelled { self.errorMessage = AISharePackage.shareFailure }
                return
            }
            if Task.isCancelled { return }
            let package = await Task.detached(priority: .userInitiated) {
                AISharePackageProducer.make(
                    resolvedData: data, fileName: fileName, allText: allText, recordCount: recordCount,
                    source: source, prepared: prepared, editedScene: editedScene,
                    background: background, options: options, includeOriginal: includeOriginal)
            }.value
            if Task.isCancelled { return }
            guard let pngData = package.pngData, let image = NSImage(data: pngData) else {
                self.errorMessage = AISharePackage.shareFailure
                return
            }
            self.presentAIShare(image: image, text: package.summary, originalData: package.originalData, fileName: fileName)
        }
    }

    private func presentAIShare(image: NSImage, text: String, originalData: Data?, fileName: String) {
        // Reclaim a prior opt-in's temp directory before staging a new one.
        cleanupAITemp()
        var fileURL: URL?
        if let originalData, let url = try? MetafileExport.writeTemporary(originalData, fileName: fileName) {
            aiTempCleanupURL = url.deletingLastPathComponent()
            fileURL = url
        }
        aiSharePayload = MacAISharePayload(image: image, text: text, fileURL: fileURL)
    }

    private func cleanupAITemp() {
        if let directory = aiTempCleanupURL {
            try? FileManager.default.removeItem(at: directory)
        }
        aiTempCleanupURL = nil
    }

    /// Cancels any in-flight render (the viewer disappeared).
    func cancelOngoing() {
        runner.cancel()
        shareOriginalTask?.cancel()
        svgTask?.cancel()
        aiShareTask?.cancel()
        isRendering = false
    }

    private func presentShare(data: Data, fileName: String, failure: String) {
        // Reclaim a prior share's temp directory before staging a new one. The
        // launch sweep reclaims the final one (ExportTemp.sweep).
        cleanupTemp()
        do {
            let url = try MetafileExport.writeTemporary(data, fileName: fileName)
            tempCleanupURL = url.deletingLastPathComponent()
            sharePayload = MacSharePayload(url: url)
        } catch {
            errorMessage = failure
        }
    }

    private func cleanupTemp() {
        if let directory = tempCleanupURL {
            try? FileManager.default.removeItem(at: directory)
        }
        tempCleanupURL = nil
    }
}

/// What drives the Mac share picker: a staged file on disk, shared as a URL so the
/// picker shows the right filename and extension-derived type. A fresh `id` each
/// time, so a repeat share re-presents even for the same name.
struct MacSharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

/// Presents `NSSharingServicePicker` when a payload appears, anchored near the
/// toolbar's Share button. Value-driven (the payload is passed in), so SwiftUI
/// re-runs `updateNSView` when it changes; a per-payload id guard presents each
/// payload exactly once.
struct MacSharePresenter: NSViewRepresentable {
    let payload: MacSharePayload?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let payload, context.coordinator.presentedID != payload.id else { return }
        context.coordinator.presentedID = payload.id
        let picker = NSSharingServicePicker(items: [payload.url])
        // Anchor to this small view's bounds; it sits at the toolbar's trailing
        // edge, so the picker drops from under the Share button.
        picker.show(relativeTo: nsView.bounds, of: nsView, preferredEdge: .minY)
    }

    final class Coordinator {
        var presentedID: UUID?
    }
}

/// What drives the Send-to-AI share picker: the rendered PNG as an `NSImage`, the
/// summary as an `NSString`, and — only when the user opted in — the staged original
/// file as a URL. A fresh `id` each time so a repeat share re-presents.
struct MacAISharePayload: Identifiable {
    let id = UUID()
    let image: NSImage
    let text: String
    let fileURL: URL?

    /// The items handed to `NSSharingServicePicker`, in the order a target reads them.
    var items: [Any] {
        var items: [Any] = [image, text as NSString]
        if let fileURL { items.append(fileURL) }
        return items
    }
}

/// Presents `NSSharingServicePicker` for the Send-to-AI payload when it appears,
/// anchored near the toolbar's Share button — the same pattern as `MacSharePresenter`,
/// but carrying the image + text (+ optional file) items rather than a single file URL.
struct MacAISharePresenter: NSViewRepresentable {
    let payload: MacAISharePayload?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let payload, context.coordinator.presentedID != payload.id else { return }
        context.coordinator.presentedID = payload.id
        let picker = NSSharingServicePicker(items: payload.items)
        picker.show(relativeTo: nsView.bounds, of: nsView, preferredEdge: .minY)
    }

    final class Coordinator {
        var presentedID: UUID?
    }
}
