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

    /// Renders `format` and opens the share sheet with "<base name>.<ext>".
    func share(_ format: ExportFormat, prepared: MetafileRenderer.Prepared, baseName: String) {
        runner.run(
            setBusy: { [weak self] busy in self?.isRendering = busy },
            render: { MetafileExport.data(for: format, prepared: prepared) },
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

    /// Renders a PNG and copies it to the pasteboard, confirming with a toast (the
    /// toast also announces to VoiceOver). C4a H6/A2.
    func copyImage(prepared: MetafileRenderer.Prepared, toast: ToastCenter?) {
        runner.run(
            setBusy: { [weak self] busy in self?.isRendering = busy },
            render: { MetafileExport.pngData(prepared) },
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
    func saveToPhotos(prepared: MetafileRenderer.Prepared, toast: ToastCenter?) {
        runner.run(
            setBusy: { [weak self] busy in self?.isRendering = busy },
            render: { MetafileExport.pngData(prepared) },
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
