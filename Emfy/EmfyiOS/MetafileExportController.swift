import EMFRender
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Drives the viewer's Share menu: Share File, Share as PNG/PDF, Copy Image, and
/// Save to Photos. Each render runs off-main and cancellably through
/// `ExportTaskRunner`, surfacing a spinner (`isRendering`) past ~0.3 s; the share
/// sheet, the two alerts, and the spinner are hosted by `MetafileViewerScreen`.
///
/// The file-details "Export as PNG/PDF…" rows do NOT go through this controller —
/// they present their own `fileExporter` from within the inspector so the
/// presentation is correct whether the inspector is a column (iPad) or a sheet
/// (iPhone). Both surfaces share the pure render in `MetafileExport`.
@MainActor
@Observable
final class MetafileExportController {
    /// Drives the full-screen rendering spinner.
    var isRendering = false
    /// Non-nil presents the system share sheet.
    var sharePayload: SharePayload?
    /// Non-nil presents the "Export Failed" alert (render/share failures).
    var shareError: String?
    /// Presents the "add photos permission denied" alert with a Settings path — only
    /// when access was already denied before the tap (C4a H7).
    var showPhotosDeniedAlert = false
    /// Presents the informational "Photos access is restricted" alert (C4a H7).
    var showPhotosRestrictedAlert = false

    @ObservationIgnored private let runner = ExportTaskRunner()
    /// The temp directory of the file currently being shared, removed on dismiss.
    @ObservationIgnored private var tempCleanupURL: URL?
    /// The in-flight "Share File" resolve/stage task, tracked so a repeat tap
    /// cancels it rather than letting two runs double-fire the share sheet (§j).
    @ObservationIgnored private var shareOriginalTask: Task<Void, Never>?

    // MARK: - Actions

    /// Shares the original bytes (.emf/.wmf/.emz/.wmz) under their real file name,
    /// so the sheet shows the correct name and extension-derived type.
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
                if !Task.isCancelled { shareError = MetafileExport.shareFileFailure }
            }
        }
    }

    /// Shares the scene as SVG (`SceneImporter` → `SceneSVGExporter`) under
    /// "<base>.svg". Unlike PNG/PDF, SVG is built from the imported scene, so it
    /// resolves the original bytes and serialises off-main; the spinner shows past
    /// ~0.3 s. The fidelity warnings are not surfaced yet — carried to E2 (the brief).
    func shareSVG(entry: RecentEntry, store: RecentsStore, baseName: String) {
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
            guard let original = try? await store.resolveData(for: entry) else {
                if !Task.isCancelled { self.shareError = SVGExport.generateFailure }
                return
            }
            if Task.isCancelled { return }
            let produced = await Task.detached(priority: .userInitiated) { SVGExport.data(from: original) }.value
            if Task.isCancelled { return }
            guard let produced else { self.shareError = SVGExport.generateFailure; return }
            presentShare(data: produced.data, fileName: "\(baseName).svg", failure: SVGExport.generateFailure)
        }
    }

    /// Renders `format` and opens the share sheet with "<base name>.<ext>". `scale`
    /// and `background` carry the Export settings into the PNG render (S1a-6).
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
                guard let data else {
                    self.shareError = format.failureMessage
                    return
                }
                self.presentShare(
                    data: data,
                    fileName: "\(baseName).\(format.pathExtension)",
                    failure: format.failureMessage
                )
            }
        )
    }

    /// Prints the drawing (F1) via `UIPrintInteractionController`, fed the vector PDF so
    /// the print output is vector. `jobName` is the file name. Renders off-main, then
    /// presents the system print UI (anchored to the key window on iPad).
    func printDrawing(prepared: MetafileRenderer.Prepared, options: RenderOptions, jobName: String) {
        runner.run(
            setBusy: { [weak self] busy in self?.isRendering = busy },
            render: { MetafileExport.pdfData(prepared, options: options) },
            done: { [weak self] data in
                guard let self else { return }
                guard let data else { self.shareError = MetafileExport.pdfGenerateFailure; return }
                let info = UIPrintInfo.printInfo()
                info.jobName = jobName
                info.outputType = .general
                let controller = UIPrintInteractionController.shared
                controller.printInfo = info
                controller.printingItem = data
                if let (view, rect) = Self.keyWindowAnchor() {
                    controller.present(from: rect, in: view, animated: true, completionHandler: nil)
                } else {
                    controller.present(animated: true, completionHandler: nil)
                }
            }
        )
    }

    /// Copies the drawing to the pasteboard as vector PDF + PNG (F1 design call 2),
    /// confirming with a toast. `scale`/`background` come from the Export settings.
    func copyDrawing(prepared: MetafileRenderer.Prepared, scale: CGFloat, background: RenderBackground, options: RenderOptions, toast: ToastCenter?) {
        runner.run(
            setBusy: { [weak self] busy in self?.isRendering = busy },
            render: { CopyPayload(
                pdf: MetafileExport.pdfData(prepared, options: options),
                png: MetafileExport.pngData(prepared, scale: scale, background: background, options: options)) },
            done: { [weak self] payload in
                guard let self else { return }
                var representation: [String: Any] = [:]
                if let pdf = payload.pdf { representation[UTType.pdf.identifier] = pdf }
                if let png = payload.png { representation[UTType.png.identifier] = png }
                guard !representation.isEmpty else {
                    self.shareError = MetafileExport.pdfGenerateFailure
                    return
                }
                UIPasteboard.general.items = [representation]
                toast?.show("Drawing copied", systemImage: "doc.on.doc")
            }
        )
    }

    /// An anchor for `UIPrintInteractionController.present(from:in:…)` on iPad — a tiny
    /// rect at the top centre of the foreground key window.
    private static func keyWindowAnchor() -> (UIView, CGRect)? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let window = scene?.keyWindow ?? scene?.windows.first else { return nil }
        return (window, CGRect(x: window.bounds.midX - 1, y: 0, width: 2, height: 2))
    }

    /// Renders a PNG and copies it to the pasteboard, confirming with a toast (the
    /// toast also announces to VoiceOver). C4a H6/A2. `scale`/`background` from the
    /// Export settings (S1a-6).
    func copyImage(prepared: MetafileRenderer.Prepared, scale: CGFloat, background: RenderBackground, options: RenderOptions, toast: ToastCenter?) {
        runner.run(
            setBusy: { [weak self] busy in self?.isRendering = busy },
            render: { MetafileExport.pngData(prepared, scale: scale, background: background, options: options) },
            done: { [weak self] data in
                guard let self else { return }
                guard let data else {
                    self.shareError = MetafileExport.pngEncodeFailure
                    return
                }
                UIPasteboard.general.setData(data, forPasteboardType: UTType.png.identifier)
                toast?.show("Image copied", systemImage: "doc.on.doc")
            }
        )
    }

    /// Renders a PNG and saves it to Photos via an add-only request; confirms with a
    /// toast, offers Settings only on a pre-existing denial, shows an informational
    /// alert when restricted, stays quiet on a fresh decline (C4a H6/A2, H7).
    func saveToPhotos(prepared: MetafileRenderer.Prepared, scale: CGFloat, background: RenderBackground, options: RenderOptions, toast: ToastCenter?) {
        runner.run(
            setBusy: { [weak self] busy in self?.isRendering = busy },
            render: { MetafileExport.pngData(prepared, scale: scale, background: background, options: options) },
            done: { [weak self] data in
                guard let self else { return }
                guard let data else {
                    self.shareError = MetafileExport.pngEncodeFailure
                    return
                }
                Task { @MainActor in
                    switch await PhotoLibrarySaver.save(pngData: data) {
                    case .saved:
                        toast?.show("Saved to Photos", systemImage: "checkmark.circle")
                    case .restricted:
                        self.showPhotosRestrictedAlert = true
                    case .deniedNeedsSettings:
                        self.showPhotosDeniedAlert = true
                    case .deniedSilently:
                        break   // the system prompt just ran; stay quiet (H7)
                    case .failed(let message):
                        self.shareError = message
                    }
                }
            }
        )
    }

    // MARK: - Lifecycle

    /// Removes the shared file's temp directory once the sheet is dismissed.
    func cleanupTemp() {
        if let directory = tempCleanupURL {
            try? FileManager.default.removeItem(at: directory)
        }
        tempCleanupURL = nil
    }

    /// Cancels any in-flight render when the viewer disappears.
    func cancelOngoing() {
        runner.cancel()
        shareOriginalTask?.cancel()
        isRendering = false
    }

    /// Presents the share sheet for an already-serialised EMF copy of the edited scene
    /// ("Save a Copy as EMF…", E2a-5 review #6), under "<base>.emf".
    func shareSceneCopy(data: Data, baseName: String) {
        presentShare(data: data, fileName: "\(baseName).emf", failure: "Emfy couldn’t prepare an EMF copy of this drawing.")
    }

    // MARK: - Helpers

    private func presentShare(data: Data, fileName: String, failure: String) {
        // Reclaim a prior share's temp directory before staging a new one, so a
        // second share without a dismiss in between can't leak the first (§j).
        cleanupTemp()
        do {
            let url = try MetafileExport.writeTemporary(data, fileName: fileName)
            tempCleanupURL = url.deletingLastPathComponent()
            sharePayload = SharePayload(url: url)
        } catch {
            shareError = failure
        }
    }

    /// Cancels the in-flight render (the merged export overlay's Cancel button, L2).
    func cancelExport() {
        cancelOngoing()
    }
}

