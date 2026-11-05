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
    /// Presents the "add photos permission denied" alert with a Settings path.
    var showPhotosDeniedAlert = false

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

    /// Renders a PNG and copies it to the pasteboard, announcing the result.
    func copyImage(prepared: MetafileRenderer.Prepared) {
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
                UIAccessibility.post(notification: .announcement, argument: "Image copied")
            }
        )
    }

    /// Renders a PNG and saves it to Photos via an add-only request; announces
    /// success, offers Settings on denial, alerts on failure.
    func saveToPhotos(prepared: MetafileRenderer.Prepared) {
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
                        UIAccessibility.post(notification: .announcement, argument: "Saved to Photos")
                    case .denied:
                        self.showPhotosDeniedAlert = true
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
}

/// A dimmed, tap-blocking overlay shown while an export renders. VoiceOver reads
/// it as a single "Preparing export" element.
struct RenderingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Preparing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preparing export")
        .accessibilityAddTraits(.updatesFrequently)
    }
}
