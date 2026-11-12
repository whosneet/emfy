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
        Self.scriptWindow()?.makeKeyAndOrderFront(nil)
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
        _ = EditorDebugScreenshot.captureLibraryWindow(to: base + "-a-strokes.png")
        await session.save()
        try? await Task.sleep(for: .milliseconds(500))
        session.debugCancelAutosave()
        let kinds = session.editingScene?.editableElements.map { "\($0.kind)" }.joined(separator: ",") ?? "?"
        Self.logScript("pen-strokes: ids=\(id1 ?? -1),\(id2 ?? -1),\(id3 ?? -1),\(id4 ?? -1) kinds=[\(kinds)] savedPath=\(resolvedEntryPath() ?? "?") saveError=\(session.lastSaveError.map { "\($0)" } ?? "nil")")
        try? await Task.sleep(for: .milliseconds(200))
        exit(session.lastSaveError == nil ? 0 : 3)
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
            if session.editing == .editing {
                ToolbarItem { shapesMenu }
                ToolbarItem { penMenu }
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
            ToolbarItem { shareMenu }
            ToolbarItem { infoButton }
        } else {
            // Pre-26 has no ToolbarSpacer: one group keeps the stated order.
            ToolbarItemGroup {
                editButton
                if session.editing == .editing {
                    shapesMenu
                    penMenu
                }
                zoomOutButton
                MacZoomPercentLabel(controller: controller)
                zoomInButton
                fitButton
                shareMenu
                infoButton
            }
        }
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
