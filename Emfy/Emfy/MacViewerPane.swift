import AppKit
import CoreGraphics
import EMFRender
import SwiftUI

/// The Mac library window's detail column: the sharp, memory-bounded tiled viewer
/// (C3a slice 3). It shows the `DocumentSession`'s metafile through
/// `MacMetafileScrollView` — an `NSScrollView` magnifying a `CATiledLayer`-backed
/// view that replays the vector per tile at the on-screen resolution, so the
/// drawing stays crisp at any zoom and memory stays bounded to the screen.
///
/// The toolbar's Zoom Out / percentage / Zoom In / Fit / Share / Info and the
/// inspector's Zoom row read the shared `MacMetafileZoomController`, so they stay
/// live as the user pinches or ⌘-scrolls (C3b scope 3). The menu bar owns the
/// keyboard shortcuts (C3b scope 2), routed here through `ViewerActions` published
/// on `.focusedSceneValue`, so each window drives its own document. Export and
/// Share are owned here (not the inspector), so Export works with the inspector
/// closed (C3b scope 5), through the off-main `MacViewerExporter`.
struct MacViewerPane: View {
    @Environment(RecentsStore.self) private var store
    @Environment(ToastCenter.self) private var toast
    @Environment(EmfySettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let session: DocumentSession
    /// Clears the window's selection when the file is removed from Recents.
    let onRemove: () -> Void

    @State private var controller = MacMetafileZoomController()
    @State private var exporter = MacViewerExporter()
    @State private var showInspector = false

    private var loaded: LoadedMetafile? { session.loaded }

    var body: some View {
        @Bindable var exporter = exporter
        content
            .navigationTitle(entry?.baseName ?? "Metafile")
            // Format · size under the title, using the shared helper (G6).
            .navigationSubtitle(subtitle)
            .toolbar { toolbarContent }
            .inspector(isPresented: $showInspector) {
                inspector
            }
            // Export is hoisted out of the inspector so it works when the inspector
            // is closed (C3b scope 5); the inspector rows call the same path.
            .fileExporter(
                isPresented: $exporter.isExportingPNG,
                document: exporter.pngDocument,
                contentType: .png,
                defaultFilename: entry?.baseName ?? "Metafile"
            ) { result in
                handleExport(result, format: "PNG")
            }
            .fileExporter(
                isPresented: $exporter.isExportingPDF,
                document: exporter.pdfDocument,
                contentType: .pdf,
                defaultFilename: entry?.baseName ?? "Metafile"
            ) { result in
                handleExport(result, format: "PDF")
            }
            .alert(
                "Export Failed",
                isPresented: Binding(get: { exporter.errorMessage != nil }, set: { if !$0 { exporter.errorMessage = nil } }),
                presenting: exporter.errorMessage
            ) { _ in
                Button("OK", role: .cancel) { exporter.errorMessage = nil }
            } message: { message in
                Text(message)
            }
            .overlay {
                if exporter.isRendering {
                    ExportProgressOverlay { exporter.cancelOngoing() }
                }
            }
            // ⌘= also zooms in: a US keyboard sends "=" unshifted, and the View menu
            // item can show only ⌘+. This hidden accelerator covers the alternate.
            .background(zoomInEqualsShortcut)
            // Publish this window's actions to the shared menu bar (C3b scope 1).
            .focusedSceneValue(\.viewerActions, viewerActions)
            .onDisappear { exporter.cancelOngoing() }
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
        case .loaded(let model):
            MacMetafileScrollView(
                prepared: model.prepared,
                naturalSize: model.displaySize,
                drawingLabel: "Drawing: \(entry?.baseName ?? "Metafile")",
                controller: controller,
                defaultZoom: settings.defaultZoomOnOpen,
                pageShadow: settings.pageShadow,
                tilePaint: ViewerTilePaint.make(
                    background: settings.pageBackground,
                    darkMode: settings.darkPageMode,
                    isDark: colorScheme == .dark
                ),
                scrollAction: settings.macScrollAction
            )
            .ignoresSafeArea()
            // Rebuild the tiled view only when the content actually changes, so a
            // changed-content reload shows the new drawing while an identical reload
            // keeps the same view and its zoom (C4a M4).
            .id(session.loadedContentID)
        case .failed(let reason):
            failedView(reason)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    /// The failed state: per-reason actions and wording shared with iOS through
    /// `ViewerFailurePresentation` (C4a H4, M4). Try Again now also covers `.unreadable`
    /// (a file still being written), per M4.
    private func failedView(_ reason: DocumentSession.FailureReason) -> some View {
        ContentUnavailableView {
            Label("Can’t show this file", systemImage: "exclamationmark.triangle")
        } description: {
            Text(ViewerFailurePresentation.message(for: reason))
        } actions: {
            ForEach(ViewerFailurePresentation.actions(for: reason), id: \.self) { action in
                failedActionButton(action)
            }
        }
    }

    @ViewBuilder
    private func failedActionButton(_ action: ViewerFailurePresentation.Action) -> some View {
        switch action {
        case .tryAgain:
            Button("Try Again") { Task { await session.load() } }
                .buttonStyle(.borderedProminent)
        case .remove:
            Button("Remove from Recents", role: .destructive) {
                store.remove(session.entryID)
                onRemove()
            }
        }
    }

    /// Ignores a user cancel (C4a M2); confirms a save with a toast carrying a Show
    /// in Finder action (C4a M3); surfaces a real failure.
    private func handleExport(_ result: Result<URL, Error>, format: String) {
        switch result {
        case .success(let url):
            toast.show("Exported as \(format)", systemImage: "square.and.arrow.down", actionTitle: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .failure(let error):
            if (error as? CocoaError)?.code == .userCancelled { return }
            exporter.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let loaded, let entry {
            MetafileInfoView(
                entry: entry,
                prepared: loaded.prepared,
                diagnostics: loaded.diagnostics,
                couldNotShowNotes: loaded.couldNotShowNotes,
                naturalSize: loaded.naturalSize,
                // A closure, so the live zoom is read inside the Zoom row's leaf, not
                // this pane's body (P1). The Mac row is read-only (no onZoomStep).
                zoomProvider: { Int((controller.zoom * 100).rounded()) },
                onClose: { showInspector = false },
                // Route the inspector's export rows through the hoisted exporter, so
                // both surfaces share one path and the fileExporter presentation.
                onExport: { format in export(format) }
            )
        } else {
            ContentUnavailableView("No details yet", systemImage: "info.circle")
        }
    }

    // MARK: - Toolbar (C3b scope 3: Zoom Out, %, Zoom In, Fit, Share, Info)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItemGroup {
                zoomOutButton
                MacZoomPercentLabel(controller: controller)
                zoomInButton
            }
            ToolbarSpacer(.fixed)
            ToolbarItem { fitButton }
            ToolbarSpacer(.fixed)
            ToolbarItem { shareMenu }
            ToolbarItem { infoButton }
        } else {
            // Pre-26 has no ToolbarSpacer: one group keeps the stated order.
            ToolbarItemGroup {
                zoomOutButton
                MacZoomPercentLabel(controller: controller)
                zoomInButton
                fitButton
                shareMenu
                infoButton
            }
        }
    }

    // The menu bar owns the shortcuts now (C3b scope 2), so the toolbar buttons
    // carry none — only tooltips.

    private var zoomOutButton: some View {
        Button {
            controller.zoomOut()
        } label: {
            Label("Zoom Out", systemImage: "minus.magnifyingglass")
        }
        .disabled(loaded == nil)
        .help("Zoom Out")
    }

    private var zoomInButton: some View {
        Button {
            controller.zoomIn()
        } label: {
            Label("Zoom In", systemImage: "plus.magnifyingglass")
        }
        .disabled(loaded == nil)
        .help("Zoom In")
    }

    private var fitButton: some View {
        Button("Fit") {
            controller.fit()
        }
        .disabled(loaded == nil)
        .help("Fit to Window")
    }

    private var shareMenu: some View {
        Menu {
            Button {
                shareOriginal()
            } label: {
                Label("Share File", systemImage: "square.and.arrow.up")
            }
            Button {
                share(.png)
            } label: {
                Label("Share as PNG", systemImage: "photo")
            }
            Button {
                share(.pdf)
            } label: {
                Label("Share as PDF", systemImage: "doc.richtext")
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        // The share picker anchors to this hidden view sitting behind the Share
        // toolbar item, so it drops from the Share glyph itself rather than the far
        // trailing corner (which was under Info) — the picker tracks Share on both
        // macOS 14 (single group) and 26 (spacers), with no magic offset (G7, review #4).
        .background {
            MacSharePresenter(payload: exporter.sharePayload)
                .allowsHitTesting(false)
        }
        .disabled(loaded == nil)
        .help("Share")
    }

    private var infoButton: some View {
        Button {
            showInspector.toggle()
        } label: {
            Label("Info", systemImage: "info.circle")
        }
        .disabled(loaded == nil)
        .help("Show file details")
    }

    // MARK: - Actions

    /// Hidden ⌘= accelerator for Zoom In (see `body`). Zero-size and non-interactive
    /// so it only registers the shortcut while the window is key.
    private var zoomInEqualsShortcut: some View {
        Button("Zoom In") { controller.zoomIn() }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(loaded == nil)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private func export(_ format: ExportFormat) {
        guard let loaded else { return }
        exporter.exportToFile(format, prepared: loaded.prepared)
    }

    private func share(_ format: ExportFormat) {
        guard let loaded, let entry else { return }
        exporter.share(format, prepared: loaded.prepared, baseName: entry.baseName)
    }

    private func shareOriginal() {
        guard let entry else { return }
        exporter.shareOriginal(entry: entry, store: store)
    }

    /// The per-window actions published to the menu bar. Recomputed each body pass,
    /// so the closures always target the current document.
    private var viewerActions: ViewerActions {
        ViewerActions(
            isDocumentLoaded: loaded != nil,
            zoomIn: { controller.zoomIn() },
            zoomOut: { controller.zoomOut() },
            fit: { controller.fit() },
            actualSize: { controller.actualSize() },
            exportPNG: { export(.png) },
            exportPDF: { export(.pdf) },
            shareFile: { shareOriginal() },
            sharePNG: { share(.png) },
            sharePDF: { share(.pdf) }
        )
    }

    private var entry: RecentEntry? {
        store.entry(id: session.entryID)
    }

    /// Format · size for the navigation subtitle, via the shared helper (G6). Reads
    /// the entry (which changes on load), never the zoom, so it stays off the per-
    /// frame path.
    private var subtitle: String {
        entry?.formatSizeSubtitle ?? ""
    }
}

/// The toolbar's zoom percentage, as its own leaf view reading the controller, so a
/// zoom change invalidates only this label — not `MacViewerPane.body`, which would
/// otherwise rebuild the inspector and republish `viewerActions` to the menu bar
/// every frame (P1).
private struct MacZoomPercentLabel: View {
    let controller: MacMetafileZoomController

    var body: some View {
        let percent = Int((controller.zoom * 100).rounded())
        Text("\(percent)%")
            .font(.system(.body, design: .rounded).monospacedDigit())
            .frame(minWidth: 48)
            // Give the bare percentage context for VoiceOver (A11).
            .accessibilityElement()
            .accessibilityLabel("Zoom")
            .accessibilityValue("\(percent) percent")
    }
}
