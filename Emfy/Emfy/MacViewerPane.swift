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
    @State private var editorModel = EditorModel()
    @State private var showInspector = false
    @State private var showRevertConfirm = false
    @State private var showReloadDiscardConfirm = false
    #if DEBUG
    @State private var debugLaunchRan = false
    #endif

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
            .fileExporter(
                isPresented: $exporter.isExportingSVG,
                document: exporter.svgDocument,
                contentType: .svg,
                defaultFilename: entry?.baseName ?? "Metafile"
            ) { result in
                handleExport(result, format: "SVG")
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
            // A Rendering settings change re-prepares the open file live, keeping the
            // zoom and scroll where practical; render-time options also reach the tiles
            // through the `options` prop above (S1b).
            .onChange(of: settings.renderOptions) { _, new in
                session.applyRenderOptions(new)
            }
            // Editing (E2a): revert confirmation, the WMF first-save limitations
            // dialog, the "changed on disk" banner, and typed save-failure toasts.
            .confirmationDialog(
                "Revert to the version you opened?",
                isPresented: $showRevertConfirm,
                titleVisibility: .visible
            ) {
                Button("Revert", role: .destructive) { Task { await session.revertToOpenedVersion() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This replaces the file on disk with the version Emfy opened and discards your edits. This can’t be undone.")
            }
            .confirmationDialog(
                "Save as WMF?",
                isPresented: Binding(
                    get: { session.pendingWMFConfirmation != nil },
                    set: { if !$0 { session.cancelPendingWMFSave() } }
                ),
                titleVisibility: .visible,
                presenting: session.pendingWMFConfirmation
            ) { pending in
                Button("Save Anyway") { Task { await session.confirmPendingWMFSave() } }
                Button("Save a Copy as EMF…") { saveSceneCopyAsEMF() }
                Button("Cancel", role: .cancel) { session.cancelPendingWMFSave() }
            } message: { pending in
                Text(WMFLimitationWording.message(for: pending))
            }
            .fileExporter(
                isPresented: $exporter.isExportingSceneEMF,
                document: exporter.sceneCopyDocument,
                contentType: .data,
                defaultFilename: (entry?.baseName ?? "Metafile") + ".emf"
            ) { _ in }
            .overlay(alignment: .top) {
                if session.showsExternalChangeBanner {
                    externalChangeBanner
                }
            }
            .onChange(of: session.lastSaveError != nil) { _, hasError in
                if hasError, let error = session.lastSaveError {
                    toast.show(error.message, systemImage: "exclamationmark.triangle")
                    session.clearSaveError()
                }
            }
            // A non-WMF explicit save that lost fidelity surfaces a one-line toast
            // naming the simplified areas (E2a-5, review #5).
            .onChange(of: session.pendingSaveNotice != nil) { _, hasNotice in
                if hasNotice, let notice = session.pendingSaveNotice {
                    toast.show(WMFLimitationWording.savedSummary(notice.categories), systemImage: "checkmark.circle")
                    session.clearSaveNotice()
                }
            }
            .onDisappear {
                exporter.cancelOngoing()
                Task { await session.flushPendingSave() }
            }
            #if DEBUG
            .task { await runDebugLaunchIfNeeded() }
            #endif
    }

    #if DEBUG
    /// The E2b screenshot hook (design call E2b-8): once the file loads, optionally
    /// enter edit mode, pre-select the first N editable elements, and — when a
    /// screenshot base path is given — capture the window at fit and at 400% and quit.
    @MainActor
    private func runDebugLaunchIfNeeded() async {
        guard !debugLaunchRan, EditorDebugLaunch.isActive else { return }
        debugLaunchRan = true
        for _ in 0..<80 { if session.loaded != nil { break }; try? await Task.sleep(for: .milliseconds(100)) }
        guard session.loaded != nil else { return }
        if EditorDebugLaunch.editOnOpen {
            await session.beginEditing()
            if session.editing == .editing, EditorDebugLaunch.selectText, let tid = session.firstTextElementID() {
                editorModel.selection.replace(with: tid)
            } else if session.editing == .editing, EditorDebugLaunch.selectFirst > 0 {
                editorModel.selection.replace(with: session.firstEditableIDs(EditorDebugLaunch.selectFirst))
            }
        }
        // E2c captures (Format inspector, text popover, recolour+delete) take a distinct,
        // single-shot path — the composite capture includes a popover window.
        if EditorDebugLaunch.isE2cCapture {
            await captureE2cScreenshot()
            return
        }
        guard let base = EditorDebugLaunch.screenshotBase else { return }
        try? await Task.sleep(for: .milliseconds(1200))
        // Required captures: edit mode with the multi-selection + handles, at fit and 400%.
        controller.fit()
        try? await Task.sleep(for: .milliseconds(800))
        _ = EditorDebugScreenshot.captureLibraryWindow(to: base + "-fit.png")
        controller.setZoom(4.0)
        controller.debugScrollToTopLeft()   // show the selection's top-left handles at 400%
        try? await Task.sleep(for: .milliseconds(800))
        _ = EditorDebugScreenshot.captureLibraryWindow(to: base + "-400.png")
        // Supplementary: prove one committed transform re-renders the canvas (the
        // selection moves). Re-assert editing first, since a spurious file-presenter
        // event can drop clean edit mode (E2a).
        controller.fit()
        try? await Task.sleep(for: .milliseconds(400))
        if session.editing != .editing {
            await session.beginEditing()
            editorModel.selection.replace(with: session.firstEditableIDs(EditorDebugLaunch.selectFirst))
        }
        session.debugTranslate(ids: editorModel.selection.ids, dx: 55, dy: 45)
        try? await Task.sleep(for: .milliseconds(900))
        _ = EditorDebugScreenshot.captureLibraryWindow(to: base + "-moved.png")
        try? await Task.sleep(for: .milliseconds(200))
        NSApp.terminate(nil)
    }

    /// The E2c single-shot capture: fits, opens the Format inspector / applies a
    /// recolour+delete / opens the text popover per the launch flags, then composites
    /// every window (so a popover shows) to `<base>-e2c.png` and quits.
    @MainActor
    private func captureE2cScreenshot() async {
        guard let base = EditorDebugLaunch.screenshotBase else { return }
        NSApp.activate(ignoringOtherApps: true)   // so a transient popover presents and stays
        // (The forced appearance is applied at launch, in EmfyAppDelegate, so the SwiftUI
        // inspector adopts it from the first render.)
        controller.fit()
        try? await Task.sleep(for: .milliseconds(700))
        if EditorDebugLaunch.showInspector { showInspector = true }
        if EditorDebugLaunch.recolorDelete {
            let ids = editorModel.selection.ids
            session.debugSetFill(ids: ids, red: 0.20, green: 0.55, blue: 0.95)
            if let first = ids.sorted().first { session.deleteSelection([first]) }
        }
        if EditorDebugLaunch.textEdit, let tid = session.firstTextElementID(), let string = session.textString(of: tid) {
            editorModel.selection.replace(with: tid)
            // A fixed anchor near the first run, so the capture reliably shows the popover
            // (real double-clicks compute the anchor from the run's reference point).
            editorModel.textEdit = TextEditRequest(id: tid, anchor: UnitPoint(x: 0.4, y: 0.28), initialText: string)
        }
        try? await Task.sleep(for: .milliseconds(1200))
        _ = EditorDebugScreenshot.captureAllWindows(to: base + "-e2c.png")
        session.debugCancelAutosave()   // never write on the way out of a capture run
        try? await Task.sleep(for: .milliseconds(200))
        // exit() rather than NSApp.terminate(): a capture of a recolour+delete leaves the
        // (temp-copy) document dirty, and terminate would raise the unsaved-changes prompt
        // and hang. The screenshot is already written; nothing needs saving.
        exit(0)
    }
    #endif

    /// The non-modal banner shown when the file changed on disk while there were
    /// unsaved edits (design call E2a-8): keep the edits, or reload and discard them.
    private var externalChangeBanner: some View {
        HStack(spacing: 12) {
            Label("This file changed on disk", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            Spacer()
            Button("Keep My Edits") { session.keepMyEdits() }
            Button("Reload…", role: .destructive) { showReloadDiscardConfirm = true }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
        .shadow(radius: 4, y: 2)
        .confirmationDialog(
            "Reload and discard your edits?",
            isPresented: $showReloadDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Reload", role: .destructive) { Task { await session.reloadDiscardingEdits() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The on-disk version replaces what’s on screen. Your unsaved edits are lost.")
        }
    }

    /// "Save a Copy as EMF…": exports the current scene as EMF and presents a file
    /// exporter, keeping full fidelity instead of narrowing to WMF.
    private func saveSceneCopyAsEMF() {
        guard let data = session.sceneExportData(as: .emf) else {
            exporter.errorMessage = "Emfy couldn’t prepare an EMF copy of this drawing."
            return
        }
        session.cancelPendingWMFSave()
        exporter.exportSceneCopy(data: data)
    }

    @ViewBuilder
    private var content: some View {
        // In edit mode the drawing is fed from the scene (so what's on screen is what's
        // selectable), through the crisp tiled canvas with the selection overlay on top
        // (design calls E2b-1/-2). Read-only viewing keeps the prepared-model tiled view.
        if session.editing == .editing {
            MacEditingContainer(
                session: session, editorModel: editorModel, controller: controller,
                pageShadow: settings.pageShadow,
                tilePaint: ViewerTilePaint.make(
                    background: settings.pageBackground, darkMode: settings.darkPageMode, isDark: colorScheme == .dark
                ),
                options: settings.renderOptions
            )
            .ignoresSafeArea()
            .overlay(alignment: .bottom) { rotationReadout }
        } else {
            readOnlyContent
        }
    }

    /// The live rotation-angle readout while a rotation drag is in flight (E2b-6).
    @ViewBuilder
    private var rotationReadout: some View {
        if let readout = editorModel.rotationReadout {
            Text(readout)
                .font(.system(.body, design: .rounded).monospacedDigit())
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var readOnlyContent: some View {
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
                scrollAction: settings.macScrollAction,
                options: settings.renderOptions
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
        // In edit mode with a selection, the Format panel replaces Info (a Format | Info
        // segmented control switches between them); otherwise Info as today (E2c design
        // call 1).
        if session.editing == .editing, !editorModel.selection.isEmpty, loaded != nil, entry != nil {
            EditorInspectorPanel(session: session, editorModel: editorModel, onClose: { showInspector = false }) {
                infoView
            }
        } else {
            infoView
        }
    }

    @ViewBuilder
    private var infoView: some View {
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
            ToolbarItem { editButton }
            ToolbarSpacer(.fixed)
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
                editButton
                zoomOutButton
                MacZoomPercentLabel(controller: controller)
                zoomInButton
                fitButton
                shareMenu
                infoButton
            }
        }
    }

    /// The Edit toggle (design call E2b-1), modelled on Preview's Markup button:
    /// entering lifts the scene and shows the selection canvas; leaving clears the
    /// selection and flushes any pending save. A tint marks the active state.
    private var editButton: some View {
        Button {
            toggleEditMode()
        } label: {
            Label("Edit", systemImage: "pencil.tip.crop.circle")
        }
        .disabled(loaded == nil)
        .help("Edit")
        .symbolVariant(session.editing == .editing ? .fill : .none)
        .foregroundStyle(session.editing == .editing ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }

    private func toggleEditMode() {
        if session.editing == .editing {
            editorModel.selection.clear()
            Task { await session.endEditing() }
        } else {
            Task {
                await session.beginEditing()
                if session.editing == .unavailable {
                    toast.show("This file can’t be edited", systemImage: "pencil.slash")
                    await session.endEditing()   // reset to not-editing so the toggle reads off
                }
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
            Button {
                shareSVG()
            } label: {
                Label("Share as SVG", systemImage: "doc.text")
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
        let opts = ExportScale.pngOptions(for: loaded.prepared.naturalSize, settings: settings)
        exporter.exportToFile(format, prepared: loaded.prepared, scale: opts.scale, background: opts.background, options: settings.renderOptions)
    }

    private func share(_ format: ExportFormat) {
        guard let loaded, let entry else { return }
        let opts = ExportScale.pngOptions(for: loaded.prepared.naturalSize, settings: settings)
        exporter.share(format, prepared: loaded.prepared, baseName: entry.baseName, scale: opts.scale, background: opts.background, options: settings.renderOptions)
    }

    /// SVG export/share build from the imported scene, so they take the file's bytes
    /// (resolved by the exporter) rather than the prepared raster (F2).
    private func exportSVG() {
        guard let entry else { return }
        exporter.exportSVGToFile(entry: entry, store: store)
    }

    private func shareSVG() {
        guard let entry else { return }
        exporter.shareSVG(entry: entry, store: store, baseName: entry.baseName)
    }

    private func shareOriginal() {
        guard let entry else { return }
        exporter.shareOriginal(entry: entry, store: store)
    }

    /// Builds the privacy-safe diagnostic report for the current file, copies it to
    /// the clipboard and confirms with a toast (S1a-6). Published to the Help menu
    /// via `ViewerActions` and called by the Info inspector's own button.
    private func copyDiagnosticReport() {
        guard let loaded, let entry else { return }
        DiagnosticReportAction.copyFileReport(
            entry: entry,
            recordKinds: loaded.prepared.recordKinds,
            notes: loaded.couldNotShowNotes,
            toast: toast
        )
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
            exportSVG: { exportSVG() },
            shareFile: { shareOriginal() },
            sharePNG: { share(.png) },
            sharePDF: { share(.pdf) },
            shareSVG: { shareSVG() },
            copyDiagnosticReport: loaded != nil ? { copyDiagnosticReport() } : nil,
            save: (session.editing == .editing && session.isDirty) ? { Task { await session.save() } } : nil,
            revertToOpenedVersion: (session.canRevertToOpenedVersion && settings.keepOpenedVersionForRevert) ? { showRevertConfirm = true } : nil,
            selectAllElements: session.editing == .editing ? { selectAllElements() } : nil,
            deselectElements: (session.editing == .editing && !editorModel.selection.isEmpty) ? { editorModel.selection.clear() } : nil,
            deleteSelection: (session.editing == .editing && !editorModel.selection.isEmpty) ? { session.deleteSelection(editorModel.selection.ids) } : nil
        )
    }

    /// ⌘A: select every editable element (design call E2b-4).
    private func selectAllElements() {
        editorModel.selection.replace(with: session.allEditableIDs())
    }

    private var entry: RecentEntry? {
        store.entry(id: session.entryID)
    }

    /// Format · size for the navigation subtitle, via the shared helper (G6), with an
    /// "Edited" marker while there are unsaved edits (E2a-9, review #7). Reads the
    /// entry and the dirty flag, never the zoom, so it stays off the per-frame path.
    private var subtitle: String {
        let base = entry?.formatSizeSubtitle ?? ""
        return session.isDirty ? (base.isEmpty ? "Edited" : "\(base) — Edited") : base
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
