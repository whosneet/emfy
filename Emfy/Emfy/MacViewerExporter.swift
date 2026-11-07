import AppKit
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

    /// Non-nil presents the share picker (consumed by `MacSharePresenter`).
    var sharePayload: MacSharePayload?

    @ObservationIgnored private let runner = ExportTaskRunner()
    /// The in-flight "Share File" resolve/stage task, so a repeat tap cancels it.
    @ObservationIgnored private var shareOriginalTask: Task<Void, Never>?
    /// The in-flight SVG resolve+import+serialise task, so a repeat tap cancels it.
    @ObservationIgnored private var svgTask: Task<Void, Never>?
    /// The temp directory of the file currently staged for sharing.
    @ObservationIgnored private var tempCleanupURL: URL?

    // MARK: - Export to file

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

    /// Cancels any in-flight render (the viewer disappeared).
    func cancelOngoing() {
        runner.cancel()
        shareOriginalTask?.cancel()
        svgTask?.cancel()
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
