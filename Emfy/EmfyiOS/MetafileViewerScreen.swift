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
    @Environment(EmfySettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    // Non-optional: verified at runtime that the window's ToastCenter reaches the
    // compact pushed viewer (the "Image copied" toast appears there).
    @Environment(ToastCenter.self) private var toast
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

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
    // Editing (E2a review #6).
    @State private var showRevertConfirm = false
    @State private var showReloadDiscardConfirm = false

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
        // At regular width (iPad) a long inline title clips at the LEADING edge behind
        // the sidebar boundary; a principal title view truncates at the tail with an
        // ellipsis, like the iPhone title (S1a-5 carry-over c). iPhone keeps the
        // default inline title, which already tail-truncates.
        .toolbar { regularWidthTitle }
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
                .presentationDetents([.medium, .large])   // G5
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
        // Editing (E2a review #6): revert and reload-discard confirmations, the WMF
        // first-save limitations sheet, and the changed-on-disk banner.
        .confirmationDialog("Revert to the version you opened?", isPresented: $showRevertConfirm, titleVisibility: .visible) {
            Button("Revert", role: .destructive) { Task { await session.revertToOpenedVersion() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the file with the version Emfy opened and discards your edits. This can’t be undone.")
        }
        .confirmationDialog("Reload and discard your edits?", isPresented: $showReloadDiscardConfirm, titleVisibility: .visible) {
            Button("Reload", role: .destructive) { Task { await session.reloadDiscardingEdits() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The on-disk version replaces what’s on screen. Your unsaved edits are lost.")
        }
        .confirmationDialog(
            "Save as WMF?",
            isPresented: Binding(get: { session.pendingWMFConfirmation != nil }, set: { if !$0 { session.cancelPendingWMFSave() } }),
            titleVisibility: .visible,
            presenting: session.pendingWMFConfirmation
        ) { pending in
            Button("Save Anyway") { Task { await session.confirmPendingWMFSave() } }
            Button("Save a Copy as EMF…") { saveSceneCopyAsEMF() }
            Button("Cancel", role: .cancel) { session.cancelPendingWMFSave() }
        } message: { pending in
            Text(WMFLimitationWording.message(for: pending))
        }
        .overlay(alignment: .top) {
            if session.showsExternalChangeBanner {
                externalChangeBanner
            }
        }
        .overlay {
            if exporter.isRendering {
                ExportProgressOverlay { exporter.cancelExport() }
            }
        }
        .background(keyboardCommands)
        // Publish the viewer's actions to the scene so the shared iOS View menu drives
        // zoom / controls / Info even while the sidebar holds first responder (K1).
        .focusedSceneValue(\.viewerActions, viewerActions)
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
        // A Rendering settings change re-prepares the open file live, keeping the zoom
        // where practical; render-time options also reach the tiles through the
        // `options` prop above (S1b).
        .onChange(of: settings.renderOptions) { _, new in
            session.applyRenderOptions(new)
        }
        // Typed save-failure and saved-with-limitations toasts (E2a-9 / E2a-5, review #6).
        .onChange(of: session.lastSaveError != nil) { _, hasError in
            if hasError, let error = session.lastSaveError {
                toast.show(error.message, systemImage: "exclamationmark.triangle")
                session.clearSaveError()
            }
        }
        .onChange(of: session.pendingSaveNotice != nil) { _, hasNotice in
            if hasNotice, let notice = session.pendingSaveNotice {
                toast.show(WMFLimitationWording.savedSummary(notice.categories), systemImage: "checkmark.circle")
                session.clearSaveNotice()
            }
        }
        // Autosave-flush unsaved edits when the scene backgrounds (E2a-6, review #6).
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await session.flushPendingSave() } }
        }
        .onDisappear {
            pillHideTask?.cancel()
            exporter.cancelOngoing()
            Task { await session.flushPendingSave() }
        }
    }

    /// The non-modal "changed on disk" banner (E2a-8, review #6): keep the edits, or
    /// reload and discard them.
    private var externalChangeBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text("This file changed on disk")
                .font(.callout)
            Spacer(minLength: 8)
            Button("Keep") { session.keepMyEdits() }
                .font(.callout.weight(.semibold))
            Button("Reload", role: .destructive) { showReloadDiscardConfirm = true }
                .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .floatingSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// "Save a Copy as EMF…": exports the scene as EMF and shares it, keeping full
    /// fidelity instead of narrowing to WMF (E2a-5 review #6).
    private func saveSceneCopyAsEMF() {
        session.cancelPendingWMFSave()
        guard let data = session.sceneExportData(as: .emf) else {
            exporter.shareError = "Emfy couldn’t prepare an EMF copy of this drawing."
            return
        }
        exporter.shareSceneCopy(data: data, baseName: entry?.baseName ?? "Drawing")
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
        // Once edits diverge from the opened version, draw the edited scene from
        // SceneRenderer (E2a-3, review #6). E2b layers its editing canvas on top.
        if let pageSize = session.editedPageSize {
            MetafileEditedSceneView(pageSize: pageSize, scale: displayScale, makeImage: { session.makeEditedSceneImage(scale: $0) })
                .id(session.editVersion)
                .ignoresSafeArea()
        } else {
            readOnlyDrawingLayer
        }
    }

    @ViewBuilder
    private var readOnlyDrawingLayer: some View {
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
                defaultZoom: settings.defaultZoomOnOpen,
                pageShadow: settings.pageShadow,
                tilePaint: ViewerTilePaint.make(
                    background: settings.pageBackground,
                    darkMode: settings.darkPageMode,
                    isDark: colorScheme == .dark
                ),
                options: settings.renderOptions,
                onSingleTap: { toggleChrome() }
            )
            .ignoresSafeArea()
            // Rebuild the tiled view only when the content actually changes, so a
            // changed-content reload shows the new drawing while an identical reload
            // keeps the same view and its zoom (C4a M4). The identity also tracks the
            // prepared's size and its WMF embedded-EMF choice, so toggling that option
            // (option 4) rebuilds with the new content, while the render-time options
            // redraw the existing tiles (S1b).
            .id(ViewerContentID(model: model, content: session.loadedContentID))
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

    /// A tail-truncating principal title, only at regular width (iPad), so a long
    /// file name no longer clips at the leading edge behind the sidebar (carry-over c).
    @ToolbarContentBuilder
    private var regularWidthTitle: some ToolbarContent {
        if isRegularWidth {
            ToolbarItem(placement: .principal) {
                Text(entry?.baseName ?? "Metafile")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 460)
            }
        }
    }

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
            let opts = ExportScale.pngOptions(for: model.prepared.naturalSize, settings: settings)
            Button {
                exporter.shareOriginal(entry: entry, store: store)
            } label: {
                Label("Share File", systemImage: "square.and.arrow.up")
            }
            // The default export format leads (S1a-6 Export › Default export format).
            ForEach(ExportMenuOrder.formats(default: settings.defaultExportFormat), id: \.self) { format in
                shareFormatButton(format, model: model, entry: entry, opts: opts)
            }
            // SVG is built from the imported scene (F2), so it resolves the file's
            // bytes rather than the prepared raster the PNG/PDF buttons use.
            Button {
                exporter.shareSVG(entry: entry, store: store, baseName: entry.baseName)
            } label: {
                Label("Share as SVG", systemImage: "doc.text")
            }
            Divider()
            Button {
                exporter.copyImage(prepared: model.prepared, scale: opts.scale, background: opts.background, options: settings.renderOptions, toast: toast)
            } label: {
                Label("Copy Image", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("copyImage")
            Button {
                exporter.saveToPhotos(prepared: model.prepared, scale: opts.scale, background: opts.background, options: settings.renderOptions, toast: toast)
            } label: {
                Label("Save to Photos", systemImage: "square.and.arrow.down")
            }
            Divider()
            Button {
                DiagnosticReportAction.copyFileReport(
                    entry: entry,
                    recordKinds: model.prepared.recordKinds,
                    notes: model.couldNotShowNotes,
                    toast: toast
                )
            } label: {
                Label("Copy Diagnostic Report", systemImage: "doc.on.clipboard")
            }
            .accessibilityIdentifier("copyDiagnosticReport")
            // Revert to Opened Version — only once a snapshot exists and the Settings
            // toggle is on (E2a-7, review #6).
            if session.canRevertToOpenedVersion && settings.keepOpenedVersionForRevert {
                Divider()
                Button(role: .destructive) {
                    showRevertConfirm = true
                } label: {
                    Label("Revert to Opened Version", systemImage: "arrow.uturn.backward")
                }
            }
        }
    }

    /// One "Share as PNG/PDF" button, so the default export format can lead the menu.
    @ViewBuilder
    private func shareFormatButton(
        _ format: EmfySettings.ExportFormat,
        model: LoadedMetafile,
        entry: RecentEntry,
        opts: (scale: CGFloat, background: RenderBackground)
    ) -> some View {
        switch format {
        case .png:
            Button {
                exporter.share(.png, prepared: model.prepared, baseName: entry.baseName, scale: opts.scale, background: opts.background, options: settings.renderOptions)
            } label: {
                Label("Share as PNG", systemImage: "photo")
            }
        case .pdf:
            Button {
                exporter.share(.pdf, prepared: model.prepared, baseName: entry.baseName, scale: opts.scale, background: opts.background, options: settings.renderOptions)
            } label: {
                Label("Share as PDF", systemImage: "doc.richtext")
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

    // The zoom group (⌘0 / ⌘9 / ⌘+ / ⌘= / ⌘−), the controls toggle (⌃⌘H) and Info
    // (⌘I) are now registered once, in the shared iOS View menu (`ViewerCommandsIOS`),
    // and driven by this viewer's `focusedSceneValue` — so they fire even while the
    // sidebar holds first responder, which a view-level `.keyboardShortcut` could not
    // (K1). Only Esc stays here: it just restores the chrome from immersive mode, and
    // the user is already working inside the viewer to be in that mode. Hidden from
    // VoiceOver.
    private var keyboardCommands: some View {
        Button("Show Controls") { if chromeHidden { toggleChrome() } }
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityHidden(true)
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
    }

    /// The viewer actions published to the scene for the shared iOS View menu (K1):
    /// the zoom group plus the immersive-controls and Info toggles. Rebuilt when
    /// `isLoaded` or `chromeHidden` change — not per zoom frame — so it never churns
    /// the menu bar while pinching.
    private var viewerActions: ViewerActions {
        ViewerActions(
            isDocumentLoaded: isLoaded,
            zoomIn: { controller.zoomIn() },
            zoomOut: { controller.zoomOut() },
            fit: { controller.fit() },
            actualSize: { controller.actualSize() },
            toggleChrome: isLoaded ? { toggleChrome() } : nil,
            toggleInfo: { toggleInspector() },
            isChromeHidden: chromeHidden
        )
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
                floatingGroup(xOffset: xOffset, sideWidth: sideWidth)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.top, topInset)
        }
    }

    /// The pill and banner, wrapped in a `GlassEffectContainer` on 26 so the two
    /// glass surfaces merge cleanly when both show; a plain stack below (G1).
    @ViewBuilder
    private func floatingGroup(xOffset: CGFloat, sideWidth: CGFloat) -> some View {
        let content = VStack(spacing: 8) {
            if pillVisible {
                ZoomPill(controller: controller)
                    .offset(x: xOffset)
                    .transition(reduceMotion ? .identity : .opacity)
            }
            if showBanner, let message = partialMessage {
                banner(message)
                    .frame(maxWidth: sideWidth - 24)
                    .offset(x: xOffset)
                    .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
            }
        }
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { content }
        } else {
            content
        }
    }

    private var showBanner: Bool {
        // The partial-support banner is hidden when the setting is off (S1a-4); the
        // Info panel's notes stay either way.
        settings.showPartialSupportBanner && !chromeHidden && !bannerDismissed && partialMessage != nil
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
        .floatingSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                couldNotShowNotes: model.couldNotShowNotes,
                naturalSize: model.naturalSize,
                // The Zoom row is reachable on both iPhone (sheet) and iPad (column),
                // with − / + 25% steppers driving the viewer's controller (A14). A
                // closure, so the live % is read inside the Zoom row's leaf, not here
                // (P2).
                zoomProvider: { Int((controller.zoom * 100).rounded()) },
                onClose: { closeInspector() },
                onZoomStep: { delta in controller.step(by: delta) }
            )
            // At compact width the inspector is a sheet — a separate hosting view that
            // reads ToastCenter and EmfySettings — so re-inject them rather than rely on
            // the presenting view's injection surviving the snapshot re-layout (C1).
            .environment(toast)
            .environment(settings)
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
        loaded?.partialSupportMessage   // precomputed at load (P6)
    }

    private var entry: RecentEntry? {
        store.entry(id: session.entryID)
    }

    private var subtitle: String {
        entry?.formatSizeSubtitle ?? ""
    }
}

/// Draws an edited scene from `SceneRenderer` (E2a-3, review #6). A minimal
/// fit-to-view raster for E2a — it renders once per edit version at the backing
/// resolution; E2b's canvas replaces it with the interactive editing surface.
private struct MetafileEditedSceneView: View {
    let pageSize: CGSize
    let scale: CGFloat
    let makeImage: (CGFloat) -> CGImage?

    var body: some View {
        GeometryReader { proxy in
            if let image = makeImage(editScale(for: proxy.size)) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color(.systemGroupedBackground)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private func editScale(for viewport: CGSize) -> CGFloat {
        guard pageSize.width > 0, pageSize.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        let fit = min(viewport.width / pageSize.width, viewport.height / pageSize.height)
        return min(max(fit * scale, 1), 4)
    }
}

/// The transient zoom pill, as its own leaf view reading the controller, so the live
/// percentage invalidates only the pill each pinch frame — not `MetafileViewerScreen.body`,
/// which hosts the inspector and publishes `viewerActions` (P2).
private struct ZoomPill: View {
    let controller: MetafileZoomController

    var body: some View {
        let percent = Int((controller.zoom * 100).rounded())
        Text("\(percent)%")
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .floatingSurface(in: Capsule())
            .accessibilityHidden(true)
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