/// The two representations a Copy produces, rendered off-main in one pass (F1).
private struct CopyPayload: Sendable {
    let pdf: Data?
    let png: Data?
}

extension MetafileExportController {
    /// Builds the drag item provider for an iPad long-press drag on the viewer canvas
    /// (F1 design call 3): the drawing as a vector PDF file promise (a drop yields
    /// "<name>.pdf") and a PNG. Each representation renders lazily off-main, so starting
    /// the drag is cheap.
    static func dragItemProvider(
        prepared: MetafileRenderer.Prepared,
        baseName: String,
        pngScale: Int,
        background: RenderBackground,
        options: RenderOptions
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = baseName

        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all
        ) { completion in
            Task.detached(priority: .userInitiated) {
                guard let data = MetafileRenderer.pdfData(prepared, options: options) else {
                    completion(nil, false, DragError.renderFailed); return
                }
                do {
                    let directory = ExportTemp.makeDirectory()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent(MetafileExport.sanitisedFileName("\(baseName).pdf"))
                    try data.write(to: url, options: .atomic)
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }

        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier, visibility: .all
        ) { completion in
            Task.detached(priority: .userInitiated) {
                let selection = ExportScale.select(
                    baseWidth: Int(prepared.naturalSize.width.rounded()),
                    baseHeight: Int(prepared.naturalSize.height.rounded()),
                    requested: pngScale, areaCap: ExportScale.areaCap)
                guard let (image, _) = MetafileRenderer.makeImage(
                        prepared, scale: CGFloat(selection.multiplier), background: background, options: options),
                      let data = EMFExport.pngData(from: image) else {
                    completion(nil, DragError.renderFailed); return
                }
                completion(data, nil)
            }
            return nil
        }
        return provider
    }

    private enum DragError: Error { case renderFailed }
}
