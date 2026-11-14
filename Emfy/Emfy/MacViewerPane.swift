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
    @Environment(AIProviderStore.self) private var aiProviders: AIProviderStore?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: DocumentSession
    /// Clears the window's selection when the file is removed from Recents.
    let onRemove: () -> Void

    @State private var controller = MacMetafileZoomController()
    @State private var exporter = MacViewerExporter()
    @State private var editorModel = EditorModel()
    @State private var findModel = DrawingFindModel()
    // Inspector open state and tab persist per scene across relaunch (N2).
    @SceneStorage("viewer.inspector.open") private var showInspector = false
    // Records inspector + step-through replay (F5c).
    @SceneStorage("viewer.inspector.tab") private var viewerInspectorTab: ViewerInspectorTab = .info
    @State private var recordModel = RecordInspectorModel()
    @State private var replayDriver = RecordReplayDriver()
    // On-device AI (A1a): Describe + alt text + Ask.
    @State private var describeModel = DrawingDescribeModel()
    @State private var askModel = DrawingAskModel()
    @State private var altTextStore = DrawingAltTextStore()
    // Accessibility Check (X1a): deterministic analysis + fixes + AI summary.
    @State private var checkModel = DrawingCheckModel()
    @State private var summariseModel = DrawingSummariseModel()
    // Editor AI edit + recolour (X2a), reachable from the Edit menu, selection-scoped.
    @State private var aiEditModel = DrawingAIEditModel()
    @State private var recolourModel = DrawingRecolourModel()
    @State private var translateModel = DrawingAITranslateModel()
    @State private var showingAIEditSheet = false
    @State private var showingRecolourSheet = false
    @State private var showingTranslateSheet = false
    @State private var showRevertConfirm = false
    @State private var showReloadDiscardConfirm = false
    // Translate (F3d): the system Translate overlay presentation.
    @State private var showTranslation = false
    // Send to AI… (A3b): the pre-sheet and its "Include the original file" toggle (off).
    @State private var showAIShareConfirm = false
    @State private var aiShareIncludeOriginal = false
    #if DEBUG
    @State private var debugLaunchRan = false
    #endif

    private var loaded: LoadedMetafile? { session.loaded }

    var body: some View {
        @Bindable var exporter = exporter
        content
            // The viewer context menu's Translate… (F3d), alongside the Edit menu item.
            .contextMenu { translateMenuItem }
            // Translate (F3d): the system overlay for the current Find match or the drawing's
            // text, in one gated modifier (macOS 14.4).
            .modifier(DrawingTranslationModifier(isPresented: $showTranslation, text: translationText))
            .navigationTitle(entry?.baseName ?? "Metafile")
            // Format · size under the title, using the shared helper (G6).
            .navigationSubtitle(subtitle)
            .toolbar { toolbarContent }
            // The find bar and the external-change banner share ONE top stack so they can
            // never overlap (audit L-B), wrapped in a GlassEffectContainer on 26 so the two
            // glass surfaces merge cleanly. The find bar slides in on ⌘F (F3b); Esc closes it.
            .overlay(alignment: .top) { topOverlays }
            // Keep the find model's runs current: the renderer observation in viewer mode,
            // the edited scene in edit mode (F3b). Recomputed only when the drawing changes.
            .task(id: findRunsKey) { await refreshFindRuns() }
            // Toggling "Recognise text in pictures" (F3c): off drops picture matches and
            // clears the in-memory cache; on re-runs the find pass so OCR starts.
            .onChange(of: settings.recognizeTextInPictures) { _, enabled in
                if enabled {
                    Task { await refreshFindRuns() }
                } else {
                    findModel.clearPictureRuns()
                    Task { await DrawingOCRService.shared.clearMemoryCache() }
                }
            }
            // Scroll the current match into view as Find Next/Previous or a live query moves
            // it (F3b).
            .onChange(of: findModel.current) { _, _ in scrollToCurrentMatch() }
            .inspector(isPresented: $showInspector) {
                inspector
            }
            // Editor AI edit + recolour sheets (X2a), driven by the Edit-menu entries.
            .sheet(isPresented: $showingAIEditSheet) {
                DrawingAIEditView(model: aiEditModel, onClose: { showingAIEditSheet = false })
                    .environment(aiProviders)
            }
            .sheet(isPresented: $showingRecolourSheet) {
                DrawingRecolourView(model: recolourModel, onClose: { showingRecolourSheet = false })
            }
            // Editor translate-in-place sheet (X2c), driven by the Edit-menu entry.
            .sheet(isPresented: $showingTranslateSheet) {
                DrawingAITranslateView(model: translateModel, onClose: { showingTranslateSheet = false })
                    .environment(aiProviders)
            }
            // Records inspector (F5c): (re)configure when the segment is shown or the
            // content changes, render each selection off-main, and rebuild on an
            // options change that keeps the same content id.
            .task(id: recordsConfigKey) { configureRecordsIfNeeded() }
            // On-device AI (A1a): reset the models and seed alt text when the drawing
            // changes (or edit mode flips, which hides/affects the AI inputs).
            .task(id: "\(session.loadedContentID)·\(session.editing == .editing)") { configureAIForCurrentDrawing() }
            // Accessibility Check (X1a): re-run the analysis when the drawing, the edit, or
            // the Check segment's visibility changes.
            .task(id: checkConfigKey) { configureCheckIfNeeded() }
            .onChange(of: recordModel.selectedIndex) { _, index in
                replayDriver.request(index: index, model: recordModel)
            }
            .onChange(of: settings.renderOptions) { _, _ in
                replayDriver.invalidate()
                configureRecordsIfNeeded()
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
            // Edit ▸ Copy (⌘C), F1 — through the responder chain, so it uses the one
            // system Copy item and a focused text field keeps its own ⌘C.
            .onCopyCommand { copyItemProviders() }
            // Publish this window's actions to the shared menu bar (C3b scope 1).
            .focusedSceneValue(\.viewerActions, viewerActions)
            // Intercept the window close (red button / ⌘W) to flush and, if needed,
            // confirm unsaved edits before closing — the window-level equivalent of the
            // quit prompt (E2d). A clean window closes immediately. Zero-size, installed
            // on the host NSWindow via an AppKit delegate bridge.
            .background(WindowCloseGuard(session: session, documentName: entry?.baseName ?? "this file"))
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
                // The dismiss setter cancels ONLY a genuine dismissal, never while a button is
                // resolving (R2U1): a tapped "Save Anyway" marks the resolution synchronously, so
                // this setter no longer pre-empts its async write.
                isPresented: Binding(
                    get: { session.pendingWMFConfirmation != nil },
                    set: { if !$0 { session.dismissPendingWMFConfirmation() } }
                ),
                titleVisibility: .visible,
                presenting: session.pendingWMFConfirmation
            ) { pending in
                Button("Save Anyway") { session.beginResolvingWMFConfirmation(); Task { await session.confirmPendingWMFSave() } }
                Button("Save a Copy as EMF…") { session.beginResolvingWMFConfirmation(); saveSceneCopyAsEMF() }
                // Only while leaving edit mode (Done): let the user drop the edits and
                // exit rather than being stuck in the editor on a dirty WMF (U1).
                if session.isEndingEditing {
                    Button("Don’t Save", role: .destructive) { session.beginResolvingWMFConfirmation(); session.discardEditsAndStopEditing() }
                }
                Button("Cancel", role: .cancel) { session.cancelPendingWMFSave() }
            } message: { pending in
                Text(WMFLimitationWording.message(for: pending))
            }
            // A save that fails while leaving edit mode (Done / switch) used to trap the user in
            // the editor with only a transient toast (R2U2). Offer a real way out, wired to the
            // same leave-completion hook as the WMF dialog.
            .alert(
                "Couldn’t Save",
                isPresented: Binding(get: { session.isLeaveBlockedBySaveError }, set: { _ in }),
                presenting: session.lastSaveError
            ) { _ in
                Button("Try Again") { Task { await session.retryEndEditing() } }
                Button("Save a Copy as EMF…") { session.cancelEndEditingAfterSaveError(); saveSceneCopyAsEMF() }
                Button("Don’t Save", role: .destructive) { session.discardEditsAndStopEditing() }
                Button("Cancel", role: .cancel) { session.cancelEndEditingAfterSaveError() }
            } message: { error in
                Text(error.message)
            }
            .fileExporter(
                isPresented: $exporter.isExportingSceneEMF,
                document: exporter.sceneCopyDocument,
                contentType: .data,
                defaultFilename: (entry?.baseName ?? "Metafile") + ".emf"
            ) { _ in }
            .onChange(of: session.lastSaveError != nil) { _, hasError in
                // A failure that blocks a leave is handled by the R2U2 alert, not a toast.
                if hasError, let error = session.lastSaveError, !session.isEndingEditing {
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
        // F5c: the Records inspector perf log and screenshot flows.
        if EditorDebugLaunch.recordsPerf { await runRecordsPerf(); return }
        if EditorDebugLaunch.recordsInspector, let base = EditorDebugLaunch.screenshotBase {
            await runRecordsCapture(base: base); return
        }
        // F3b: the find menu audit (⌘F/⌘G counts) and the find-bar screenshot flows.
        if EditorDebugLaunch.findMenuAudit, let base = EditorDebugLaunch.screenshotBase {
            await runFindMenuAudit(base: base)
            return
        }
        if EditorDebugLaunch.findQuery != nil, let base = EditorDebugLaunch.screenshotBase {
            await runFindCapture(base: base)
            return
        }
        // A scripted end-to-end gate flow (E2d) takes a distinct path.
        if let script = EditorDebugLaunch.script {
            await runDebugScript(script)
            return
        }
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
        // Centre on the drawing for a P2b viewer proof shot; otherwise top-left to
        // show an edit-mode selection's handles.
        if EditorDebugLaunch.shotCenter {
            controller.debugScrollToDrawingCenter()
        } else {
            controller.debugScrollToTopLeft()
        }
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

    /// F5c: opens the inspector on the Records segment, steps to the requested record
    /// (default: the last, the full drawing), waits for the off-main render to land, then
    /// captures the window (the list, scrubber, DC panel and outlined replay) and quits.
    @MainActor
    private func runRecordsCapture(base: String) async {
        NSApp.activate(ignoringOtherApps: true)
        controller.fit()
        showInspector = true
        viewerInspectorTab = .records
        configureRecordsIfNeeded()
        for _ in 0..<120 where !recordModel.hasRecords { try? await Task.sleep(for: .milliseconds(100)) }
        // A specific mid index snaps to the nearest DRAWING record so the capture always
        // outlines a drawn shape; no index means the last record (the full drawing).
        let index: Int
        if let requested = EditorDebugLaunch.recordIndex {
            index = recordModel.drawingIndices.min(by: { abs($0 - requested) < abs($1 - requested) }) ?? requested
        } else {
            index = max(0, recordModel.recordCount - 1)
        }
        recordModel.select(index)
        for _ in 0..<80 {
            if replayDriver.image != nil || !recordModel.supportsPartial { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(1400))
        Self.logScript("records: count=\(recordModel.recordCount) index=\(recordModel.selectedIndex) supportsPartial=\(recordModel.supportsPartial) image=\(replayDriver.image != nil)")
        if !EditorDebugScreenshot.captureLibraryWindow(to: base + "-records.png") {
            _ = EditorDebugScreenshot.captureLargestWindowOffscreen(to: base + "-records.png")
        }
        session.debugCancelAutosave()
        try? await Task.sleep(for: .milliseconds(200))
        exit(0)
    }

    /// F5c: steps through every record of the opened (WS-A) file once, measuring each,
    /// then logs the median step and first→last span by label only — never the filename.
    @MainActor
    private func runRecordsPerf() async {
        showInspector = true
        viewerInspectorTab = .records
        configureRecordsIfNeeded()
        for _ in 0..<300 where !recordModel.hasRecords { try? await Task.sleep(for: .milliseconds(100)) }
        let perf = await replayDriver.runPerf(count: recordModel.recordCount)
        Self.logScript("records-perf \(EditorDebugLaunch.recordsLabel) records=\(recordModel.recordCount) medianStepMs=\(String(format: "%.3f", perf.median)) firstToLastMs=\(String(format: "%.1f", perf.span)) steps=\(perf.count) supportsPartial=\(recordModel.supportsPartial)")
        session.debugCancelAutosave()
        try? await Task.sleep(for: .milliseconds(100))
        exit(0)
    }

    /// F3b: opens the find bar, searches `EditorDebugLaunch.findQuery` (in edit mode too
    /// when `-EmfyDebugEdit YES`), scrolls the first match into view and captures the window
    /// (so the bar, "n of m" and the yellow highlights show), then quits.
    @MainActor
    private func runFindCapture(base: String) async {
        NSApp.activate(ignoringOtherApps: true)
        if EditorDebugLaunch.editOnOpen { await session.beginEditing() }
        controller.fit()
        try? await Task.sleep(for: .milliseconds(600))
        await refreshFindRuns()
        findModel.present()
        findModel.query = EditorDebugLaunch.findQuery ?? ""
        findModel.applyQuery()
        // F3c: picture OCR runs off the main actor; wait for it so a find-in-picture capture
        // shows the recognised match. `setPictureRuns` re-matches against the live query, so
        // the highlight appears as soon as OCR finishes (cap the wait for a file with none).
        var waited = 0
        while findModel.isReadingPictures, waited < 45000 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 100
        }
        try? await Task.sleep(for: .milliseconds(300))
        scrollToCurrentMatch()
        try? await Task.sleep(for: .milliseconds(900))
        let path = base + (EditorDebugLaunch.editOnOpen ? "-edit.png" : "-viewer.png")
        if !EditorDebugScreenshot.captureLibraryWindow(to: path) {
            _ = EditorDebugScreenshot.captureLargestWindowOffscreen(to: path)
        }
        Self.logScript("find: query=\"\(findModel.query)\" status=\"\(findModel.statusText)\" matches=\(findModel.matches.count) editing=\(session.editing == .editing)")
        session.debugCancelAutosave()
        try? await Task.sleep(for: .milliseconds(200))
        exit(0)
    }

    /// F3b: counts the Find ⌘F / Find Next ⌘G / Find Previous ⇧⌘G menu items (each must be
    /// exactly one) and writes the counts next to the shots, then quits.
    @MainActor
    private func runFindMenuAudit(base: String) async {
        try? await Task.sleep(for: .milliseconds(800))
        let menu = NSApp.mainMenu ?? NSMenu()
        let f = MenuShortcutAudit.count(key: "f", modifiers: [.command], in: menu)
        let g = MenuShortcutAudit.count(key: "g", modifiers: [.command], in: menu)
        let gShift = MenuShortcutAudit.count(key: "g", modifiers: [.command, .shift], in: menu)
        try? "command-F items: \(f)\ncommand-G items: \(g)\nshift-command-G items: \(gShift)\n"
            .write(toFile: base + "-find-menu-audit.txt", atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(150))
        exit(0)
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
        if EditorDebugLaunch.clearFill {
            session.debugClearFill(ids: editorModel.selection.ids)
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

    // MARK: - E2d scripted gate flows

    /// Dispatches an `-EmfyDebugScript` gate flow (E2d). Each flow screenshots then exits
    /// the process, so a launch is always self-terminating.
    @MainActor
    private func runDebugScript(_ script: String) async {
        guard let base = EditorDebugLaunch.screenshotBase else { Self.logScript("no -EmfyDebugShot base"); exit(1) }
        switch script {
        case "edit-save": await runEditSaveScript(base: base)
        case "plain": await runPlainScript(base: base)
        case "close-dirty": await runCloseDirtyScript(base: base)
        case "undo-redo": await runUndoRedoScript(base: base)
        case "new-shapes": await runNewShapesScript(base: base)
        case "pen-strokes": await runPenStrokesScript(base: base)
        case "text-image": await runTextImageScript(base: base)
        case "text-popover": await runTextPopoverScript(base: base)
        case "layers": await runLayersScript(base: base)
        case "align-grid": await runAlignGridScript(base: base)
        case "a11y-dump": await runAccessibilityDumpScript(base: base)
        default: Self.logScript("unknown script \(script)"); exit(1)
        }
    }

    /// `undo-redo`: edit mode → select the first element → Change Fill (purple) → fire the
    /// REAL Edit ▸ Undo menu item (update + performActionForItem) and assert the scene
    /// reverted → screenshot → fire the real Redo item and assert it re-applies → exit.
    @MainActor
    private func runUndoRedoScript(base: String) async {
        NSApp.activate(ignoringOtherApps: true)
        Self.scriptWindow()?.makeKeyAndOrderFront(nil)
        controller.fit()
        try? await Task.sleep(for: .milliseconds(500))
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("undo-redo: begin editing failed"); exit(2) }
        let ids = session.firstEditableIDs(1)
        editorModel.selection.replace(with: ids)
        session.debugSetFill(ids: ids, red: 0.55, green: 0.10, blue: 0.85)   // a Change Fill edit
        session.debugCancelAutosave()
        try? await Task.sleep(for: .milliseconds(600))
        Self.logScript("undo-redo: afterEdit matchesOpened=\(session.debugSceneMatchesOpened())")
        // The REAL Mac menu path: fire Edit ▸ Undo / Redo from NSApp.mainMenu.
        let undo = Self.fireEditMenuItem(titlePrefix: "Undo")
        try? await Task.sleep(for: .milliseconds(600))
        Self.logScript("undo-redo: undoMenuTitle=\"\(undo.title)\" fired=\(undo.fired) afterUndo matchesOpened=\(session.debugSceneMatchesOpened())")
        _ = EditorDebugScreenshot.captureLibraryWindow(to: base + "-undo.png")
        let redo = Self.fireEditMenuItem(titlePrefix: "Redo")
        try? await Task.sleep(for: .milliseconds(600))
        Self.logScript("undo-redo: redoMenuTitle=\"\(redo.title)\" fired=\(redo.fired) afterRedo matchesOpened=\(session.debugSceneMatchesOpened())")
        session.debugCancelAutosave()
        try? await Task.sleep(for: .milliseconds(200))
        exit(0)
    }

    /// Fires a real Edit-menu item by title prefix ("Undo"/"Redo") through AppKit:
    /// `menu.update()` refreshes titles and enablement, then `performActionForItem` sends
    /// the item's action. Returns the validated title and whether it fired (was enabled).
    @MainActor
    private static func fireEditMenuItem(titlePrefix: String) -> (title: String, fired: Bool) {
        guard let editMenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Edit" || $0.title == "Edit" })?.submenu
        else { return ("<no edit menu>", false) }
        editMenu.update()   // run NSMenuValidation so the titles/enablement refresh
        guard let index = editMenu.items.firstIndex(where: { $0.title.hasPrefix(titlePrefix) }) else { return ("<no item>", false) }
        let item = editMenu.items[index]
        guard item.isEnabled else { return (item.title, false) }
        editMenu.performActionForItem(at: index)
        return (item.title, true)
    }

    /// `edit-save`: edit mode → select the first element → move it (+40,+30) → recolour it
    /// vivid purple → screenshot (a) → explicit ⌘S save to the temp copy → exit.
    @MainActor
    private func runEditSaveScript(base: String) async {
        NSApp.activate(ignoringOtherApps: true)
        controller.fit()
        try? await Task.sleep(for: .milliseconds(400))
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("edit-save: begin editing failed"); exit(2) }
        let ids = session.firstEditableIDs(1)
        editorModel.selection.replace(with: ids)
        // The app opens an UNSANDBOXED import copy (a plain path is never security-scoped),
        // so the save writes to that copy, not the temp file the driver named. Log its
        // resolved path so the `plain` relaunch can re-open exactly what was persisted.
        let savedPath = resolvedEntryPath() ?? "?"
        session.debugTranslate(ids: ids, dx: 40, dy: 30)
        session.debugSetFill(ids: ids, red: 0.55, green: 0.10, blue: 0.85)   // vivid purple
        try? await Task.sleep(for: .milliseconds(800))
        _ = EditorDebugScreenshot.captureLibraryWindow(to: base + "-a-edited.png")
        await session.save()
        try? await Task.sleep(for: .milliseconds(500))
        session.debugCancelAutosave()
        Self.logScript("edit-save: savedToPath=\(savedPath) saveError=\(session.lastSaveError.map { "\($0)" } ?? "nil") undoTitle=\(Self.editMenuUndoTitle() ?? "<none>")")
        try? await Task.sleep(for: .milliseconds(200))
        exit(session.lastSaveError == nil ? 0 : 3)
    }

    /// `new-shapes` (E3a): the opened file is a blank A4 drawing → edit mode (an empty
    /// scene is now editable) → insert one of each shape kind through the tool's own code
    /// path → select the last → screenshot (b) → explicit save → exit. A `plain` relaunch
    /// on the same file proves the shapes persisted (screenshot c).
    @MainActor
    private func runNewShapesScript(base: String) async {
        NSApp.activate(ignoringOtherApps: true)
        controller.fit()
        try? await Task.sleep(for: .milliseconds(400))
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("new-shapes: begin editing failed"); exit(2) }
        let page = session.editingScene?.pageSizeDevice ?? CGSize(width: 1122, height: 793)
        let kinds: [ShapeToolKind] = [.rect, .roundRect, .ellipse, .line, .triangle]
        let w = page.width * 0.14
        let h = page.height * 0.22
        var lastID: Int?
        for (i, kind) in kinds.enumerated() {
            let x = page.width * 0.06 + CGFloat(i) * (page.width * 0.88 - w) / CGFloat(kinds.count - 1)
            lastID = session.debugInsertShape(kind, rectDevice: CGRect(x: x, y: page.height * 0.38, width: w, height: h))
        }
        if let lastID { editorModel.selection.replace(with: lastID) }
        session.debugCancelAutosave()
        try? await Task.sleep(for: .milliseconds(1000))
        _ = EditorDebugScreenshot.captureLibraryWindow(to: base + "-b-shapes.png")
        await session.save()
        try? await Task.sleep(for: .milliseconds(500))
        session.debugCancelAutosave()
        Self.logScript("new-shapes: savedPath=\(resolvedEntryPath() ?? "?") saveError=\(session.lastSaveError.map { "\($0)" } ?? "nil") elements=\(session.editingScene?.editableElements.count ?? -1)")
        try? await Task.sleep(for: .milliseconds(200))
        exit(session.lastSaveError == nil ? 0 : 3)
    }

    /// `pen-strokes` (E3b): a blank drawing → edit mode → feed four synthetic strokes through
    /// the SAME pipeline the pen tool uses (`DocumentSession.debugInsertPenStroke` → PenCommit):
    /// a wavy freehand line (no hold → curve), a wobbly circle WITH a hold (→ ellipse), a
    /// wobbly rectangle WITH a hold (→ rect) and a scribble (no hold → curve) → screenshot (a)
    /// → explicit save → exit. A `plain` relaunch proves the strokes persisted (screenshot b).
    @MainActor
    private func runPenStrokesScript(base: String) async {
        NSApp.activate(ignoringOtherApps: true)
        controller.fit()
        try? await Task.sleep(for: .milliseconds(400))
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("pen-strokes: begin editing failed"); exit(2) }

        let wavyLine = Self.wavyLineStroke()
        let circle = Self.wobblyCircleStroke()
        let rect = Self.wobblyRectStroke()
        let scribble = Self.scribbleStroke()
        let line = PenStyle(color: PenPalette.black, widthPoints: 2)
        let bluePen = PenStyle(color: PenPalette.blue, widthPoints: 4)
        let redPen = PenStyle(color: PenPalette.red, widthPoints: 4)
        let greenPen = PenStyle(color: PenPalette.green, widthPoints: 2)
        let id1 = session.debugInsertPenStroke(devicePoints: wavyLine, held: false, pen: line)
        let id2 = session.debugInsertPenStroke(devicePoints: circle, held: true, pen: bluePen)
        let id3 = session.debugInsertPenStroke(devicePoints: rect, held: true, pen: redPen)
        let id4 = session.debugInsertPenStroke(devicePoints: scribble, held: false, pen: greenPen)
        // Arm the pen so the capture shows the toolbar Pen button active (design call 1).
        editorModel.armPen()
        session.debugCancelAutosave()
        try? await Task.sleep(for: .milliseconds(1000))
        // Prefer the on-screen library window; fall back to an offscreen cacheDisplay when
        // the window isn't visible (headless raw-exec launch).
        if !EditorDebugScreenshot.captureLibraryWindow(to: base + "-a-strokes.png") {
            _ = EditorDebugScreenshot.captureLargestWindowOffscreen(to: base + "-a-strokes.png")
        }
        await session.save()
        try? await Task.sleep(for: .milliseconds(500))
        session.debugCancelAutosave()
        let kinds = session.editingScene?.editableElements.map { "\($0.kind)" }.joined(separator: ",") ?? "?"
        Self.logScript("pen-strokes: ids=\(id1 ?? -1),\(id2 ?? -1),\(id3 ?? -1),\(id4 ?? -1) kinds=[\(kinds)] savedPath=\(resolvedEntryPath() ?? "?") saveError=\(session.lastSaveError.map { "\($0)" } ?? "nil")")
        try? await Task.sleep(for: .milliseconds(200))
        exit(session.lastSaveError == nil ? 0 : 3)
    }

    /// `text-image` (E3c): a blank drawing → edit mode → insert a text element "Hello Emfy"
    /// and an in-process gradient image through the SAME tool commit paths
    /// (`debugInsertText` / `debugInsertImage`) → select the image → screenshot (d) → save →
    /// exit. A `plain` relaunch proves persistence.
    @MainActor
    private func runTextImageScript(base: String) async {
        NSApp.activate(ignoringOtherApps: true)
        controller.fit()
        try? await Task.sleep(for: .milliseconds(400))
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("text-image: begin editing failed"); exit(2) }
        let page = session.editingScene?.pageSizeDevice ?? CGSize(width: 1122, height: 793)
        let textID = session.debugInsertText("Hello Emfy", originDevice: CGPoint(x: page.width * 0.12, y: page.height * 0.2))
        let imageID = await session.debugInsertImage(Self.debugGradientPNG(), centreDevice: CGPoint(x: page.width * 0.5, y: page.height * 0.6))
        if let imageID { editorModel.selection.replace(with: imageID) }
        session.debugCancelAutosave()
        try? await Task.sleep(for: .milliseconds(1000))
        if !EditorDebugScreenshot.captureLibraryWindow(to: base + "-d-text-image.png") {
            _ = EditorDebugScreenshot.captureLargestWindowOffscreen(to: base + "-d-text-image.png")
        }
        await session.save()
        try? await Task.sleep(for: .milliseconds(500))
        session.debugCancelAutosave()
        let kinds = session.editingScene?.editableElements.map { "\($0.kind)" }.joined(separator: ",") ?? "?"
        Self.logScript("text-image: textID=\(textID ?? -1) imageID=\(imageID ?? -1) kinds=[\(kinds)] savedPath=\(resolvedEntryPath() ?? "?") saveError=\(session.lastSaveError.map { "\($0)" } ?? "nil")")
        try? await Task.sleep(for: .milliseconds(200))
        exit(session.lastSaveError == nil ? 0 : 3)
    }

    /// `text-popover` (E3c): a blank drawing → edit mode → insert a text element and open its
    /// popover (the SAME popover a text-tool click opens) → screenshot (e, composited so the
    /// popover child window shows over the canvas) → exit.
    @MainActor
    private func runTextPopoverScript(base: String) async {
        NSApp.activate(ignoringOtherApps: true)
        controller.fit()
        try? await Task.sleep(for: .milliseconds(400))
        await session.beginEditing()
        guard session.editing == .editing, let scene = session.editingScene else { Self.logScript("text-popover: begin editing failed"); exit(2) }
        let page = scene.pageSizeDevice
        let insertion = TextToolInsertion.element(originDevice: CGPoint(x: page.width * 0.2, y: page.height * 0.35), in: scene)
        session.beginInsertText(insertion.element)
        editorModel.selection.replace(with: insertion.id)
        editorModel.textEdit = TextEditRequest(id: insertion.id, anchor: UnitPoint(x: 0.3, y: 0.4), initialText: insertion.element.text?.string ?? "Text")
        session.debugCancelAutosave()
        try? await Task.sleep(for: .milliseconds(1200))
        _ = EditorDebugScreenshot.captureAllWindows(to: base + "-e-text-popover.png")
        Self.logScript("text-popover: id=\(insertion.id) popoverOpen=\(editorModel.textEdit != nil)")
        try? await Task.sleep(for: .milliseconds(200))
        exit(0)
    }

    /// `layers` (E3d): a blank drawing → edit mode → rename the base layer Background, add
    /// Shapes and Notes, put one shape in each → hide Notes, lock Background → select the
    /// Shapes shape and Bring to Front → open the Layers tab → screenshot (a) → save → exit.
    /// A `plain` relaunch proves the hidden Notes shape still draws in other readers (b).
    @MainActor
    private func runLayersScript(base: String) async {
        NSApp.activate(ignoringOtherApps: true)
        controller.fit()
        try? await Task.sleep(for: .milliseconds(400))
        await session.beginEditing()
        guard session.editing == .editing, let backgroundID = session.editingScene?.layers.first?.id else {
            Self.logScript("layers: begin editing failed"); exit(2)
        }
        let page = session.editingScene?.pageSizeDevice ?? CGSize(width: 1122, height: 793)
        session.debugRenameLayer(backgroundID, "Background")
        let shapesID = session.debugAddLayer(name: "Shapes", aboveLayer: backgroundID)
        let notesID = shapesID.flatMap { session.debugAddLayer(name: "Notes", aboveLayer: $0) }
        // A shape in each layer, in distinct spots.
        _ = session.debugInsertShape(.rect, rectDevice: CGRect(x: page.width * 0.10, y: page.height * 0.14, width: page.width * 0.52, height: page.height * 0.34), inLayer: backgroundID)
        let shapesShape = shapesID.flatMap { session.debugInsertShape(.ellipse, rectDevice: CGRect(x: page.width * 0.34, y: page.height * 0.30, width: page.width * 0.34, height: page.height * 0.26), inLayer: $0) }
        _ = notesID.flatMap { session.debugInsertShape(.triangle, rectDevice: CGRect(x: page.width * 0.58, y: page.height * 0.50, width: page.width * 0.30, height: page.height * 0.30), inLayer: $0) }
        if let notesID { session.debugSetLayerHidden(notesID, true) }
        session.debugSetLayerLocked(backgroundID, true)
        // Select the Shapes shape, make Shapes the active layer, Bring to Front.
        if let shapesShape { editorModel.selection.replace(with: shapesShape) }
        if let shapesID { editorModel.activeLayerID = shapesID }
        session.bringSelectionToFront(editorModel.selection.ids)
        // Open the Layers tab for the capture.
        EditorDebugLaunch.forceLayersTab = true
        showInspector = true
        session.debugCancelAutosave()
        try? await Task.sleep(for: .milliseconds(1400))
        if !EditorDebugScreenshot.captureLibraryWindow(to: base + "-a-layers.png") {
            _ = EditorDebugScreenshot.captureLargestWindowOffscreen(to: base + "-a-layers.png")
        }
        await session.save()
        try? await Task.sleep(for: .milliseconds(500))
        session.debugCancelAutosave()
        Self.logScript("layers: names=\(session.debugLayerNames()) notesHidden=\(notesID.map { session.debugLayerHidden($0) } ?? false) savedPath=\(resolvedEntryPath() ?? "?") saveError=\(session.lastSaveError.map { "\($0)" } ?? "nil")")
        // (b): leave edit mode and reload the saved file into the plain read-only viewer —
        // the same render path a relaunch uses. The hidden Notes layer is saved and drawn by
        // any plain reader, so its shape now appears (other-apps semantics).
        EditorDebugLaunch.forceLayersTab = false
        showInspector = false
        await session.endEditing()
        await session.load()
        try? await Task.sleep(for: .milliseconds(1000))
        controller.fit()
        try? await Task.sleep(for: .milliseconds(700))
        if !EditorDebugScreenshot.captureLibraryWindow(to: base + "-b-plain.png") {
            _ = EditorDebugScreenshot.captureLargestWindowOffscreen(to: base + "-b-plain.png")
        }
        Self.logScript("layers: reloaded plain loaded=\(session.loaded != nil) recordKinds=\(session.loaded?.prepared.recordKinds.count ?? -1)")
        try? await Task.sleep(for: .milliseconds(200))
        exit(session.lastSaveError == nil ? 0 : 3)
    }

    /// `align-grid` (E3e): a blank drawing → insert 3 shapes at uneven positions → select all
    /// → Align Top → Distribute Horizontally → show the grid → screenshot (a) with the
    /// inspector open (fix B: the page stays fully fitted) → then a live snapped move drag
    /// with a smart guide → screenshot (b) → exit.
    @MainActor
    private func runAlignGridScript(base: String) async {
        NSApp.activate(ignoringOtherApps: true)
        // A roomy, on-screen window so the fitted page + the open inspector are both clearly
        // visible in the capture (fix B review).
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) && ($0.contentView?.bounds.height ?? 0) > 200 }) {
            window.setContentSize(NSSize(width: 1500, height: 950))
            window.makeKeyAndOrderFront(nil)
        }
        controller.fit()
        try? await Task.sleep(for: .milliseconds(400))
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("align-grid: begin editing failed"); exit(2) }
        let page = session.editingScene?.pageSizeDevice ?? CGSize(width: 1122, height: 793)
        // Three shapes at uneven positions and sizes.
        let a = session.debugInsertShape(.rect, rectDevice: CGRect(x: page.width * 0.08, y: page.height * 0.22, width: page.width * 0.17, height: page.height * 0.13))
        let b = session.debugInsertShape(.ellipse, rectDevice: CGRect(x: page.width * 0.46, y: page.height * 0.52, width: page.width * 0.17, height: page.height * 0.13))
        let c = session.debugInsertShape(.rect, rectDevice: CGRect(x: page.width * 0.80, y: page.height * 0.34, width: page.width * 0.15, height: page.height * 0.17))
        let ids = Set([a, b, c].compactMap { $0 })
        guard ids.count == 3, let aID = a, let bID = b else { Self.logScript("align-grid: insert failed (\(ids.count))"); exit(3) }
        editorModel.selection.replace(with: ids)
        session.alignSelection(ids, .top)
        session.distributeSelection(ids, .horizontal)
        editorModel.showGrid = true
        EditorDebugLaunch.scrollInspectorToArrange = true   // bring the Arrange buttons into view
        showInspector = true
        session.debugCancelAutosave()
        try? await Task.sleep(for: .milliseconds(350))
        controller.fit()   // re-fit with the inspector open (fix B)
        try? await Task.sleep(for: .milliseconds(1100))
        Self.logScript("align-grid FIT(before): \(MacEditableCanvas.Coordinator.debugActive?.debugFitReport() ?? "no coordinator")")
        if !EditorDebugScreenshot.captureLibraryWindow(to: base + "-a.png") {
            _ = EditorDebugScreenshot.captureLargestWindowOffscreen(to: base + "-a.png")
        }
        let tops = ids.compactMap { id in session.editingScene?.elements.first { $0.id == id }?.selectionBoundsDevice.minY }
        Self.logScript("align-grid: aligned tops=\(tops.map { Int($0) }) grid=\(editorModel.showGrid) inspector=\(showInspector)")

        // (b): a live snapped move drag that shows a smart guide. Disable grid-snap so the
        // element-centre guide wins, then drive the drag and capture mid-drag.
        editorModel.snapToGrid = false
        try? await Task.sleep(for: .milliseconds(200))
        let guideShown = MacEditableCanvas.Coordinator.debugActive?.debugBeginSnappedMoveDrag(moveID: aID, towardID: bID) ?? false
        try? await Task.sleep(for: .milliseconds(900))
        if !EditorDebugScreenshot.captureLibraryWindow(to: base + "-b.png") {
            _ = EditorDebugScreenshot.captureLargestWindowOffscreen(to: base + "-b.png")
        }
        Self.logScript("align-grid: guideShown=\(guideShown)")
        session.debugCancelAutosave()
        try? await Task.sleep(for: .milliseconds(200))
        exit(0)
    }

    /// C5g (audit A1): edit mode → insert a few shapes and a text run → select one element
    /// THROUGH THE ACCESSIBILITY ACTION PATH (the canvas coordinator's Select custom action)
    /// → dump the live accessibility tree (label, value, traits, actions) to `<base>-a11y.txt`
    /// and stderr → screenshot the window → exit. The DEBUG evidence hook for the Mac
    /// edit-mode accessibility baseline.
    @MainActor
    private func runAccessibilityDumpScript(base: String) async {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) && ($0.contentView?.bounds.height ?? 0) > 200 }) {
            window.setContentSize(NSSize(width: 1400, height: 900))
            window.makeKeyAndOrderFront(nil)
        }
        controller.fit()
        try? await Task.sleep(for: .milliseconds(400))
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("a11y-dump: begin editing failed"); exit(2) }
        let page = session.editingScene?.pageSizeDevice ?? CGSize(width: 1122, height: 793)
        let w = page.width * 0.22, h = page.height * 0.16
        _ = session.debugInsertShape(.rect, rectDevice: CGRect(x: page.width * 0.10, y: page.height * 0.14, width: w, height: h))
        _ = session.debugInsertShape(.ellipse, rectDevice: CGRect(x: page.width * 0.60, y: page.height * 0.16, width: w, height: h))
        _ = session.debugInsertText("Quarterly Results", originDevice: CGPoint(x: page.width * 0.12, y: page.height * 0.48))
        let firstID = session.editingScene?.editableElements.first?.id
        session.debugCancelAutosave()
        try? await Task.sleep(for: .milliseconds(400))
        // Select via the ACCESSIBILITY path (the Select custom action), not a direct set.
        if let firstID { _ = MacEditableCanvas.Coordinator.debugActive?.accessibilityPerform(.select, on: firstID) }
        try? await Task.sleep(for: .milliseconds(400))
        let dump = MacEditableCanvas.Coordinator.debugActive?.debugAccessibilityDump() ?? "no coordinator"
        try? dump.write(toFile: base + "-a11y.txt", atomically: true, encoding: .utf8)
        if !EditorDebugScreenshot.captureLibraryWindow(to: base + "-a11y.png") {
            _ = EditorDebugScreenshot.captureLargestWindowOffscreen(to: base + "-a11y.png")
        }
        Self.logScript("mac a11y-dump BEGIN\n\(dump)\nmac a11y-dump END")
        session.debugCancelAutosave()
        try? await Task.sleep(for: .milliseconds(200))
        exit(0)
    }

    /// A small in-process gradient PNG, so the image-insert script needs no external file.
    @MainActor
    private static func debugGradientPNG() -> Data {
        let size = NSSize(width: 240, height: 160)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(starting: .systemBlue, ending: .systemOrange)?.draw(in: NSRect(origin: .zero, size: size), angle: 45)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }

    /// A wavy open freehand line (top-left): too wavy to be a straight line, and no hold, so
    /// it stays a smoothed curve.
    private static func wavyLineStroke() -> [CGPoint] {
        (0 ... 50).map { i in CGPoint(x: 90 + Double(i) * 8, y: 150 + sin(Double(i) * 0.35) * 45) }
    }
    /// A hand-drawn-ish wobbly circle (top-right) that snaps to an ellipse on a hold.
    private static func wobblyCircleStroke() -> [CGPoint] {
        var pts = (0 ... 72).map { i -> CGPoint in
            let a = Double(i) / 72 * 2 * .pi
            return CGPoint(x: 820 + cos(a) * 150 + sin(Double(i) * 0.9) * 4, y: 230 + sin(a) * 150 + cos(Double(i) * 0.9) * 4)
        }
        pts.append(pts[0])
        return pts
    }
    /// A wobbly rectangle (bottom-left) that snaps to a rect on a hold.
    private static func wobblyRectStroke() -> [CGPoint] {
        let corners = [CGPoint(x: 90, y: 430), CGPoint(x: 520, y: 430), CGPoint(x: 520, y: 700), CGPoint(x: 90, y: 700)]
        var pts: [CGPoint] = []
        for edge in 0 ..< 4 {
            let p0 = corners[edge], p1 = corners[(edge + 1) % 4]
            for i in 0 ..< 16 {
                let t = Double(i) / 16
                pts.append(CGPoint(x: p0.x + (p1.x - p0.x) * t + sin(Double(i) * 0.9) * 2.5,
                                   y: p0.y + (p1.y - p0.y) * t + cos(Double(i) * 0.9) * 2.5))
            }
        }
        pts.append(corners[0])
        return pts
    }
    /// A scribble (bottom-right): open and far from any chord, so no hold could snap it; it
    /// stays a curve.
    private static func scribbleStroke() -> [CGPoint] {
        (0 ... 60).map { i in CGPoint(x: 640 + Double(i) * 7, y: 560 + sin(Double(i) * 0.8) * 110) }
    }

    /// `plain`: open the (already edited) temp copy read-only → screenshot (b) → log the
    /// re-parse result (the plain viewer loads through MetafileLoader → EMFParse) → exit.
    @MainActor
    private func runPlainScript(base: String) async {
        NSApp.activate(ignoringOtherApps: true)
        controller.fit()
        try? await Task.sleep(for: .milliseconds(900))
        _ = EditorDebugScreenshot.captureLibraryWindow(to: base + "-b-plain.png")
        if let loaded = session.loaded {
            Self.logScript("plain: reparsed OK recordKinds=\(loaded.prepared.recordKinds.count) displaySize=\(loaded.displaySize)")
        } else {
            Self.logScript("plain: FAILED to re-parse saved file")
        }
        try? await Task.sleep(for: .milliseconds(200))
        exit(session.loaded == nil ? 4 : 0)
    }

    /// `close-dirty`: edit mode → move the first element → force the next save to fail →
    /// trigger the real user window-close (performClose) → screenshot the close sheet (c)
    /// → exit. Nothing is written (the injected failure blocks it).
    @MainActor
    private func runCloseDirtyScript(base: String) async {
        NSApp.activate(ignoringOtherApps: true)
        controller.fit()
        try? await Task.sleep(for: .milliseconds(400))
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("close-dirty: begin editing failed"); exit(2) }
        let ids = session.firstEditableIDs(1)
        editorModel.selection.replace(with: ids)
        session.debugTranslate(ids: ids, dx: 40, dy: 30)
        session.debugInjectWriteFailure = true   // the flush on close will fail → sheet shows
        try? await Task.sleep(for: .milliseconds(400))
        Self.logScript("close-dirty: dirty=\(session.isDirty) undoTitle=\(Self.editMenuUndoTitle() ?? "<none>")")
        if let window = Self.scriptWindow() { window.performClose(nil) }
        // Let the flush fail and the sheet fully slide in and lay out before capturing.
        try? await Task.sleep(for: .milliseconds(3000))
        _ = EditorDebugScreenshot.captureAllWindows(to: base + "-c-close-sheet.png")
        _ = EditorDebugScreenshot.captureAttachedSheet(to: base + "-c2-close-alert.png")
        try? await Task.sleep(for: .milliseconds(200))
        session.debugCancelAutosave()
        exit(0)
    }

    /// The on-disk path the current session reads and writes, by resolving the recents
    /// entry's bookmark — used to point the `plain` relaunch at exactly what `edit-save`
    /// persisted (the unsandboxed import copy).
    @MainActor
    private func resolvedEntryPath() -> String? {
        guard let entry = store.entry(id: session.entryID) else { return nil }
        var stale = false
        return (try? URL(
            resolvingBookmarkData: entry.bookmark,
            options: RecentsStore.bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ))?.path
    }

    /// The host library window (largest visible non-panel), for `performClose`.
    @MainActor
    private static func scriptWindow() -> NSWindow? {
        NSApp.windows
            .filter { $0.isVisible && !($0 is NSPanel) && ($0.contentView?.bounds.height ?? 0) > 200 }
            .max { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }
    }

    /// The Edit ▸ Undo menu item title, as textual proof of the current undo action name
    /// (gate screenshot (d)): e.g. "Undo Change Fill" when wired. `nil` when no Edit menu.
    @MainActor
    private static func editMenuUndoTitle() -> String? {
        guard let editMenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Edit" || $0.title == "Edit" })?.submenu
        else { return nil }
        let item = editMenu.items.first { $0.action == Selector(("undo:")) || $0.title.hasPrefix("Undo") }
        return item?.title
    }

    private static func logScript(_ message: String) {
        FileHandle.standardError.write(Data("EMFY-E2D \(message)\n".utf8))
    }
    #endif

    /// The single top overlay stack (audit L-B): the find bar and the external-change
    /// banner, so they never overlap, wrapped in a `GlassEffectContainer` on 26 so the two
    /// glass surfaces merge cleanly; a plain stack below (G2). (The Mac has no zoom pill or
    /// partial-support banner overlay — those appear in the toolbar / Info inspector.)
    @ViewBuilder
    private var topOverlays: some View {
        let content = VStack(spacing: 8) {
            if findModel.isPresented {
                MacFindBar(model: findModel) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { findModel.dismiss() }
                }
                .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
            }
            if session.showsExternalChangeBanner {
                externalChangeBanner
                    .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 10)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: findModel.isPresented)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: session.showsExternalChangeBanner)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { content }
        } else {
            content
        }
    }

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
        .floatingSurface(in: RoundedRectangle(cornerRadius: 10))   // C5e G2
        // Shadow only pre-26 — glass casts its own (audit G-B). Outer margin dropped: the
        // shared top overlay stack now positions this banner (L-B).
        .floatingShadow(radius: 4, y: 2)
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
                options: settings.renderOptions,
                findHighlights: findHighlightSet
            )
            .ignoresSafeArea()
            .overlay(alignment: .bottom) { MacRotationReadoutLeaf(editorModel: editorModel) }
        } else {
            readOnlyContent
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
            if showsReplayCanvas {
                MacRecordReplayView(
                    image: replayDriver.image,
                    pixelSize: replayDriver.pixelSize,
                    deviceBounds: replayDriver.deviceBounds,
                    outlineDeviceRect: replayDriver.outlineDeviceRect,
                    contentToken: replayDriver.contentToken,
                    onArrowStep: { forward, option in
                        if option { recordModel.jumpDrawing(forward: forward) } else { recordModel.step(by: forward ? 1 : -1) }
                    }
                )
                .ignoresSafeArea()
            } else {
            MacMetafileScrollView(
                prepared: model.prepared,
                naturalSize: model.displaySize,
                drawingLabel: canvasAccessibilityLabel,
                controller: controller,
                defaultZoom: settings.defaultZoomOnOpen,
                pageShadow: settings.pageShadow,
                tilePaint: ViewerTilePaint.make(
                    background: settings.pageBackground,
                    darkMode: settings.darkPageMode,
                    isDark: colorScheme == .dark
                ),
                scrollAction: settings.macScrollAction,
                options: settings.renderOptions,
                findHighlights: findHighlightSet
            )
            .ignoresSafeArea()
            // Rebuild the tiled view only when the content actually changes, so a
            // changed-content reload shows the new drawing while an identical reload
            // keeps the same view and its zoom (C4a M4). The identity also tracks the
            // prepared's size and its WMF embedded-EMF choice, so toggling that option
            // (option 4) rebuilds with the new content, while the render-time options
            // redraw the existing tiles (S1b).
            .id(ViewerContentID(model: model, content: session.loadedContentID))
            }
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
        // In edit mode the segmented Format | Layers | Info panel replaces Info (E2c design
        // call 1; Layers added E3d). It shows even with no selection so the Layers tab is
        // always reachable; Format then reads "No Selection".
        if session.editing == .editing, loaded != nil, entry != nil {
            EditorInspectorPanel(session: session, editorModel: editorModel, onClose: { showInspector = false }) {
                infoView
            }
        } else if let loaded, entry != nil {
            // Read-only viewing: the Info | Records segment (F5c).
            ViewerInspectorPanel(
                tab: $viewerInspectorTab,
                model: recordModel,
                summaries: replayDriver.summaries,
                diagnostics: loaded.diagnostics,
                onClose: { showInspector = false },
                checkModel: checkModel,
                summariseModel: summariseModel,
                onExportReport: exportCheckReport,
                askModel: aiInputs != nil ? askModel : nil,
                aiInputs: aiInputs
            ) {
                infoView
            }
        } else {
            infoView
        }
    }

    /// Whether the dedicated step-through replay canvas replaces the live tiled viewer:
    /// the Records segment is active in read-only viewing and this drawing supports
    /// per-record stepping (an EMF+ drawing / WMF keeps the live viewer).
    private var showsReplayCanvas: Bool {
        showInspector && viewerInspectorTab == .records
            && session.editing != .editing && recordModel.supportsPartial
    }

    /// Populates the Records model for the loaded drawing: the step-through engine for
    /// an EMF (off-main via the driver), or a list-only load for a WMF program.
    /// A change in this key re-runs `configureRecordsIfNeeded` (content, inspector
    /// visibility, the active segment, or edit mode changed).
    private var recordsConfigKey: String {
        "\(session.loadedContentID)·\(showInspector)·\(viewerInspectorTab == .records)·\(session.editing == .editing)"
    }

    private func configureRecordsIfNeeded() {
        guard showInspector, viewerInspectorTab == .records else { return }
        guard let loaded, session.editing != .editing else { return }
        let contentID = session.loadedContentID
        if loaded.prepared.kind == .wmfRecords {
            // WMF has no step-through, but its records carry parameter summaries (P3):
            // populate them before setContent so the first row render shows them.
            replayDriver.setSummaries(from: loaded.prepared)
            recordModel.setContent(
                refs: loaded.prepared.recordRefs(), drawingIndices: [],
                supportsPartial: false, isEMF: false, contentID: contentID
            )
        } else {
            replayDriver.configure(
                prepared: loaded.prepared, options: settings.renderOptions,
                scale: 2, contentID: contentID, model: recordModel
            )
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
                onExport: { format in export(format) },
                // On-device Describe (A1a) — only when AI is available.
                aiInputs: aiInputs,
                describeModel: aiInputs != nil ? describeModel : nil,
                altTextStore: aiInputs != nil ? altTextStore : nil
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
            if session.editing == .editing {
                ToolbarItem { shapesMenu }
                ToolbarItem { penMenu }
                ToolbarItem { textButton }
                ToolbarItem { imageButton }
            }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                zoomOutButton
                MacZoomPercentLabel(controller: controller)
                zoomInButton
            }
            ToolbarSpacer(.fixed)
            ToolbarItem { fitButton }
            ToolbarSpacer(.fixed)
            if session.editing != .editing { ToolbarItem { dragHandle } }
            ToolbarItem { shareMenu }
            ToolbarItem { infoButton }
        } else {
            // Pre-26 has no ToolbarSpacer: one group keeps the stated order.
            ToolbarItemGroup {
                editButton
                if session.editing == .editing {
                    shapesMenu
                    penMenu
                    textButton
                    imageButton
                }
                zoomOutButton
                MacZoomPercentLabel(controller: controller)
                zoomInButton
                fitButton
                if session.editing != .editing { dragHandle }
                shareMenu
                infoButton
            }
        }
    }

    /// The document-proxy drag handle (F1 design call 3), shown in viewer mode. Dragging
    /// it provides the whole drawing as a PDF file promise + PNG, plus the original EMF
    /// when it cleanly applies. Chosen over an ⌥-drag on the canvas, which already owns
    /// pan/magnify/element-drag gestures.
    private var dragHandle: some View {
        Image(systemName: "square.and.arrow.up.on.square")
            .foregroundStyle(loaded == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            .onDrag { makeDragProvider() }
            .help("Drag out as PDF or PNG")
            .accessibilityLabel("Drag Out")
            .allowsHitTesting(loaded != nil)
    }

    /// Builds the drag item provider for the current drawing (F1 design call 3).
    private func makeDragProvider() -> NSItemProvider {
        guard let loaded, let entry else { return NSItemProvider() }
        let background: RenderBackground = settings.pngBackground == .transparent ? .transparent : .white
        return MacDrawingDrag.itemProvider(
            prepared: loaded.prepared, baseName: entry.baseName,
            pngScale: settings.defaultPNGScale.multiplier, background: background,
            options: settings.renderOptions, bookmark: entry.bookmark,
            originalIsEMF: entry.formatLabel.uppercased() == "EMF")
    }

    /// The Shapes menu (E3a design call 5), present only in edit mode. Choosing a
    /// shape arms the creation tool; the canvas then shows a crosshair and a drag (or
    /// a click) draws it. A tint marks the armed state.
    private var shapesMenu: some View {
        Menu {
            ForEach(ShapeToolKind.allCases) { kind in
                Button {
                    editorModel.armShape(kind)
                } label: {
                    Label(kind.title, systemImage: kind.systemImage)
                }
            }
        } label: {
            Label("Shapes", systemImage: "square.on.circle")
        }
        .help("Shapes")
        .symbolVariant(editorModel.armedShapeTool != nil ? .fill : .none)
        .foregroundStyle(editorModel.armedShapeTool != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }

    /// The Pen tool (E3b design call 1/3), present only in edit mode. Tapping the button
    /// arms/disarms the pen (it STAYS armed until Esc or re-tap, unlike Shapes); the
    /// menu offers the 6 colours and 3 widths, which persist on `EditorModel`. A tint
    /// marks the armed state.
    private var penMenu: some View {
        Menu {
            Section("Colour") {
                ForEach(PenPalette.colors.indices, id: \.self) { i in
                    let swatch = PenPalette.colors[i]
                    Button {
                        editorModel.penStyle.color = swatch.color
                    } label: {
                        Label {
                            Text(swatch.name)
                        } icon: {
                            Image(systemName: editorModel.penStyle.color == swatch.color ? "checkmark.circle.fill" : "circle.fill")
                                .foregroundStyle(swatch.color.swiftUIColor)
                        }
                    }
                }
            }
            Section("Width") {
                ForEach(PenPalette.widths, id: \.self) { width in
                    Button {
                        editorModel.penStyle.widthPoints = width
                    } label: {
                        Label("\(Int(width)) pt", systemImage: editorModel.penStyle.widthPoints == width ? "checkmark" : "pencil.tip")
                    }
                }
            }
        } label: {
            Label("Pen", systemImage: "pencil.tip")
        } primaryAction: {
            if editorModel.armedPen { editorModel.armedPen = false } else { editorModel.armPen() }
        }
        .help("Pen")
        .symbolVariant(editorModel.armedPen ? .fill : .none)
        .foregroundStyle(editorModel.armedPen ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }

    /// The Text tool (E3c design call 1), present only in edit mode. Tapping it arms the
    /// tool; the next canvas click inserts a text element and opens its popover, then the
    /// tool disarms (Keynote). A tint marks the armed state.
    private var textButton: some View {
        Button {
            if editorModel.armedTextTool { editorModel.disarmTools() } else { editorModel.armText() }
        } label: {
            Label("Text", systemImage: "textformat")
        }
        .help("Text")
        .symbolVariant(editorModel.armedTextTool ? .fill : .none)
        .foregroundStyle(editorModel.armedTextTool ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }

    /// The Insert Image button (E3c design call 2), present only in edit mode: it opens
    /// an images-only NSOpenPanel and inserts the chosen image centred on the page.
    private var imageButton: some View {
        Button {
            presentImagePanel()
        } label: {
            Label("Image", systemImage: "photo")
        }
        .help("Insert Image…")
    }

    /// Opens an images-only open panel and inserts the chosen file centred on the page
    /// (one undo), selecting the new image; a decode/cap failure toasts (design call 2).
    /// Arming an image insert disarms the other creation tools (single armed tool).
    private func presentImagePanel() {
        guard session.editing == .editing else { return }
        editorModel.disarmTools()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Insert"
        panel.message = "Choose an image to insert"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { insertImage(from: url) }
        }
    }

    /// Reads `url`'s bytes (security-scoped) and inserts them through the session's
    /// capped, metadata-stripping image path, selecting the new element.
    private func insertImage(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        guard let data else {
            toast.show("This image couldn’t be added", systemImage: "photo.badge.exclamationmark")
            return
        }
        // The decode/re-encode happens off the main thread inside insertImage (P7).
        Task { @MainActor in
            if let id = await session.insertImage(data: data) {
                editorModel.selection.replace(with: id)
            } else {
                toast.show("This image couldn’t be added", systemImage: "photo.badge.exclamationmark")
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
            editorModel.disarmTools()
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
            Divider()
            // Send to AI… (A3b): packages a PNG + a text summary for an AI app the user
            // already has, through the system share sheet. Emfy sends nothing itself.
            Button {
                aiShareIncludeOriginal = false
                showAIShareConfirm = true
            } label: {
                Label(AISharePackage.menuTitle, systemImage: "sparkles")
            }
            .accessibilityIdentifier("sendToAI")
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
        .background {
            MacAISharePresenter(payload: exporter.aiSharePayload)
                .allowsHitTesting(false)
        }
        .sheet(isPresented: $showAIShareConfirm) {
            AIShareConfirmSheet(includeOriginal: $aiShareIncludeOriginal) {
                showAIShareConfirm = false
                sendToAI(includeOriginal: aiShareIncludeOriginal)
            } onCancel: {
                showAIShareConfirm = false
            }
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

    /// Send to AI… (A3b): packages the whole drawing (the edited scene when diverged,
    /// else the original) as a PNG + text summary and hands it to the system share sheet.
    /// `includeOriginal` attaches the original file too (the pre-sheet toggle, default off).
    private func sendToAI(includeOriginal: Bool) {
        guard let loaded, let entry else { return }
        let opts = ExportScale.pngOptions(for: loaded.prepared.naturalSize, settings: settings)
        let source = AISharePackage.outputSource(
            isEditing: session.editing == .editing, hasDiverged: session.hasDivergedFromOpened)
        let recordCount = loaded.prepared.recordKinds.reduce(0) { $0 + $1.count }
        exporter.sendToAI(
            entry: entry, store: store, source: source,
            prepared: loaded.prepared, editedScene: session.editedScene,
            allText: findModel.copyAllText(), recordCount: recordCount,
            background: opts.background, options: settings.renderOptions,
            includeOriginal: includeOriginal)
    }

    /// File ▸ Print… (⌘P), F1. Prints the whole drawing as vector — the edited scene
    /// when editing has diverged, else the original — through the same renderer the PDF
    /// export uses, with the Scale accessory and auto orientation.
    private func printDocument() {
        guard let loaded, let entry else { return }
        let source = OutputSource.wholeDrawing(
            isEditing: session.editing == .editing, hasDiverged: session.hasDivergedFromOpened)
        guard let pdf = MacPrint.makePDFData(
            source: source, prepared: loaded.prepared,
            editedScene: session.editedScene, options: settings.renderOptions) else { return }
        MacPrint.present(
            pdfData: pdf, naturalSize: loaded.prepared.naturalSize,
            jobName: entry.displayName, window: NSApp.keyWindow)
    }

    /// Edit ▸ Copy (⌘C), F1. Driven through the responder chain by `.onCopyCommand`, so
    /// it uses the one system Copy item and yields to a focused text field. Copies the
    /// drawing (or, in edit mode, the selection) as vector PDF + PNG, plus the original
    /// EMF when it cleanly applies. Returns `[]` with no document, so Copy stays inert.
    private func copyItemProviders() -> [NSItemProvider] {
        guard let loaded, let entry else { return [] }
        return MacDrawingCopy.itemProviders(
            session: session, prepared: loaded.prepared, entry: entry,
            settings: settings, selection: editorModel.selection.ids)
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

    // MARK: - Find (F3b)

    /// The page bounds (device) and natural size the current mode draws with: the edited
    /// scene in edit mode, the prepared model in viewer mode. `nil` when nothing is shown.
    private var findPageGeometry: (pageBoundsDevice: CGRect, naturalSize: CGSize)? {
        if session.editing == .editing, let scene = session.editedScene {
            return (scene.pageBoundsDevice, scene.pageSizeDevice)
        }
        if let loaded {
            return (loaded.prepared.deviceBounds, loaded.displaySize)
        }
        return nil
    }

    /// The find highlights for the current matches, in device space, handed to the overlays.
    /// The Check segment's selected-finding outline takes precedence while it is showing, so
    /// selecting a finding outlines its elements on the canvas (X1a).
    private var findHighlightSet: FindHighlightSet {
        if showInspector, viewerInspectorTab == .check {
            let checkHighlight = checkModel.highlight
            if !checkHighlight.isEmpty { return checkHighlight }
        }
        guard findModel.isPresented, !findModel.matches.isEmpty, let geometry = findPageGeometry else {
            return .empty
        }
        return FindHighlightSet(
            pageBoundsDevice: geometry.pageBoundsDevice,
            matchDeviceRects: FindHighlightGeometry.distinctDeviceRects(findModel.matches),
            currentDeviceRect: FindHighlightGeometry.matchDeviceRect(findModel.matches, current: findModel.current)
        )
    }

    /// Changes whenever the drawing the find model should search over changes: the edit
    /// state and the loaded content id, plus — only while the find bar is OPEN — the edit
    /// version. A closed bar therefore does not re-extract text on every edit (P13); the
    /// bar re-keys and extracts lazily on open, and tracks edits while open.
    private var findRunsKey: String {
        let version = findModel.isPresented ? session.editVersion : 0
        return "\(findModel.isPresented)-\(session.editing == .editing)-\(version)-\(session.loadedContentID)"
    }

    /// Recomputes the find model's runs for the current drawing (F3b): the edited scene in
    /// edit mode, the renderer observation in viewer mode — BOTH off the main actor (P13), so
    /// a large drawing's text extraction never blocks an edit or a load. Embedded-picture
    /// enumeration (and the Vision OCR pass it feeds) runs only while the find bar is open,
    /// since its results only ever surface in find; it is skipped entirely for a closed bar.
    private func refreshFindRuns() async {
        let contentID = findRunsKey.hashValue
        let wantOCR = settings.recognizeTextInPictures && findModel.isPresented
        if session.editing == .editing, let scene = session.editedScene {
            let (runs, pictures) = await Task.detached(priority: .userInitiated) {
                (DrawingTextExtractor.extract(from: scene),
                 wantOCR ? DrawingPictureEnumerator.pictures(from: scene) : [])
            }.value
            findModel.setRuns(runs, contentID: contentID)
            startPictureOCR(pictures, contentID: contentID)
            return
        }
        guard let loaded else {
            findModel.setRuns([], contentID: contentID)
            return
        }
        let prepared = loaded.prepared
        let options = settings.renderOptions
        let (runs, pictures) = await Task.detached(priority: .userInitiated) {
            let observation = MetafileRenderer.observe(prepared, options: options)
            let runs = DrawingTextExtractor.extract(from: observation)
            let pictures = wantOCR ? DrawingPictureEnumerator.pictures(from: observation) : []
            return (runs, pictures)
        }.value
        findModel.setRuns(runs, contentID: contentID)
        startPictureOCR(pictures, contentID: contentID)
    }

    /// Kicks off the embedded-picture OCR pass for the current drawing (F3c). Drawing text is
    /// already searchable; the recognised picture text merges into the matches when it
    /// completes, off the main actor, so the UI never blocks. No pictures (or OCR disabled) →
    /// nothing to do.
    private func startPictureOCR(_ pictures: [EmbeddedPicture], contentID: Int) {
        guard !pictures.isEmpty else { return }
        findModel.beginReadingPictures()
        Task {
            let runs = await DrawingOCRService.shared.recognize(pictures: pictures)
            findModel.setPictureRuns(runs, contentID: contentID)
        }
    }

    /// Scrolls the current match into view through the active scroll view (F3b).
    private func scrollToCurrentMatch() {
        guard let rect = FindHighlightGeometry.matchDeviceRect(findModel.matches, current: findModel.current),
              let geometry = findPageGeometry else { return }
        controller.scrollDeviceRectToVisible(rect, pageBoundsDevice: geometry.pageBoundsDevice, naturalSize: geometry.naturalSize)
    }

    /// Opens the find bar (⌘F); a second ⌘F re-focuses the field rather than closing.
    private func presentFind() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { findModel.present() }
    }

    /// Copies the drawing's text (reading order, plain text) to the pasteboard (F3b).
    private func copyAllText() {
        let text = findModel.copyAllText()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toast.show("Copied all text", systemImage: "doc.on.doc")
    }

    // MARK: - Translate (F3d)

    /// The text handed to the Translate overlay: the current Find match's run text when one
    /// exists, else the drawing's text in Copy All Text order, truncated at a word boundary.
    private var translationText: String {
        DrawingTranslation.text(currentMatch: findModel.currentMatchRunText, allText: findModel.copyAllText())
    }

    /// Whether Translate is offered: macOS 14.4+, a document is shown, and it has text (F3d).
    private var translateEnabled: Bool {
        guard loaded != nil, findModel.hasText else { return false }
        if #available(macOS 14.4, *) { return true } else { return false }
    }

    /// The Translate… item shared by the Edit menu (via `translate`) and the viewer context
    /// menu. Hidden below macOS 14.4; disabled when no document/text is shown.
    @ViewBuilder
    private var translateMenuItem: some View {
        if #available(macOS 14.4, *) {
            Button {
                showTranslation = true
            } label: {
                Label("Translate…", systemImage: "translate")
            }
            .disabled(loaded == nil || !findModel.hasText)
        }
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
            sendToAI: loaded != nil ? { aiShareIncludeOriginal = false; showAIShareConfirm = true } : nil,
            copyDiagnosticReport: loaded != nil ? { copyDiagnosticReport() } : nil,
            printDocument: loaded != nil ? { printDocument() } : nil,
            presentFind: loaded != nil ? { presentFind() } : nil,
            findNext: loaded != nil ? { findModel.present(); findModel.goNext() } : nil,
            findPrevious: loaded != nil ? { findModel.present(); findModel.goPrevious() } : nil,
            copyAllText: findModel.hasText ? { copyAllText() } : nil,
            translate: translateEnabled ? { showTranslation = true } : nil,
            save: (session.editing == .editing && session.isDirty) ? { Task { await session.save() } } : nil,
            revertToOpenedVersion: (session.canRevertToOpenedVersion && settings.keepOpenedVersionForRevert) ? { showRevertConfirm = true } : nil,
            selectAllElements: session.editing == .editing ? { selectAllElements() } : nil,
            deselectElements: (session.editing == .editing && !editorModel.selection.isEmpty) ? { editorModel.selection.clear() } : nil,
            selectNextElement: session.editing == .editing ? { cycleElementSelection(forward: true) } : nil,
            selectPreviousElement: session.editing == .editing ? { cycleElementSelection(forward: false) } : nil,
            deleteSelection: (session.editing == .editing && !editorModel.selection.isEmpty) ? { session.deleteSelection(editorModel.selection.ids) } : nil,
            insertImage: session.editing == .editing ? { presentImagePanel() } : nil,
            bringToFront: arrangeEnabled ? { session.bringSelectionToFront(editorModel.selection.ids) } : nil,
            bringForward: arrangeEnabled ? { session.bringSelectionForward(editorModel.selection.ids) } : nil,
            sendBackward: arrangeEnabled ? { session.sendSelectionBackward(editorModel.selection.ids) } : nil,
            sendToBack: arrangeEnabled ? { session.sendSelectionToBack(editorModel.selection.ids) } : nil,
            alignSelection: arrangeEnabled ? { session.alignSelection(editorModel.selection.ids, $0) } : nil,
            distributeSelection: arrangeEnabled ? { session.distributeSelection(editorModel.selection.ids, $0) } : nil,
            canDistribute: editorModel.selection.ids.count >= 3,
            editWithAI: (session.editing == .editing && aiEnabled) ? { startEditorAIEdit() } : nil,
            recolour: session.editing == .editing ? { startEditorRecolour() } : nil,
            translateDrawing: (session.editing == .editing && aiEnabled) ? { startEditorTranslate() } : nil,
            toggleGrid: session.editing == .editing ? { editorModel.showGrid.toggle() } : nil,
            toggleSnapToGrid: session.editing == .editing ? { editorModel.snapToGrid.toggle() } : nil,
            toggleSnapToGuides: session.editing == .editing ? { editorModel.snapToGuides.toggle() } : nil,
            isGridShown: editorModel.showGrid,
            isSnapToGrid: editorModel.snapToGrid,
            isSnapToGuides: editorModel.snapToGuides
        )
    }

    /// Opens "Edit with AI…", scoped to the current selection (X2a).
    private func startEditorAIEdit() {
        aiEditModel.reset()
        aiEditModel.configure(session: session, scope: editorModel.selection.ids)
        aiEditModel.providerStore = aiProviders
        showingAIEditSheet = true
    }

    /// Opens "Recolour…", scoped to the current selection (X2a).
    private func startEditorRecolour() {
        showingRecolourSheet = true
        Task { await recolourModel.start(session: session, selection: editorModel.selection.ids) }
    }

    /// Opens "Translate…", scoped to the selected text runs, else all text (X2c).
    private func startEditorTranslate() {
        translateModel.providerStore = aiProviders
        showingTranslateSheet = true
        Task { await translateModel.prepare(session: session, selection: editorModel.selection.ids) }
    }

    /// Arrange is enabled only in edit mode with a non-empty selection (E3d).
    private var arrangeEnabled: Bool {
        ArrangeAvailability.isEnabled(editing: session.editing == .editing, selectionCount: editorModel.selection.ids.count)
    }

    /// ⌘A: select every editable element (design call E2b-4).
    private func selectAllElements() {
        editorModel.selection.replace(with: session.allEditableIDs())
    }

    /// ⌥Tab / ⌥⇧Tab (Edit ▸ Select Next/Previous Element): cycle the selection through the
    /// unlocked elements in reading order — keyboard accessibility (C5g / audit A1).
    private func cycleElementSelection(forward: Bool) {
        guard let scene = session.editingScene,
              let id = EditorAccessibility.cycleSelection(from: editorModel.selection.ids, forward: forward, in: scene) else { return }
        editorModel.selection.replace(with: id)
    }

    private var entry: RecentEntry? {
        store.entry(id: session.entryID)
    }

    // MARK: - On-device AI (A1a)

    /// Whether on-device AI is available and switched on.
    private var onDeviceReady: Bool {
        settings.useOnDeviceAI && DrawingAIAvailability.current().isAvailable
    }

    /// Whether the AI surface (Describe, Ask, Explain, alt text) appears: when the
    /// on-device engine is ready OR a provider is configured (A2b). Alt text stays an
    /// on-device-only feature.
    private var aiEnabled: Bool {
        guard let aiProviders else { return onDeviceReady }
        return aiProviders.shouldShowAISurface(onDeviceAvailable: onDeviceReady)
    }

    /// The AI inputs for this drawing, or `nil` when AI is off or there's nothing to
    /// describe. Read-only viewing only (edit mode has its own inspector).
    private var aiInputs: DrawingAIInspectorInputs? {
        guard aiEnabled, session.editing != .editing, let loaded, let entry else { return nil }
        let store = self.store
        return DrawingAIInspectorInputs(
            contentID: session.loadedContentID,
            fileName: entry.displayName,
            unsupportedNotes: loaded.couldNotShowNotes.map(\.summary),
            dataProvider: { [weak store] in
                guard let store else { return nil }
                return try? await store.resolveData(for: entry)
            }
        )
    }

    /// The canvas accessibility label: on-device alt text when it exists, else
    /// "Drawing, <file name>" (A1a).
    private var canvasAccessibilityLabel: String {
        let fallback = "Drawing: \(entry?.baseName ?? "Metafile")"
        guard onDeviceReady else { return fallback }
        return altTextStore.label(for: session.loadedContentID, fileName: entry?.displayName ?? "")
    }

    /// Resets the AI models when the open drawing changes, and seeds alt text when
    /// VoiceOver is running (A1a).
    private func configureAIForCurrentDrawing() {
        askModel.providerStore = aiProviders
        describeModel.providerStore = aiProviders
        describeModel.resetIfDrawingChanged(contentID: session.loadedContentID)
        guard let inputs = aiInputs else { return }
        askModel.prepare(
            contentID: inputs.contentID,
            dataProvider: inputs.dataProvider,
            fileName: inputs.fileName,
            unsupportedNotes: inputs.unsupportedNotes
        )
        if NSWorkspace.shared.isVoiceOverEnabled {
            altTextStore.generateIfNeeded(
                contentID: inputs.contentID,
                dataProvider: inputs.dataProvider,
                fileName: inputs.fileName,
                unsupportedNotes: inputs.unsupportedNotes
            )
        }
    }

    // MARK: - Accessibility Check (X1a)

    /// Re-runs the Check analysis when the drawing, the edit, the inspector visibility or
    /// the active segment changes.
    private var checkConfigKey: String {
        "\(session.loadedContentID)·\(session.editVersion)·\(session.editing == .editing)·\(showInspector)·\(viewerInspectorTab == .check)"
    }

    /// The drawing's bytes on demand (independent of AI, so Check works with AI off).
    private var checkDataProvider: (@Sendable () async -> Data?)? {
        guard let entry else { return nil }
        let store = self.store
        return { [weak store] in
            guard let store else { return nil }
            return try? await store.resolveData(for: entry)
        }
    }

    private func configureCheckIfNeeded() {
        guard showInspector, viewerInspectorTab == .check, entry != nil else { return }
        guard let dataProvider = checkDataProvider else { return }
        summariseModel.providerStore = aiProviders
        checkModel.configure(session: session, dataProvider: dataProvider, contentID: session.loadedContentID)
        checkModel.refreshIfNeeded()
        summariseModel.resetIfChanged(key: checkModel.analysisVersion)
    }

    /// Saves the Markdown accessibility report, "<name> accessibility report.md" (X1a §4).
    private func exportCheckReport() {
        guard let markdown = checkModel.markdownReport(title: reportTitle) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(entry?.baseName ?? "Drawing") accessibility report.md"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(markdown.utf8).write(to: url)
                toast.show("Saved report", systemImage: "square.and.arrow.down", actionTitle: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                exporter.errorMessage = error.localizedDescription
            }
        }
    }

    private var reportTitle: String { "\(entry?.baseName ?? "Drawing") — accessibility report" }

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

// MARK: - Window-close prompt (E2d)

/// Installs an `NSWindowDelegate` on the library window so the user's window close (the
/// red button, ⌘W, or File ▸ Close) flushes and, if needed, confirms unsaved edits
/// before the window closes — the window-level equivalent of the quit prompt (E2d). A
/// clean window closes immediately. Zero-size and non-drawing; it only observes the
/// window. Any pre-existing delegate (SwiftUI's) is preserved by forwarding every method
/// this proxy does not implement.
private struct WindowCloseGuard: NSViewRepresentable {
    let session: DocumentSession
    let documentName: String

    func makeNSView(context: Context) -> NSView {
        let view = GuardView()
        view.session = session
        view.documentName = documentName
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? GuardView else { return }
        view.session = session
        view.documentName = documentName
    }

    private final class GuardView: NSView {
        var session: DocumentSession?
        var documentName: String = "this file"
        private weak var guardedWindow: NSWindow?
        private var proxy: CloseDelegateProxy?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== guardedWindow else { return }
            let proxy = CloseDelegateProxy(
                previous: window.delegate,
                session: { [weak self] in self?.session },
                name: { [weak self] in self?.documentName ?? "this file" }
            )
            window.delegate = proxy
            self.proxy = proxy
            guardedWindow = window
        }
    }
}

/// The window delegate that runs the unsaved-changes close flow (E2d). It forwards every
/// `NSWindowDelegate` message it does not implement to the previous delegate, so SwiftUI's
/// own window behaviour is preserved. `windowShouldClose` defers the real decision to an
/// async flow and returns `false`; the flow closes the window itself once it decides to.
private final class CloseDelegateProxy: NSObject, NSWindowDelegate {
    private let previous: NSWindowDelegate?
    private let session: () -> DocumentSession?
    private let name: () -> String
    private var isClosing = false

    init(previous: NSWindowDelegate?, session: @escaping () -> DocumentSession?, name: @escaping () -> String) {
        self.previous = previous
        self.session = session
        self.name = name
    }

    // Preserve the previous delegate: claim to respond to its selectors, and forward
    // any message this proxy does not itself implement (the runtime consults
    // `forwardingTarget(for:)` only for selectors without an own implementation, so
    // `windowShouldClose` always runs here).
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (previous?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if previous?.responds(to: aSelector) == true { return previous }
        return super.forwardingTarget(for: aSelector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isClosing { return true }
        guard let session = session() else { return true }   // no editing session: close
        let name = name()
        Task { @MainActor in
            await self.runCloseFlow(window: sender, session: session, name: name)
        }
        return false
    }

    /// Routes Edit ▸ Undo/Redo and ⌘Z/⇧⌘Z to the shown session's `SceneHistory` by making
    /// its `UndoManager` the window's, so the menu titles read "Undo Change Fill" etc. and
    /// invoking them reverses the scene edit (E2d). While a text field / field editor is
    /// first responder it returns nil, so the field keeps its own field-editor undo; with
    /// no session it returns nil (the window's default manager applies).
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if window.firstResponder is NSText { return nil }
        return session()?.undoManager
    }

    @MainActor
    private func runCloseFlow(window: NSWindow, session: DocumentSession, name: String) async {
        await session.flushPendingSave()
        // Snapshot the post-flush state before any SwiftUI observer (the error toast)
        // can clear it; `stillDirty` is the reliable trigger either way.
        let needsPrompt = WindowCloseDecision.needsPromptAfterFlush(
            saveFailed: session.lastSaveError != nil,
            wmfPending: session.pendingWMFConfirmation != nil,
            stillDirty: session.isDirty
        )
        guard needsPrompt else { close(window); return }

        switch await Self.presentSheet(on: window, name: name) {
        case .cancel:
            break   // keep the window open
        case .dontSave:
            session.discardEditsAndStopEditing()
            close(window)
        case .save:
            await session.save()
            let still = WindowCloseDecision.needsPromptAfterFlush(
                saveFailed: session.lastSaveError != nil,
                wmfPending: session.pendingWMFConfirmation != nil,
                stillDirty: session.isDirty
            )
            // A clean save closes; a pending WMF confirmation or a failed save keeps the
            // window open, where the existing SwiftUI dialog / error toast takes over.
            if WindowCloseDecision.outcome(choice: .save, stillNeedsPromptAfterSave: still) == .closeNow {
                close(window)
            } else if session.pendingWMFConfirmation != nil {
                // The save raised the WMF limitations dialog instead of writing. Hand off to the
                // SwiftUI dialog and close the window once the user confirms the write (R2U5).
                session.onPendingWMFSaveCommitted = { [weak self] in self?.close(window) }
            }
        }
    }

    @MainActor
    private func close(_ window: NSWindow) {
        isClosing = true
        window.close()
    }

    @MainActor
    private static func presentSheet(on window: NSWindow, name: String) async -> WindowCloseChoice {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Save changes to “\(name)” before closing?"
            alert.informativeText = "Your changes will be lost if you don’t save them."
            alert.addButton(withTitle: "Save…")
            alert.addButton(withTitle: "Don’t Save")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                let choice: WindowCloseChoice
                switch response {
                case .alertFirstButtonReturn: choice = .save
                case .alertSecondButtonReturn: choice = .dontSave
                default: choice = .cancel
                }
                continuation.resume(returning: choice)
            }
        }
    }
}

/// The live rotation-angle readout while a rotation drag is in flight (E2b-6), as a leaf view
/// so updating it each rotation frame invalidates only this text — not `MacViewerPane.body`,
/// which hosts the inspector and publishes `viewerActions` (P2).
private struct MacRotationReadoutLeaf: View {
    let editorModel: EditorModel

    var body: some View {
        if let readout = editorModel.rotationReadout {
            Text(readout)
                .font(.system(.body, design: .rounded).monospacedDigit())
                .padding(.horizontal, 12).padding(.vertical, 6)
                .floatingSurface(in: Capsule())   // C5e G2
                .padding(.bottom, 24)
        }
    }
}
