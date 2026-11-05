import CoreGraphics
import EMFRender
import SwiftUI

/// The Mac library window's detail column: the sharp, memory-bounded tiled viewer
/// (C3a slice 3). It shows the `DocumentSession`'s metafile through
/// `MacMetafileScrollView` — an `NSScrollView` magnifying a `CATiledLayer`-backed
/// view that replays the vector per tile at the on-screen resolution, so the
/// drawing stays crisp at any zoom and memory stays bounded to the screen. The
/// interim fixed-bitmap path (`MetafileRenderer.makeImage` for display) is gone.
///
/// The toolbar's Zoom Out / percentage / Zoom In / Fit / Actual Size and the
/// inspector's Zoom row read the shared `MacMetafileZoomController`, so they stay
/// live as the user pinches or ⌘-scrolls. Every load state comes from the session:
/// loading, loaded, and failed with Try Again / Remove (v3-plan §9.1, §11.2). The
/// `MacViewerPane(session:onRemove:)` API is unchanged, so `LibraryWindow` is not
/// touched.
struct MacViewerPane: View {
    @Environment(RecentsStore.self) private var store
    let session: DocumentSession
    /// Clears the window's selection when the file is removed from Recents.
    let onRemove: () -> Void

    @State private var controller = MacMetafileZoomController()
    @State private var showInspector = false

    private var loaded: LoadedMetafile? { session.loaded }

    var body: some View {
        content
            .navigationTitle(entry?.baseName ?? "Metafile")
            .toolbar { toolbarContent }
            .inspector(isPresented: $showInspector) {
                inspector
            }
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
                controller: controller
            )
            .ignoresSafeArea()
        case .failed(let reason):
            failedView(reason)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    /// The failed state (v3-plan §9.1): Try Again keeps a transient file in Recents;
    /// Remove dismisses the viewer for a definitively-gone or unreadable one.
    private func failedView(_ reason: DocumentSession.FailureReason) -> some View {
        ContentUnavailableView {
            Label("Can’t show this file", systemImage: "exclamationmark.triangle")
        } description: {
            Text(failureMessage(reason))
        } actions: {
            if reason == .unavailable {
                Button("Try Again") { Task { await session.load() } }
                    .buttonStyle(.borderedProminent)
            }
            Button("Remove from Recents", role: .destructive) {
                store.remove(session.entryID)
                onRemove()
            }
        }
    }

    private func failureMessage(_ reason: DocumentSession.FailureReason) -> String {
        switch reason {
        case .unavailable:
            return "Emfy couldn’t read this file right now. It may be offline, or on a drive that isn’t connected."
        case .notFound:
            return "This file has moved or been deleted, so Emfy removed it from Recents."
        case .unreadable:
            return "Emfy opened this file but couldn’t read it as a metafile. It may be empty or damaged."
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
                naturalSize: loaded.naturalSize,
                zoomPercent: zoomPercent,
                onClose: { showInspector = false }
            )
        } else {
            ContentUnavailableView("No details yet", systemImage: "info.circle")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                controller.zoomOut()
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(loaded == nil)
            .help("Zoom Out")

            Text(zoomPercentText)
                .font(.system(.body, design: .rounded).monospacedDigit())
                .frame(minWidth: 48)

            Button {
                controller.zoomIn()
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(loaded == nil)
            .help("Zoom In")

            Button("Fit") {
                controller.fit()
            }
            .disabled(loaded == nil)
            .help("Fit to Window")

            Button("100%") {
                controller.actualSize()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(loaded == nil)
            .help("Actual Size")

            Button {
                showInspector.toggle()
            } label: {
                Label("Info", systemImage: "info.circle")
            }
            .disabled(loaded == nil)
            .help("Show file details")
        }
    }

    private var zoomPercent: Int {
        Int((controller.zoom * 100).rounded())
    }

    private var zoomPercentText: String {
        "\(zoomPercent)%"
    }

    private var entry: RecentEntry? {
        store.entry(id: session.entryID)
    }
}
