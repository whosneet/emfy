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
    // Non-optional: verified at runtime that the window's ToastCenter reaches the
    // compact pushed viewer (the "Image copied" toast appears there).
    @Environment(ToastCenter.self) private var toast
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
        case failed(DocumentSession.FailureReason)
    }

    /// The viewer phase, derived from the session's load state.
    private var phase: Phase {
        switch session.state {
        case .idle, .loading: return .loading
        case .loaded(let model): return .loaded(model)
        case .failed(let reason): return .failed(reason)
        }
    }

    private var isLoaded: Bool { if case .loaded = phase { return true }; return false }
    private var isFailed: Bool { if case .failed = phase { return true }; return false }

    /// Chrome is only hidden while a drawing is actually loaded — the immersive black
    /// background and hidden bars must never survive into loading or a failed state,
    /// or the user is left on a black screen with no Back button (C4a H5).
    private var effectiveChromeHidden: Bool { chromeHidden && isLoaded }

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
        .toolbar(effectiveChromeHidden ? .hidden : .visible, for: .navigationBar)
        .toolbar(effectiveChromeHidden ? .hidden : .visible, for: .bottomBar)
        .statusBarHidden(effectiveChromeHidden)
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
        .alert("Photos Access Restricted", isPresented: photosRestrictedBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Photos access is restricted on this device, so Emfy can’t save pictures to your photo library.")
        }
        .overlay {
            if exporter.isRendering {
                ExportProgressOverlay { exporter.cancelExport() }
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
        // Announce only when the partial-support message first appears, not each time
        // the chrome returns (A9).
        .onChange(of: partialMessage) { old, new in
            if old == nil, let message = new {
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
        // Reset immersive mode and announce the failed state when the phase leaves
        // loaded, so the chrome returns and VoiceOver is told (A10, H5).
        .onChange(of: isLoaded) { _, loaded in
            if !loaded { chromeHidden = false }
        }
        .onChange(of: isFailed) { _, failed in
            if failed {
                UIAccessibility.post(notification: .announcement, argument: "Can’t show this file")
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

    private var photosRestrictedBinding: Binding<Bool> {
        Binding(get: { exporter.showPhotosRestrictedAlert }, set: { exporter.showPhotosRestrictedAlert = $0 })
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var backgroundColor: Color {
        effectiveChromeHidden ? .black : Color(.systemGroupedBackground)
    }

    // MARK: - Drawing

    @ViewBuilder
    private var drawingLayer: some View {
        switch phase {
        case .loading:
            ProgressView()
                .accessibilityLabel("Loading drawing")   // A10
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let model):
            ZoomableMetafileView(
                prepared: model.prepared,
                naturalSize: model.displaySize,
                displayScale: displayScale,
                drawingLabel: "Drawing: \(entry?.baseName ?? "Metafile")",
                controller: controller,
                reduceMotion: reduceMotion,
                chromeHidden: effectiveChromeHidden,
                onSingleTap: { toggleChrome() }
            )
            .ignoresSafeArea()
            // Rebuild the tiled view only when the content actually changes, so a
            // changed-content reload shows the new drawing while an identical reload
            // keeps the same view and its zoom (C4a M4).
            .id(session.loadedContentID)
        case .failed(let reason):
            failedView(reason)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The failed state: per-reason actions and wording, shared with the Mac through
    /// `ViewerFailurePresentation` (C4a H4). Try Again only where it can help
    /// (transient or a mid-write unreadable file), Remove otherwise.
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
        .accessibilityIdentifier("viewerShare")
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
                exporter.copyImage(prepared: model.prepared, toast: toast)
            } label: {
                Label("Copy Image", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("copyImage")
            Button {
                exporter.saveToPhotos(prepared: model.prepared, toast: toast)
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
        .accessibilityIdentifier("viewerInfo")
    }

    // Keyboard shortcuts stay registered regardless of chrome visibility (a hidden
    // toolbar deregisters its items' shortcuts). Aligned with the Mac (C4a M6/A15):
    // ⌘0 Actual Size, ⌘9 Fit, ⌘+/⌘= Zoom In, ⌘− Zoom Out, ⌘I Info (loaded only),
    // ⇧⌘H toggles the controls, Esc restores them. Not ⌃⌘F (the system Enter Full
    // Screen shortcut, which iPadOS windowing intercepts) and not ⇧⌘\ (SwiftUI can't
    // match a `\` KeyEquivalent while Shift is held, since Shift+\ emits `|`) —
    // verified on the simulator (C4a M6 correction). ⇧⌘E is deliberately NOT bound:
    // on the Mac it means Export-to-file, so it must not mean something else on iPad.
    // Each is hidden from VoiceOver.
    private var keyboardCommands: some View {
        ZStack {
            shortcutButton("Zoom In", "+") { controller.zoomIn() }
            shortcutButton("Zoom In", "=") { controller.zoomIn() }
            shortcutButton("Zoom Out", "-") { controller.zoomOut() }
            shortcutButton("Actual Size", "0") { controller.actualSize() }
            shortcutButton("Zoom to Fit", "9") { controller.fit() }
            shortcutButton("Info", "i", enabled: loaded != nil) { toggleInspector() }
            shortcutButton("Toggle Controls", "h", modifiers: [.command, .shift], enabled: isLoaded) { toggleChrome() }
            Button("Show Controls") { if chromeHidden { toggleChrome() } }
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityHidden(true)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func shortcutButton(
        _ title: String,
        _ key: KeyEquivalent,
        modifiers: EventModifiers = .command,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(!enabled)
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
            .accessibilityLabel("Details about what Emfy couldn’t show")   // A9
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
        .accessibilityLabel("Dismiss warning")   // A9
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
                // The Zoom row is reachable on both iPhone (sheet) and iPad (column),
                // with − / + 25% steppers driving the viewer's controller (A14).
                zoomPercent: zoomPercent,
                onClose: { closeInspector() },
                onZoomStep: { delta in controller.step(by: delta) }
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
