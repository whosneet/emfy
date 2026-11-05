import CoreGraphics
import EMFRender
import SwiftUI
import UIKit

/// The iOS library window's detail column: the Photos-style viewer, now driven by
/// a per-window `DocumentSession` (v3-plan §11.2) rather than loading the file
/// itself. The drawing is full-bleed on a white page, pinch/pan zoom that stays
/// crisp at every level, tap-to-toggle chrome (the background goes black with the
/// bars hidden), a transient zoom pill, a dismissible partial-support banner, and
/// file details. Built to the approved I2 mockups and the iPhone Duo rules.
///
/// File details use Apple's `.inspector`, which adapts on its own: a trailing
/// column at regular width (iPad) and a sheet at compact width (iPhone, screenshot
/// #6). The viewer is the split view's detail, so at regular width it is a proper
/// column rather than a NavigationStack-pushed view, and `.inspector` doesn't pop.
struct MetafileViewerScreen: View {
    @Environment(RecentsStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let session: DocumentSession
    /// Clears the window's selection when the file is removed from Recents.
    let onRemove: () -> Void

    @State private var controller = MetafileZoomController()
    @State private var exporter = MetafileExportController()

    @State private var chromeHidden = false
    @State private var showInspector = false
    @State private var bannerDismissed = false
    @State private var pillVisible = false
    @State private var pillHideTask: Task<Void, Never>?

    private enum Phase {
        case loading
        case loaded(LoadedMetafile)
        case unrenderable
        case failed
    }

    /// The viewer phase, derived from the session's load state.
    private var phase: Phase {
        switch session.state {
        case .idle, .loading: return .loading
        case .loaded(let model): return .loaded(model)
        case .failed(.unreadable): return .unrenderable
        case .failed: return .failed
        }
    }

    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    /// A fixed inspector column width so the drawing can reserve exactly that much
    /// trailing space when the inspector is open (iPad). `.inspector` presents as a
    /// translucent overlay over the detail's trailing edge, not a width-reducing
    /// column, so without this the drawing bleeds under it (item 2).
    private let inspectorWidth: CGFloat = 320

    /// Trailing space to keep clear for the inspector overlay — only at regular
    /// width (iPad), where the inspector is a column; zero for the iPhone sheet.
    private var reservedInspectorWidth: CGFloat {
        (showInspector && isRegularWidth) ? inspectorWidth : 0
    }

    var body: some View {
        ZStack {
            backgroundColor
                .ignoresSafeArea()
            drawingLayer
        }
        // Reserve the inspector overlay's width on the trailing edge so the drawing
        // keeps clear of it; the scroll view then refits to the visible rect when
        // the inspector opens/closes, the sidebar collapses, or the device rotates
        // (item 2). Zero on iPhone, where the inspector is a sheet.
        .padding(.trailing, reservedInspectorWidth)
        .navigationTitle(entry?.baseName ?? "Metafile")
        .navigationBarTitleDisplayMode(.inline)
        .metafileNavigationSubtitle(subtitle)
        .toolbar { bottomBar }
        .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar)
        .toolbar(chromeHidden ? .hidden : .visible, for: .bottomBar)
        .statusBarHidden(chromeHidden)
        .overlay(alignment: .top) { topOverlays }
        // Built-in inspector: a column on iPad, a sheet on iPhone (screenshot #6).
        // A fixed width so the drawing's reserved trailing space matches it exactly.
        .inspector(isPresented: $showInspector) { inspectorContent }
        .inspectorColumnWidth(min: inspectorWidth, ideal: inspectorWidth, max: inspectorWidth)
        .sheet(item: shareSheetBinding, onDismiss: { exporter.cleanupTemp() }) { payload in
            ShareSheet(items: payload.items)
        }
        .alert(
            "Export Failed",
            isPresented: shareErrorBinding,
            presenting: exporter.shareError
        ) { _ in
            Button("OK", role: .cancel) { exporter.shareError = nil }
        } message: { message in
            Text(message)
        }
        .alert("Allow Photo Access", isPresented: photosDeniedBinding) {
            Button("Open Settings") { openSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Emfy needs permission to add pictures to your photo library. You can allow access in Settings.")
        }
        .overlay {
            if exporter.isRendering {
                RenderingOverlay()
            }
        }
        .background(keyboardCommands)
        .task(id: session.entryID) {
            // The window drives the load; this covers the rare idle arrival.
            if case .idle = session.state { await session.load() }
        }
        .onChange(of: controller.isZooming) { _, zooming in
            updatePill(zooming: zooming)
        }
        .onChange(of: showBanner) { _, shown in
            if shown, let message = partialMessage {
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
        .onDisappear {
            pillHideTask?.cancel()
            exporter.cancelOngoing()
        }
    }

    // Computed bindings keep share/export state on the `@Observable` controller.
    private var shareSheetBinding: Binding<SharePayload?> {
        Binding(get: { exporter.sharePayload }, set: { exporter.sharePayload = $0 })
    }

    private var shareErrorBinding: Binding<Bool> {
        Binding(get: { exporter.shareError != nil }, set: { if !$0 { exporter.shareError = nil } })
    }

    private var photosDeniedBinding: Binding<Bool> {
        Binding(get: { exporter.showPhotosDeniedAlert }, set: { exporter.showPhotosDeniedAlert = $0 })
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var backgroundColor: Color {
        chromeHidden ? .black : Color(.systemGroupedBackground)
    }

    // MARK: - Drawing

    @ViewBuilder
    private var drawingLayer: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let model):
            ZoomableMetafileView(
                prepared: model.prepared,
                naturalSize: model.displaySize,
                displayScale: displayScale,
                drawingLabel: "Drawing: \(entry?.baseName ?? "Metafile")",
                controller: controller,
                reduceMotion: reduceMotion,
                chromeHidden: chromeHidden,
                onSingleTap: { toggleChrome() }
            )
            .ignoresSafeArea()
        case .unrenderable:
            message("This drawing couldn’t be rendered.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            failedView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func message(_ text: String) -> some View {
        ContentUnavailableView {
            Label("Can’t show this file", systemImage: "exclamationmark.triangle")
        } description: {
            Text(text)
        }
    }

    /// The failed state (v3-plan §9.1): Try Again for a transient failure (offline,
    /// not-yet-downloaded), Remove from Recents for a definitively-gone file.
    private var failedView: some View {
        ContentUnavailableView {
            Label("Can’t show this file", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Emfy couldn’t read this file right now. It may have been moved or deleted, or it may be offline.")
        } actions: {
            Button("Try Again") { Task { await session.load() } }
                .buttonStyle(.borderedProminent)
            Button("Remove from Recents", role: .destructive) {
                store.remove(session.entryID)
                onRemove()
            }
        }
    }

    // MARK: - Bottom toolbar (system-managed; one glass capsule)

    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        if #available(iOS 27.0, *) {
            ToolbarItemGroup(placement: .bottomBar) {
                shareMenu
                fitButton
                infoButton
            }
            .visibilityPriority(.high)
        } else {
            ToolbarItemGroup(placement: .bottomBar) {
                shareMenu
                fitButton
                infoButton
            }
        }
    }

    private var shareMenu: some View {
        Menu {
            shareMenuItems
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .disabled(loaded == nil)
    }

    @ViewBuilder
    private var shareMenuItems: some View {
        if let model = loaded, let entry {
            Button {
                exporter.shareOriginal(entry: entry, store: store)
            } label: {
                Label("Share File", systemImage: "square.and.arrow.up")
            }
            Button {
                exporter.share(.png, prepared: model.prepared, baseName: entry.baseName)
            } label: {
                Label("Share as PNG", systemImage: "photo")
            }
            Button {
                exporter.share(.pdf, prepared: model.prepared, baseName: entry.baseName)
            } label: {
                Label("Share as PDF", systemImage: "doc.richtext")
            }
            Divider()
            Button {
                exporter.copyImage(prepared: model.prepared)
            } label: {
                Label("Copy Image", systemImage: "doc.on.doc")
            }
            Button {
                exporter.saveToPhotos(prepared: model.prepared)
            } label: {
                Label("Save to Photos", systemImage: "square.and.arrow.down")
            }
        }
    }

    private var fitButton: some View {
        Button {
            controller.fit()
        } label: {
            Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .disabled(loaded == nil)
    }

    private var infoButton: some View {
        Button {
            toggleInspector()
        } label: {
            Label("Info", systemImage: "info.circle")
        }
        .disabled(loaded == nil)
        .accessibilityAddTraits(showInspector ? [.isSelected] : [])
    }

    // Keyboard shortcuts stay registered regardless of chrome visibility (a hidden
    // toolbar deregisters its items' shortcuts), so iPad gets ⌘+/⌘−/⌘0/⌘1/⌘I. Each
    // is hidden from VoiceOver.
    private var keyboardCommands: some View {
        ZStack {
            shortcutButton("Zoom In", "+") { controller.zoomIn() }
            shortcutButton("Zoom Out", "-") { controller.zoomOut() }
            shortcutButton("Fit", "0") { controller.fit() }
            shortcutButton("Actual Size", "1") { controller.actualSize() }
            shortcutButton("Info", "i") { toggleInspector() }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func shortcutButton(_ title: String, _ key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .keyboardShortcut(key, modifiers: .command)
            .accessibilityHidden(true)
    }

    // MARK: - Top overlays (pill + banner), displaced clear of the Duo fold

    @ViewBuilder
    private var topOverlays: some View {
        GeometryReader { proxy in
            let regions = DuoRegions.active(in: proxy)
            let width = proxy.size.width
            let xOffset = DuoRegions.centredOverlayXOffset(viewWidth: width, division: regions.division)
            let sideWidth = DuoRegions.largerSideWidth(viewWidth: width, division: regions.division)
            let topInset = DuoRegions.overlayTopInset(base: 8, occlusion: regions.occlusion, division: regions.division, viewWidth: width)
            VStack(spacing: 8) {
                if pillVisible {
                    zoomPill
                        .offset(x: xOffset)
                        .transition(reduceMotion ? .identity : .opacity)
                }
                if showBanner, let message = partialMessage {
                    banner(message)
                        .frame(maxWidth: sideWidth - 24)
                        .offset(x: xOffset)
                        .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.top, topInset)
        }
    }

    private var zoomPill: some View {
        Text("\(zoomPercent)%")
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    private var showBanner: Bool {
        !chromeHidden && !bannerDismissed && partialMessage != nil
    }

    private var bannerWarningIcon: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
    }

    private var bannerDetailsButton: some View {
        Button("Details") { openInspectorFromBanner() }
            .font(.callout.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .hoverEffect()
    }

    private var bannerDismissButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { bannerDismissed = true }
        } label: {
            Image(systemName: "xmark")
                .font(.footnote.weight(.bold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .hoverEffect()
        .accessibilityLabel("Dismiss")
    }

    @ViewBuilder
    private func banner(_ message: String) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    Label { Text(message).fixedSize(horizontal: false, vertical: true) } icon: { bannerWarningIcon }
                        .font(.callout)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        bannerDetailsButton
                        bannerDismissButton
                    }
                }
            } else {
                HStack(spacing: 12) {
                    bannerWarningIcon
                    Text(message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    bannerDetailsButton
                    bannerDismissButton
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspectorContent: some View {
        if let model = loaded, let entry {
            MetafileInfoView(
                entry: entry,
                prepared: model.prepared,
                diagnostics: model.diagnostics,
                naturalSize: model.naturalSize,
                zoomPercent: isRegularWidth ? zoomPercent : nil,
                onClose: { closeInspector() }
            )
        } else {
            ContentUnavailableView("No details yet", systemImage: "info.circle")
        }
    }

    // MARK: - Actions

    private func toggleChrome() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            chromeHidden.toggle()
        }
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(
                notification: .announcement,
                argument: chromeHidden ? "Controls hidden" : "Controls shown"
            )
        }
    }

    private func toggleInspector() { setInspector(!showInspector) }
    private func closeInspector() { setInspector(false) }
    private func openInspectorFromBanner() { setInspector(true) }

    private func setInspector(_ open: Bool) {
        withAnimation(reduceMotion ? nil : .default) {
            showInspector = open
        }
    }

    private func updatePill(zooming: Bool) {
        pillHideTask?.cancel()
        if zooming {
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.12)) { pillVisible = true }
        } else {
            pillHideTask = Task {
                try? await Task.sleep(for: .seconds(0.9))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { pillVisible = false }
            }
        }
    }

    // MARK: - Derived data

    private var loaded: LoadedMetafile? {
        if case .loaded(let model) = phase { return model }
        return nil
    }

    private var partialMessage: String? {
        loaded?.diagnostics.partialSupportMessage
    }

    private var zoomPercent: Int {
        Int((controller.zoom * 100).rounded())
    }

    private var entry: RecentEntry? {
        store.entry(id: session.entryID)
    }

    private var subtitle: String {
        guard let entry else { return "" }
        let size = ByteCountFormatter.string(fromByteCount: entry.byteCount, countStyle: .file)
        return "\(entry.fullFormatName) · \(size)"
    }
}

extension View {
    /// Applies `navigationSubtitle` on iOS 26+, where it exists; a no-op below.
    @ViewBuilder
    func metafileNavigationSubtitle(_ subtitle: String) -> some View {
        if #available(iOS 26.0, *) {
            self.navigationSubtitle(subtitle)
        } else {
            self
        }
    }
}
