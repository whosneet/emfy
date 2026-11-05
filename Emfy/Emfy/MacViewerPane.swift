import CoreGraphics
import EMFRender
import SwiftUI

/// The Mac library window's detail column in C3a slice 2: an interim viewer that
/// shows the `DocumentSession`'s metafile through the existing render path
/// (`MetafileRenderer.makeImage`), with zoom, Fit and Actual Size, plus the
/// built-in `.inspector`. It is deliberately one self-contained view so the sharp
/// `CATiledLayer` Mac viewer can replace it in the next slice without touching the
/// window, sidebar or routing (v3-plan §9.1: "keep a clean seam").
///
/// Every load state comes from the session: loading, loaded, and failed with Try
/// Again / Remove (v3-plan §11.2).
struct MacViewerPane: View {
    @Environment(RecentsStore.self) private var store
    let session: DocumentSession
    /// Clears the window's selection when the file is removed from Recents.
    let onRemove: () -> Void

    @State private var zoom: CGFloat = 1
    @State private var didInitialFit = false
    @State private var viewportSize: CGSize = .zero
    @State private var renderedImage: CGImage?
    @State private var showInspector = false

    /// Zoom bounds and step. GDI pictures can be tiny or huge; keep a generous but
    /// finite range so the scaled frame never overflows layout.
    private static let minZoom: CGFloat = 0.02
    private static let maxZoom: CGFloat = 64
    private static let zoomStep: CGFloat = 1.25
    /// The Mac's long-standing on-screen/export render scale (2 = retina).
    private static let renderScale: CGFloat = 2

    private var loaded: LoadedMetafile? { session.loaded }

    var body: some View {
        content
            .navigationTitle(entry?.baseName ?? "Metafile")
            .toolbar { toolbarContent }
            .inspector(isPresented: $showInspector) {
                inspector
            }
            .task(id: session.state.kind) { renderIfLoaded() }
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
        case .loaded:
            viewer
        case .failed(let reason):
            failedView(reason)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    // MARK: - Viewer

    private var viewer: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                picture
                    .frame(
                        width: max(naturalSize.width * zoom, geometry.size.width),
                        height: max(naturalSize.height * zoom, geometry.size.height)
                    )
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .onAppear {
                viewportSize = geometry.size
                applyInitialFit(geometry.size)
            }
            .onChange(of: geometry.size) { _, newSize in
                viewportSize = newSize
                applyInitialFit(newSize)
            }
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let image = renderedImage {
            Image(image, scale: 1, label: Text("Metafile image"))
                .resizable()
                .interpolation(.high)
                .frame(width: naturalSize.width * zoom, height: naturalSize.height * zoom)
                .shadow(radius: 2)
        } else {
            Text("This file could not be rendered.")
                .foregroundStyle(.secondary)
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
                zoomPercent: Int((zoom * 100).rounded()),
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
                setZoom(zoom / Self.zoomStep)
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
                setZoom(zoom * Self.zoomStep)
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(loaded == nil)
            .help("Zoom In")

            Button("Fit") {
                zoom = fitZoom(in: viewportSize)
            }
            .disabled(loaded == nil)
            .help("Fit to Window")

            Button("100%") {
                setZoom(1)
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

    private var zoomPercentText: String {
        "\(Int((zoom * 100).rounded()))%"
    }

    // MARK: - Rendering & zoom

    /// Renders the loaded metafile to a retina `CGImage` off the main actor — the
    /// same path the Mac has always used. Cleared and re-run whenever the session's
    /// load state changes (a new file, a disk-change reload, Try Again).
    private func renderIfLoaded() {
        guard let loaded else {
            renderedImage = nil
            return
        }
        didInitialFit = false
        let prepared = loaded.prepared
        let scale = Self.renderScale
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                MetafileRenderer.makeImage(prepared, scale: scale)?.0
            }.value
            if session.loaded?.prepared != nil {
                renderedImage = image
                if viewportSize != .zero { applyInitialFit(viewportSize) }
            }
        }
    }

    /// The natural (100%) point size: the rendered bitmap in pixels divided by the
    /// scale it was rendered at.
    private var naturalSize: CGSize {
        guard let image = renderedImage, image.width > 0, image.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        return CGSize(
            width: CGFloat(image.width) / Self.renderScale,
            height: CGFloat(image.height) / Self.renderScale
        )
    }

    private func applyInitialFit(_ size: CGSize) {
        guard !didInitialFit, size.width > 0, size.height > 0, renderedImage != nil else { return }
        didInitialFit = true
        zoom = fitZoom(in: size)
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(max(value, Self.minZoom), Self.maxZoom)
    }

    /// The zoom that fits `naturalSize` inside `viewport` (with a small margin),
    /// never magnifying past 100%.
    private func fitZoom(in viewport: CGSize) -> CGFloat {
        let size = naturalSize
        guard size.width > 0, size.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        let margin: CGFloat = 32
        let availableWidth = max(viewport.width - margin, 1)
        let availableHeight = max(viewport.height - margin, 1)
        let fit = min(availableWidth / size.width, availableHeight / size.height)
        return min(max(fit, Self.minZoom), 1)
    }

    private var entry: RecentEntry? {
        store.entry(id: session.entryID)
    }
}
