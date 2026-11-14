import CoreGraphics
import EMFRender
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @Environment(AIProviderStore.self) private var aiProviders: AIProviderStore?
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
    /// Leaves the document via the compact back control — routed through the window model's
    /// save guard so a dirty edit isn't lost when the system back pops the push (U1).
    let onBack: () -> Void

    @State private var controller = MetafileZoomController()
    @State private var exporter = MetafileExportController()
    @State private var editorModel = EditorModel()
    @State private var findModel = DrawingFindModel()
    #if DEBUG
    @State private var debugLaunchRan = false
    #if DEBUG
    /// F1 screenshot (d): presents the share actions (Print, Copy, …) as a system dialog
    /// for a Simulator capture, since a SwiftUI Menu popover can't be opened without a tap.
    @State private var debugShareDialog = false
    #endif
    #endif

    // Translate (F3d): the system Translate overlay presentation.
    @State private var showTranslation = false

    @State private var chromeHidden = false
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
    @State private var bannerDismissed = false
    @State private var pillVisible = false
    @State private var pillHideTask: Task<Void, Never>?
    // Editing (E2a review #6).
    @State private var showRevertConfirm = false
    @State private var showReloadDiscardConfirm = false
    // Send to AI… (A3b): the confirm sheet and its "Include the original file" toggle (off).
    @State private var showAIShareConfirm = false
    @State private var aiShareIncludeOriginal = false

    // Image insert (E3c): Photos picker + Files importer presentation.
    @State private var photoItem: PhotosPickerItem?
    @State private var photoPickerPresented = false
    @State private var imageImporterPresented = false

    // Light editor (E4): the Colour sheet presentation.
    @State private var showColorSheet = false
    // Editor AI edit + recolour (X2a), selection-scoped.
    @State private var aiEditModel = DrawingAIEditModel()
    @State private var recolourModel = DrawingRecolourModel()
    @State private var translateModel = DrawingAITranslateModel()
    @State private var showingAIEditSheet = false
    @State private var showingRecolourSheet = false
    @State private var showingTranslateSheet = false
    #if DEBUG
    @State private var showDebugSettings = false
    #endif

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

    /// Which editor the viewer presents (E4): full (iPad-style) or light (compact
    /// iPhone). Resolved purely from the size class, the Settings toggle and the device
    /// family (`EditorMode.resolve`), so a live toggle or rotation re-resolves it.
    private var editorMode: EditorMode {
        EditorMode.resolve(
            horizontalSizeClass: horizontalSizeClass,
            fullEditorOnIPhone: settings.fullEditorOnIPhone,
            idiom: Self.deviceIdiom
        )
    }

    /// The device family for the editor-depth decision (design call 1). The one place
    /// the viewer reads the idiom, per §11.1.
    private static var deviceIdiom: EditorDeviceIdiom {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: return .phone
        case .pad: return .pad
        default: return .other
        }
    }

    /// Editing with the full editor (iPad, iPhone Duo, or the toggle on) — the top
    /// toolbars (Shapes, Pen, Text, Image, Grid, Undo/Redo) and the inspector show.
    private var isFullEditing: Bool { session.editing == .editing && editorMode == .full }

    /// Editing with the light editor (compact iPhone) — a bottom toolbar of Markup,
    /// Colour, Text, Delete, Undo and Redo, selection without handles, no inspector.
    private var isLightEditing: Bool { session.editing == .editing && editorMode == .light }

    /// A fixed inspector column width so the drawing can reserve exactly that much
    /// trailing space when the inspector is open (iPad). `.inspector` presents as a
    /// translucent overlay over the detail's trailing edge, not a width-reducing
    /// column, so without this the drawing bleeds under it (item 2).
    private let inspectorWidth: CGFloat = 320

    /// Trailing space to keep clear for the inspector overlay — only at regular width
    /// (iPad) in READ-ONLY viewing, where the overlay sits over the drawing's trailing
    /// edge. In edit mode the editable canvas fills the width and re-fits when the
    /// inspector opens/closes (E2c item 4), so no reserved strip — reserving it there
    /// double-counted the inspector column and left a white gap beside it.
    private var reservedInspectorWidth: CGFloat {
        guard showInspector, isRegularWidth, session.editing != .editing else { return 0 }
        // The overlay inspector that needs a reserved trailing strip is an iPadOS 26+
        // behaviour. On iPadOS 17/18 `.inspector` presents as a width-reducing trailing
        // COLUMN (Apple: "inspector(isPresented:content:)", developer.apple.com — the
        // inspector shows as a distinct trailing section/column), so the detail area already
        // shrinks and reserving extra space would double-count it and leave a white gap
        // (C5e L6). No iOS 17/18 runtime is installed here to screenshot, so this gates on
        // the documented behaviour (verified: only iOS 27.2 runtimes present, 14 Nov 2026).
        guard #available(iOS 26.0, *) else { return 0 }
        return inspectorWidth
    }

    /// The leading inset of the inspector's floating translucent PANEL inside its
    /// `inspectorWidth` column: the panel's material edge sits this far right of the
    /// column's left edge (iPadOS 27 measures ~43 pt). The read-only canvas fits to the
    /// full column but CENTRES up to the panel edge, so this inset's worth of slack is
    /// split into an equal margin on each side of the page (P1 review). A system metric —
    /// re-measure if the OS floating-inspector inset changes.
    private let inspectorPanelLeadingInset: CGFloat = 40

    /// The trailing width the read-only canvas CENTRES against — the inspector panel's
    /// footprint (column minus its floating leading inset). Zero when no strip is reserved.
    private var reservedInspectorCentreWidth: CGFloat {
        let reserved = reservedInspectorWidth
        return reserved > 0 ? max(0, reserved - inspectorPanelLeadingInset) : 0
    }

    var body: some View {
        // The body is split into chained `some View` layers grouped by concern (chrome,
        // find/inspector, sheets, alerts, reactions) so each is a separate, small
        // type-check expression — the whole modifier chain as one expression had reached
        // the Swift type-checker's limit (F3d). The modifier order is unchanged, so this
        // is behaviour-neutral: `reactionsLayer` wraps `alertsLayer` wraps `sheetsLayer`
        // wraps `findLayer` wraps `baseLayer`.
        reactionsLayer
    }

    /// The drawing plus the navigation title, toolbars, status bar and top overlays.
    private var baseLayer: some View {
        ZStack {
            // The canvas background fills the WHOLE viewport, UNDER the inspector overlay
            // too — so the grey never gives way to a white strip beside the page (P1).
            backgroundColor
                .ignoresSafeArea()
            // The drawing fills the full width; the read-only zoomable view fits + centres
            // the page into the region LEFT of the inspector via its own `reservedTrailing`
            // inset (the editable canvas does the same with `trailingInset`). Padding the
            // whole stack (the old code) shrank the grey background with it and left the
            // page pinned top-left and unfitted (P1).
            drawingLayer
        }
        .navigationTitle(entry?.baseName ?? "Metafile")
        .navigationBarTitleDisplayMode(.inline)
        // While editing in the compact push, hide the system Back button and vend a custom
        // one that leaves through the window model's save guard, so the system pop can't
        // tear the edit session down and lose unsaved WMF edits (U1).
        .navigationBarBackButtonHidden(guardsBack)
        .toolbar { backToolbarItem }
        .metafileNavigationSubtitle(subtitle)
        // At regular width (iPad) a long inline title clips at the LEADING edge behind
        // the sidebar boundary; a principal title view truncates at the tail with an
        // ellipsis, like the iPhone title (S1a-5 carry-over c). iPhone keeps the
        // default inline title, which already tail-truncates.
        .toolbar { regularWidthTitle }
        .toolbar { editToolbarItem }
        .toolbar { undoRedoToolbar }
        .toolbar { shapesToolbar }
        .toolbar { bottomBar }
        .toolbar(effectiveChromeHidden ? .hidden : .visible, for: .navigationBar)
        .toolbar(effectiveChromeHidden ? .hidden : .visible, for: .bottomBar)
        .statusBarHidden(effectiveChromeHidden)
        .overlay(alignment: .top) { topOverlays }
    }

    /// The find bar (F3b) and the file-details inspector layered over `baseLayer`.
    private var findLayer: some View {
        baseLayer
        // The find bar + its highlight/scroll plumbing (F3b), collapsed into one modifier so
        // the already-large body stays type-checkable.
        .metafileFindBar(
            model: findModel,
            runsKey: findRunsKey,
            refreshRuns: { await refreshFindRuns() },
            onCurrentChange: { scrollToCurrentMatch() },
            ocrEnabled: settings.recognizeTextInPictures,
            onOCRToggle: { enabled in
                // Toggling "Recognise text in pictures" (F3c): off drops picture matches and
                // clears the in-memory cache; on re-runs the find pass so OCR starts.
                if enabled {
                    Task { await refreshFindRuns() }
                } else {
                    findModel.clearPictureRuns()
                    Task { await DrawingOCRService.shared.clearMemoryCache() }
                }
            })
        // Built-in inspector: a column on iPad, a sheet on iPhone (screenshot #6).
        // A fixed width so the drawing's reserved trailing space matches it exactly.
        .inspector(isPresented: $showInspector) { inspectorContent }
        .inspectorColumnWidth(min: inspectorWidth, ideal: inspectorWidth, max: inspectorWidth)
        // Records inspector (F5c): configure when the segment is shown or the content
        // changes, render each selection off-main, rebuild on an options change.
        .task(id: recordsConfigKey) { configureRecordsIfNeeded() }
        // On-device AI (A1a): reset the models and seed alt text when the drawing
        // changes (or edit mode flips).
        .task(id: "\(session.loadedContentID)·\(session.editing == .editing)") { configureAIForCurrentDrawing() }
        // Accessibility Check (X1a): re-run the analysis when the drawing, the edit, or the
        // Check segment's visibility changes.
        .task(id: checkConfigKey) { configureCheckIfNeeded() }
        .onChange(of: recordModel.selectedIndex) { _, index in
            replayDriver.request(index: index, model: recordModel)
        }
        .onChange(of: settings.renderOptions) { _, _ in
            replayDriver.invalidate()
            configureRecordsIfNeeded()
        }
    }

    /// The sheets and the image-insert pickers layered over `findLayer`.
    private var sheetsLayer: some View {
        findLayer
        .sheet(item: shareSheetBinding, onDismiss: { exporter.cleanupTemp() }) { payload in
            ShareSheet(items: payload.items)
                .presentationDetents([.medium, .large])   // G5
        }
        // Send to AI… (A3b): the confirm sheet (the opt-in toggle) then the activity sheet.
        .sheet(isPresented: $showAIShareConfirm) {
            AIShareConfirmSheet(includeOriginal: $aiShareIncludeOriginal) {
                showAIShareConfirm = false
                sendToAI(includeOriginal: aiShareIncludeOriginal)
            } onCancel: {
                showAIShareConfirm = false
            }
            .presentationDetents([.height(240), .medium])   // C5e L3/A2
        }
        .sheet(item: aiActivityBinding, onDismiss: { exporter.cleanupAITemp() }) { payload in
            ShareSheet(items: payload.items)
                .presentationDetents([.medium, .large])
        }
        #if DEBUG
        // F1 screenshot (d): the share actions in a system dialog (same actions as the
        // Menu — a SwiftUI Menu popover can't be opened without a tap). One modifier, so
        // the already-large body stays type-checkable.
        .modifier(DebugShareDialogModifier(loaded: isLoaded, isPresented: $debugShareDialog) { debugRunShareAction($0) })
        #endif
        // The pen palette, shown by a Pencil squeeze or double-tap-to-palette (design
        // call 5); the Pen toolbar menu offers the same choices on a long-press.
        .sheet(isPresented: penPaletteBinding) {
            PenPaletteSheet(editorModel: editorModel)
                .presentationDetents([.height(240), .medium])
        }
        // The light editor's Colour sheet (E4 design call 2): 8 swatches plus a system
        // ColorPicker, applied to the selection through `DocumentSession.applyColor`.
        .sheet(isPresented: $showColorSheet) {
            LightColorSheet(session: session, selection: editorModel.selection.ids)
                .presentationDetents([.height(260), .medium])
                .presentationDragIndicator(.visible)
        }
        // Editor AI edit + recolour sheets (X2a).
        .sheet(isPresented: $showingAIEditSheet) {
            DrawingAIEditView(model: aiEditModel, onClose: { showingAIEditSheet = false })
                .environment(aiProviders)
        }
        .sheet(isPresented: $showingRecolourSheet) {
            DrawingRecolourView(model: recolourModel, onClose: { showingRecolourSheet = false })
        }
        .sheet(isPresented: $showingTranslateSheet) {
            DrawingAITranslateView(model: translateModel, onClose: { showingTranslateSheet = false })
                .environment(aiProviders)
        }
        #if DEBUG
        // The `iphone-settings` script presents the real Settings screen so a capture
        // shows the Full-editor toggle and its footer (E4 verification d).
        .sheet(isPresented: $showDebugSettings) {
            SettingsView()
                .environment(store)
                .environment(settings)
        }
        #endif
        // Image insert (E3c design call 2): the Photos / Files pickers and the failure
        // toast, hung off a zero-size overlay so the main body stays type-checkable.
        .overlay { imageInsertControls }
        // Translate (F3d): the system overlay for the current Find match, else the drawing's
        // text. Isolated in one gated modifier (macOS 14.4 / iOS 17.4).
        .modifier(DrawingTranslationModifier(isPresented: $showTranslation, text: translationText))
    }

    /// The alerts, confirmations and transient overlays layered over `sheetsLayer`.
    private var alertsLayer: some View {
        sheetsLayer
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
            // The dismiss setter cancels ONLY a genuine dismissal, never while a button is
            // resolving (R2U1): a tapped "Save Anyway" marks the resolution synchronously, so
            // this setter — fired before the button's async write runs — no longer pre-empts it.
            isPresented: Binding(get: { session.pendingWMFConfirmation != nil }, set: { if !$0 { session.dismissPendingWMFConfirmation() } }),
            titleVisibility: .visible,
            presenting: session.pendingWMFConfirmation
        ) { pending in
            Button("Save Anyway") { session.beginResolvingWMFConfirmation(); Task { await session.confirmPendingWMFSave() } }
            Button("Save a Copy as EMF…") { session.beginResolvingWMFConfirmation(); saveSceneCopyAsEMF() }
            // Only while leaving edit mode (Done/back): let the user drop the edits and
            // exit rather than being stuck in the editor on a dirty WMF (U1).
            if session.isEndingEditing {
                Button("Don’t Save", role: .destructive) { session.beginResolvingWMFConfirmation(); session.discardEditsAndStopEditing() }
            }
            Button("Cancel", role: .cancel) { session.cancelPendingWMFSave() }
        } message: { pending in
            Text(WMFLimitationWording.message(for: pending))
        }
        // A save that fails while leaving edit mode (Done / back / switch) used to trap the user
        // in the editor with only a transient toast (R2U2). Offer a real way out, wired to the
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
    }

    /// The viewer's state reactions: keyboard commands, the published actions, the load
    /// task and the settings/save/scene observers, layered over `alertsLayer`.
    private var reactionsLayer: some View {
        alertsLayer
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
        // Typed save-failure and saved-with-limitations toasts (E2a-9 / E2a-5, review #6). A
        // failure that blocks a leave is handled by the R2U2 alert, not a transient toast.
        .onChange(of: session.lastSaveError != nil) { _, hasError in
            if hasError, let error = session.lastSaveError, !session.isEndingEditing {
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
        #if DEBUG
        .task { await runDebugLaunchIfNeeded() }
        #endif
    }

    #if DEBUG
    /// The E2b screenshot hook (design call E2b-8): once the file loads, enter edit mode
    /// and pre-select the first N editable elements, so a simulator screenshot shows the
    /// selection without any touches. The capture itself is `xcrun simctl io screenshot`.
    @MainActor
    private func runDebugLaunchIfNeeded() async {
        guard !debugLaunchRan, EditorDebugLaunch.isActive else { return }
        debugLaunchRan = true
        for _ in 0..<80 { if session.loaded != nil { break }; try? await Task.sleep(for: .milliseconds(100)) }
        guard session.loaded != nil else { return }
        if EditorDebugLaunch.script == "undo-redo" { await runUndoRedoScript(); return }
        if EditorDebugLaunch.script == "new-shapes" { await runNewShapesScript(); return }
        if EditorDebugLaunch.script == "pen-strokes" { await runPenStrokesScript(); return }
        if EditorDebugLaunch.script == "text-image" { await runTextImageScript(); return }
        if EditorDebugLaunch.script == "wmf-done" { await runWMFDoneScript(); return }
        if EditorDebugLaunch.script == "wmf-leave" { await runWMFLeaveScript(); return }
        if EditorDebugLaunch.script == "wmf-save-anyway" { await runWMFSaveAnywayScript(); return }
        if EditorDebugLaunch.script == "save-fail-alert" { await runSaveFailAlertScript(); return }
        if EditorDebugLaunch.script == "text-popover" { await runTextPopoverScript(); return }
        if EditorDebugLaunch.script == "layers" { await runLayersScript(); return }
        if EditorDebugLaunch.script == "align-grid" { await runAlignGridScript(); return }
        if EditorDebugLaunch.script == "a11y-dump" { await runAccessibilityDumpScript(); return }
        if EditorDebugLaunch.script == "iphone-light" { await runIPhoneLightScript(stage: .select); return }
        if EditorDebugLaunch.script == "iphone-light-color" { await runIPhoneLightScript(stage: .colour); return }
        if EditorDebugLaunch.script == "iphone-light-edited" { await runIPhoneLightScript(stage: .edited); return }
        if EditorDebugLaunch.script == "iphone-settings" { await runIPhoneSettingsScript(); return }
        if EditorDebugLaunch.script == "iphone-full" { await runIPhoneFullScript(); return }
        if EditorDebugLaunch.findQuery != nil { await runFindScript(); return }
        if EditorDebugLaunch.recordsInspector { await runRecordsScript(); return }
        if EditorDebugLaunch.script == "check" { await runCheckScript(); return }
        // Read-only viewer with the file-details (Info) inspector open — the P1 iPad
        // canvas-placement capture. `-EmfyDebugInspector YES` without `-EmfyDebugEdit YES`.
        if !EditorDebugLaunch.editOnOpen, EditorDebugLaunch.showInspector {
            showInspector = true
            return
        }
        guard EditorDebugLaunch.editOnOpen else { return }
        await session.beginEditing()
        if session.editing == .editing {
            if EditorDebugLaunch.selectText, let tid = session.firstTextElementID() {
                editorModel.selection.replace(with: tid)
            } else if EditorDebugLaunch.selectFirst > 0 {
                editorModel.selection.replace(with: session.firstEditableIDs(EditorDebugLaunch.selectFirst))
            }
            // E2c: open the Format inspector for the selection-driven screenshot.
            if EditorDebugLaunch.showInspector { showInspector = true }
        }
    }

    /// iPad undo/redo gate proof (E2d): edit mode → select the first element → Change Fill
    /// → drive the UI Undo (the same `UndoManager` the toolbar buttons and gestures use) →
    /// assert the scene reverted → capture the window (toolbar shows Undo/Redo) → Redo →
    /// assert it re-applies. Logs before/after to stderr; writes the PNG into Documents so
    /// the host can copy it out. Exits so the launch always terminates.
    @MainActor
    private func runUndoRedoScript() async {
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("ios undo-redo: begin editing failed"); exit(2) }
        let ids = session.firstEditableIDs(1)
        editorModel.selection.replace(with: ids)
        session.debugSetFill(ids: ids, red: 0.55, green: 0.10, blue: 0.85)   // a Change Fill edit
        session.debugCancelAutosave()
        try? await Task.sleep(for: .milliseconds(700))
        Self.logScript("ios undo-redo: afterEdit matchesOpened=\(session.debugSceneMatchesOpened()) canUndo=\(session.undoManager.canUndo)")
        // The UI Undo path: the same undo manager the toolbar buttons and ⌘Z/gestures use.
        session.undoManager.undo()
        try? await Task.sleep(for: .milliseconds(700))
        Self.logScript("ios undo-redo: afterUndo matchesOpened=\(session.debugSceneMatchesOpened()) canRedo=\(session.undoManager.canRedo)")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let wrote = Self.captureKeyWindow(to: docs.appendingPathComponent("e2d-ios-undo.png").path)
        Self.logScript("ios undo-redo: screenshotWritten=\(wrote) path=Documents/e2d-ios-undo.png")
        session.undoManager.redo()
        try? await Task.sleep(for: .milliseconds(500))
        Self.logScript("ios undo-redo: afterRedo matchesOpened=\(session.debugSceneMatchesOpened())")
        session.debugCancelAutosave()
        try? await Task.sleep(for: .milliseconds(300))
        exit(0)
    }

    /// iPad new-shapes proof (E3a): the opened blank drawing → edit mode → insert shapes
    /// through the tool's own code path → select the last → stay on screen so a simulator
    /// screenshot captures the drawn, selected shape (does NOT exit, unlike the Mac script).
    @MainActor
    private func runNewShapesScript() async {
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("ios new-shapes: begin editing failed"); return }
        let page = session.editingScene?.pageSizeDevice ?? CGSize(width: 1122, height: 793)
        let kinds: [ShapeToolKind] = [.rect, .ellipse, .triangle]
        let w = page.width * 0.16, h = page.height * 0.24
        var lastID: Int?
        for (i, kind) in kinds.enumerated() {
            let x = page.width * 0.1 + CGFloat(i) * (page.width * 0.8 - w) / CGFloat(kinds.count - 1)
            lastID = session.debugInsertShape(kind, rectDevice: CGRect(x: x, y: page.height * 0.38, width: w, height: h))
        }
        if let lastID { editorModel.selection.replace(with: lastID) }
        session.debugCancelAutosave()
        Self.logScript("ios new-shapes: elements=\(session.editingScene?.editableElements.count ?? -1) selected=\(lastID ?? -1)")
    }

    /// iPad layers proof (E3d): blank drawing → edit mode → rename the base layer Background,
    /// add Shapes and Notes with a shape in each → hide Notes, lock Background → select the
    /// Shapes shape and Bring to Front → open the Layers tab → stay on screen so a simulator
    /// screenshot shows the panel (3 named layers, Notes eye-off, Background locked, the
    /// footnote) and the hidden Notes shape not drawn.
    @MainActor
    private func runLayersScript() async {
        await session.beginEditing()
        guard session.editing == .editing, let backgroundID = session.editingScene?.layers.first?.id else {
            Self.logScript("ios layers: begin editing failed"); return
        }
        let page = session.editingScene?.pageSizeDevice ?? CGSize(width: 1122, height: 793)
        session.debugRenameLayer(backgroundID, "Background")
        let shapesID = session.debugAddLayer(name: "Shapes", aboveLayer: backgroundID)
        let notesID = shapesID.flatMap { session.debugAddLayer(name: "Notes", aboveLayer: $0) }
        _ = session.debugInsertShape(.rect, rectDevice: CGRect(x: page.width * 0.10, y: page.height * 0.14, width: page.width * 0.52, height: page.height * 0.34), inLayer: backgroundID)
        let shapesShape = shapesID.flatMap { session.debugInsertShape(.ellipse, rectDevice: CGRect(x: page.width * 0.34, y: page.height * 0.30, width: page.width * 0.34, height: page.height * 0.26), inLayer: $0) }
        _ = notesID.flatMap { session.debugInsertShape(.triangle, rectDevice: CGRect(x: page.width * 0.58, y: page.height * 0.50, width: page.width * 0.30, height: page.height * 0.30), inLayer: $0) }
        if let notesID { session.debugSetLayerHidden(notesID, true) }
        session.debugSetLayerLocked(backgroundID, true)
        if let shapesShape { editorModel.selection.replace(with: shapesShape) }
        if let shapesID { editorModel.activeLayerID = shapesID }
        session.bringSelectionToFront(editorModel.selection.ids)
        EditorDebugLaunch.forceLayersTab = true
        showInspector = true
        session.debugCancelAutosave()
        Self.logScript("ios layers: names=\(session.debugLayerNames()) notesHidden=\(notesID.map { session.debugLayerHidden($0) } ?? false)")
    }

    /// `align-grid` (E3e): blank drawing → edit mode → insert 3 shapes at uneven positions →
    /// select all → Align Top → Distribute Horizontally → show the grid → select one shape so
    /// its outlined handles show on the blue fill (fix A) → stay on screen for the capture.
    @MainActor
    private func runAlignGridScript() async {
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("ios align-grid: begin editing failed"); return }
        let page = session.editingScene?.pageSizeDevice ?? CGSize(width: 1122, height: 793)
        let a = session.debugInsertShape(.rect, rectDevice: CGRect(x: page.width * 0.08, y: page.height * 0.22, width: page.width * 0.17, height: page.height * 0.13))
        let b = session.debugInsertShape(.ellipse, rectDevice: CGRect(x: page.width * 0.46, y: page.height * 0.52, width: page.width * 0.17, height: page.height * 0.13))
        let c = session.debugInsertShape(.rect, rectDevice: CGRect(x: page.width * 0.80, y: page.height * 0.34, width: page.width * 0.15, height: page.height * 0.17))
        let ids = Set([a, b, c].compactMap { $0 })
        guard ids.count == 3 else { Self.logScript("ios align-grid: insert failed (\(ids.count))"); return }
        editorModel.selection.replace(with: ids)
        session.alignSelection(ids, .top)
        session.distributeSelection(ids, .horizontal)
        editorModel.showGrid = true
        if let b { editorModel.selection.replace(with: b) }   // handles over a blue fill (fix A)
        session.debugCancelAutosave()
        let tops = ids.compactMap { id in session.editingScene?.elements.first { $0.id == id }?.selectionBoundsDevice.minY }
        Self.logScript("ios align-grid: tops=\(tops.map { Int($0) }) grid=\(editorModel.showGrid)")
    }

    /// C5g (audit A1): blank drawing → edit mode → insert a few shapes and a text run →
    /// select one element THROUGH THE ACCESSIBILITY ACTION PATH (the canvas coordinator's
    /// Select custom action, not a direct selection set) → dump the live UIKit accessibility
    /// tree (label, value, traits, Voice Control labels, actions) to Documents and stderr →
    /// stay on screen so `simctl io screenshot` captures the selected element. This is the
    /// DEBUG evidence hook for the edit-mode accessibility baseline.
    @MainActor
    private func runAccessibilityDumpScript() async {
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("ios a11y-dump: begin editing failed"); return }
        let page = session.editingScene?.pageSizeDevice ?? CGSize(width: 1122, height: 793)
        let w = page.width * 0.22, h = page.height * 0.16
        _ = session.debugInsertShape(.rect, rectDevice: CGRect(x: page.width * 0.10, y: page.height * 0.14, width: w, height: h))
        _ = session.debugInsertShape(.ellipse, rectDevice: CGRect(x: page.width * 0.60, y: page.height * 0.16, width: w, height: h))
        _ = session.debugInsertText("Quarterly Results", originDevice: CGPoint(x: page.width * 0.12, y: page.height * 0.48))
        let firstID = session.editingScene?.editableElements.first?.id
        session.debugCancelAutosave()
        // Wait for the canvas coordinator to come up, then select via the ACCESSIBILITY path.
        var coordinator: EditableMetafileCanvas.Coordinator?
        for _ in 0..<40 {
            coordinator = EditableMetafileCanvas.Coordinator.debugActive
            if coordinator != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let coordinator, let firstID {
            _ = coordinator.accessibilityPerform(.select, on: firstID)   // the Select custom action
        }
        try? await Task.sleep(for: .milliseconds(300))
        let dump = coordinator?.debugAccessibilityDump() ?? "no coordinator"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? dump.write(to: docs.appendingPathComponent("c5g-a11y-ios.txt"), atomically: true, encoding: .utf8)
        _ = Self.captureKeyWindow(to: docs.appendingPathComponent("c5g-a11y-ios.png").path)
        Self.logScript("ios a11y-dump BEGIN\n\(dump)\nios a11y-dump END")
        session.debugCancelAutosave()
    }

    /// F3b: opens the find bar and searches `EditorDebugLaunch.findQuery` (in edit mode too
    /// when `-EmfyDebugEdit YES`), scrolling the first match into view, then stays on screen
    /// so `simctl io screenshot` captures the bar, "n of m" and the highlights.
    /// F5c (iPad): opens the inspector on the Records segment, steps to the requested
    /// record (default: the last), waits for the off-main render, and stays on screen so
    /// `simctl io screenshot` captures the list, scrubber, DC panel and outlined replay.
    @MainActor
    private func runRecordsScript() async {
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
        Self.logScript("ios records: count=\(recordModel.recordCount) index=\(recordModel.selectedIndex) supportsPartial=\(recordModel.supportsPartial) image=\(replayDriver.image != nil)")
    }

    /// Opens the inspector on the Check segment, waits for the analysis, selects the first
    /// finding (so it is outlined on the canvas), and stays on screen so `simctl io
    /// screenshot` captures the iPad Check segment (X1a screenshot d).
    @MainActor
    private func runCheckScript() async {
        showInspector = true
        viewerInspectorTab = .check
        configureCheckIfNeeded()
        for _ in 0..<80 where checkModel.analysis == nil { try? await Task.sleep(for: .milliseconds(100)) }
        if let first = checkModel.findings.first { checkModel.select(findingID: first.id) }
        Self.logScript("ios check: findings=\(checkModel.findings.count) selected=\(checkModel.selectedFindingID ?? -1)")
    }

    @MainActor
    private func runFindScript() async {
        if EditorDebugLaunch.editOnOpen { await session.beginEditing() }
        controller.fit()
        try? await Task.sleep(for: .milliseconds(500))
        await refreshFindRuns()
        presentFind()
        findModel.query = EditorDebugLaunch.findQuery ?? ""
        findModel.applyQuery()
        try? await Task.sleep(for: .milliseconds(300))
        scrollToCurrentMatch()
        Self.logScript("ios find: query=\"\(findModel.query)\" status=\"\(findModel.statusText)\" matches=\(findModel.matches.count)")
    }

    /// The stage an `iphone-light` capture sets up (E4 verification a/b/c).
    private enum IPhoneLightStage { case select, colour, edited }

    /// iPhone light-editor proof (E4): open a corpus file with shapes and text → enter edit
    /// mode (which resolves to LIGHT on this compact iPhone) → select a shape, then either
    /// just show it (a), open the Colour sheet (b), or recolour it through the real light
    /// Colour path, add one Markup stroke and delete one element (c). Stays on screen so a
    /// simulator screenshot shows the bottom toolbar and the handleless selection outline.
    @MainActor
    private func runIPhoneLightScript(stage: IPhoneLightStage) async {
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("ios iphone-light: begin editing failed"); return }
        guard let shapeID = session.debugFirstShapeID() else { Self.logScript("ios iphone-light: no shape"); return }
        editorModel.selection.replace(with: shapeID)
        switch stage {
        case .select:
            break
        case .colour:
            showColorSheet = true
        case .edited:
            // Recolour the selected shape through the light Colour path (a visibly
            // different purple), delete a different visible shape, and lay down one
            // Markup stroke — so the capture shows all three edits.
            session.debugApplyLightColor(ids: [shapeID], red: 0.55, green: 0.17, blue: 0.78)
            let victim = session.allEditableIDs().subtracting([shapeID]).sorted().last
            let page = session.editingScene?.pageSizeDevice ?? CGSize(width: 1122, height: 793)
            let stroke = (0 ... 40).map { i -> CGPoint in
                CGPoint(x: page.width * 0.18 + Double(i) * (page.width * 0.5 / 40),
                        y: page.height * 0.62 + sin(Double(i) * 0.5) * page.height * 0.05)
            }
            _ = session.debugInsertPenStroke(devicePoints: stroke, held: false, pen: PenStyle(color: PenPalette.blue, widthPoints: 3))
            if let victim { session.deleteSelection([victim]) }
            editorModel.selection.replace(with: shapeID)   // keep the recoloured shape selected
        }
        session.debugCancelAutosave()
        Self.logScript("ios iphone-light: stage=\(stage) selected=\(shapeID) mode=light")
    }

    /// iPhone Settings proof (E4 verification d): present the real Settings screen so a
    /// capture shows the "Full editor on iPhone" toggle and its footer.
    @MainActor
    private func runIPhoneSettingsScript() async {
        showDebugSettings = true
        Self.logScript("ios iphone-settings: presented toggle=\(settings.fullEditorOnIPhone)")
    }

    /// iPhone full-editor proof (E4 verification e): turn the Settings toggle on (so the
    /// compact iPhone resolves to the FULL editor), enter edit mode, select a shape and open
    /// the inspector — which `.inspector` presents as a sheet at compact width. Stays on
    /// screen for the capture.
    @MainActor
    private func runIPhoneFullScript() async {
        settings.fullEditorOnIPhone = true
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("ios iphone-full: begin editing failed"); return }
        if let shapeID = session.debugFirstShapeID() { editorModel.selection.replace(with: shapeID) }
        showInspector = true
        session.debugCancelAutosave()
        Self.logScript("ios iphone-full: fullEditor=\(settings.fullEditorOnIPhone) inspector=\(showInspector)")
    }

    /// iPad pen proof (E3b): blank drawing → edit mode → feed a couple of synthetic strokes
    /// through the pen pipeline (`DocumentSession.debugInsertPenStroke`) — a wavy freehand
    /// line (curve) and a wobbly circle with a hold (snaps to an ellipse) — then ARM the pen
    /// and stay on screen, so a simulator screenshot shows the pen-armed toolbar plus strokes.
    @MainActor
    private func runPenStrokesScript() async {
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("ios pen-strokes: begin editing failed"); return }
        let page = session.editingScene?.pageSizeDevice ?? CGSize(width: 1122, height: 793)
        let wavy = (0 ... 48).map { CGPoint(x: page.width * 0.08 + Double($0) * (page.width * 0.4 / 48), y: page.height * 0.22 + sin(Double($0) * 0.4) * page.height * 0.05) }
        var circle = (0 ... 72).map { i -> CGPoint in
            let a = Double(i) / 72 * 2 * .pi
            return CGPoint(x: page.width * 0.72 + cos(a) * page.width * 0.16 + sin(Double(i) * 0.9) * 3,
                           y: page.height * 0.32 + sin(a) * page.width * 0.16 + cos(Double(i) * 0.9) * 3)
        }
        circle.append(circle[0])
        _ = session.debugInsertPenStroke(devicePoints: wavy, held: false, pen: PenStyle(color: PenPalette.black, widthPoints: 2))
        _ = session.debugInsertPenStroke(devicePoints: circle, held: true, pen: PenStyle(color: PenPalette.blue, widthPoints: 4))
        editorModel.armPen()
        session.debugCancelAutosave()
        Self.logScript("ios pen-strokes: elements=\(session.editingScene?.editableElements.count ?? -1) kinds=\(session.editingScene?.editableElements.map { "\($0.kind)" } ?? []) armedPen=\(editorModel.armedPen)")
    }

    /// iPad text + image proof (E3c): blank drawing → edit mode → insert a text element
    /// "Hello Emfy" and an in-process gradient image through the SAME tool commit paths
    /// (`debugInsertText` / `debugInsertImage`) → select the image → SAVE in place (so a
    /// plain relaunch proves persistence) → stay on screen so a simulator screenshot
    /// shows the text, the image and the image's selection handles.
    @MainActor
    private func runTextImageScript() async {
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("ios text-image: begin editing failed"); return }
        let page = session.editingScene?.pageSizeDevice ?? CGSize(width: 1122, height: 793)
        let textID = session.debugInsertText("Hello Emfy", originDevice: CGPoint(x: page.width * 0.12, y: page.height * 0.2))
        let imageID = await session.debugInsertImage(Self.debugGradientPNG(), centreDevice: CGPoint(x: page.width * 0.5, y: page.height * 0.6))
        if let imageID { editorModel.selection.replace(with: imageID) }
        try? await Task.sleep(for: .milliseconds(400))
        await session.save()
        // The in-place save targets a sandboxed imported copy; also write the exported EMF
        // to the host scriptFile so a plain relaunch can reopen exactly what was persisted.
        if let data = session.debugExportEMF(), let path = EditorDebugLaunch.scriptFile {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        session.debugCancelAutosave()
        try? await Task.sleep(for: .milliseconds(300))
        Self.logScript("ios text-image: textID=\(textID ?? -1) imageID=\(imageID ?? -1) elements=\(session.editingScene?.editableElements.count ?? -1) kinds=\(session.editingScene?.editableElements.map { "\($0.kind)" } ?? []) saveError=\(session.lastSaveError.map { "\($0)" } ?? "nil")")
    }

    /// U1 proof: open a WMF → edit mode → one edit → tap Done. `endEditing()` runs a
    /// non-autosave save, which raises the "Save as WMF?" confirmation and KEEPS edit mode
    /// (no discard), so a simulator screenshot shows the confirmation after Done.
    @MainActor
    private func runWMFDoneScript() async {
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("ios wmf-done: begin editing failed"); return }
        let page = session.editingScene?.pageSizeDevice ?? CGSize(width: 1122, height: 793)
        _ = session.debugInsertText("Edited", originDevice: CGPoint(x: page.width * 0.15, y: page.height * 0.2))
        try? await Task.sleep(for: .milliseconds(200))
        await session.endEditing()   // the Done path
        Self.logScript("ios wmf-done: dirty=\(session.isDirty) wmfPending=\(session.pendingWMFConfirmation != nil) ending=\(session.isEndingEditing) editing=\(session.editing == .editing)")
    }

    /// C5d U1 proof: open a WMF → edit mode → one edit → leave the document (the guarded
    /// Back / deselect, `onBack`). The window model runs the save guard, which raises the
    /// "Save as WMF?" choice and HOLDS the navigation (nothing discarded), so a simulator
    /// screenshot shows the dialog over the still-shown document. Stays alive for the capture.
    @MainActor
    private func runWMFLeaveScript() async {
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("ios wmf-leave: begin editing failed"); return }
        let page = session.editingScene?.pageSizeDevice ?? CGSize(width: 1122, height: 793)
        _ = session.debugInsertText("Edited", originDevice: CGPoint(x: page.width * 0.15, y: page.height * 0.2))
        try? await Task.sleep(for: .milliseconds(200))
        onBack()   // the guarded leave: window model raises the WMF choice and holds the nav
        try? await Task.sleep(for: .milliseconds(600))
        Self.logScript("ios wmf-leave: wmfPending=\(session.pendingWMFConfirmation != nil) ending=\(session.isEndingEditing) editing=\(session.editing == .editing)")
    }

    /// C6a R2U1 write-proof: open a WMF → edit mode → one edit → tap Done (raises the "Save as
    /// WMF?" dialog) → drive the REAL button ordering (mark the resolution, the dismiss setter
    /// fires, then the async write). Logs the on-disk checksum before and after to prove the WMF
    /// bytes actually changed (the old bug wrote nothing), and captures the document shown after
    /// the successful Save Anyway (no dialog, back in the viewer). Writes the PNG into Documents.
    @MainActor
    private func runWMFSaveAnywayScript() async {
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("ios wmf-save-anyway: begin editing failed"); return }
        let before = await session.debugResolvedChecksum()
        let page = session.editingScene?.pageSizeDevice ?? CGSize(width: 1122, height: 793)
        _ = session.debugInsertText("Edited via Save Anyway", originDevice: CGPoint(x: page.width * 0.12, y: page.height * 0.18))
        try? await Task.sleep(for: .milliseconds(150))
        await session.endEditing()                       // Done → "Save as WMF?" dialog
        // The REAL button sequence, in SwiftUI's order: the dismiss setter fires before the
        // button's async write runs. Without the R2U1 fix this wrote nothing.
        session.beginResolvingWMFConfirmation()
        let work = Task { await session.confirmPendingWMFSave() }
        session.dismissPendingWMFConfirmation()
        await work.value
        let after = await session.debugResolvedChecksum()
        try? await Task.sleep(for: .milliseconds(300))
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let wrote = Self.captureKeyWindow(to: docs.appendingPathComponent("c6a-ipad-wmf-saveanyway.png").path)
        Self.logScript("ios wmf-save-anyway: before=\(before) after=\(after) changed=\(before != after) editing=\(session.editing == .editing) screenshot=\(wrote) path=Documents/c6a-ipad-wmf-saveanyway.png")
    }

    /// C6a R2U2 proof: open an EMF → edit mode → one edit → force the next save to fail → tap
    /// Done. The failed Done raises the save-failure alert (Try Again / Save a Copy / Don't Save
    /// / Cancel) instead of trapping the user with a toast. Captures the alert; logs the blocked
    /// state. Writes the PNG into Documents.
    @MainActor
    private func runSaveFailAlertScript() async {
        await session.beginEditing()
        guard session.editing == .editing else { Self.logScript("ios save-fail-alert: begin editing failed"); return }
        let page = session.editingScene?.pageSizeDevice ?? CGSize(width: 1122, height: 793)
        _ = session.debugInsertText("Edited", originDevice: CGPoint(x: page.width * 0.15, y: page.height * 0.2))
        try? await Task.sleep(for: .milliseconds(150))
        session.debugInjectWriteFailure = true           // the next save fails before any bytes land
        await session.endEditing()                       // Done → failed save → R2U2 alert
        try? await Task.sleep(for: .milliseconds(600))
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let wrote = Self.captureKeyWindow(to: docs.appendingPathComponent("c6a-iphone-savefail-alert.png").path)
        Self.logScript("ios save-fail-alert: blocked=\(session.isLeaveBlockedBySaveError) editing=\(session.editing == .editing) screenshot=\(wrote) path=Documents/c6a-iphone-savefail-alert.png")
    }

    /// iPad text-popover proof (E3c): blank drawing → edit mode → insert a text element and
    /// open its popover (the SAME popover a text-tool tap opens), then stay on screen so a
    /// simulator screenshot shows the popover on a freshly inserted text.
    @MainActor
    private func runTextPopoverScript() async {
        await session.beginEditing()
        guard session.editing == .editing, let scene = session.editingScene else { Self.logScript("ios text-popover: begin editing failed"); return }
        let page = scene.pageSizeDevice
        let origin = CGPoint(x: page.width * 0.2, y: page.height * 0.35)
        let insertion = TextToolInsertion.element(originDevice: origin, in: scene)
        session.beginInsertText(insertion.element)
        editorModel.selection.replace(with: insertion.id)
        editorModel.textEdit = TextEditRequest(id: insertion.id, anchor: UnitPoint(x: 0.2, y: 0.35), initialText: insertion.element.text?.string ?? "Text")
        session.debugCancelAutosave()
        try? await Task.sleep(for: .milliseconds(300))
        Self.logScript("ios text-popover: id=\(insertion.id) popoverOpen=\(editorModel.textEdit != nil)")
    }

    /// A small in-process gradient PNG, so the image-insert script needs no external file.
    @MainActor
    private static func debugGradientPNG() -> Data {
        let size = CGSize(width: 240, height: 160)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.pngData { context in
            let cg = context.cgContext
            let colors = [UIColor.systemBlue.cgColor, UIColor.systemOrange.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
        }
    }

    /// Permission-free in-process capture of the key window (toolbar included), written to
    /// `path`, so the host copies it out of the app container.
    @MainActor
    private static func captureKeyWindow(to path: String) -> Bool {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return false }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        guard let data = image.pngData() else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    private static func logScript(_ message: String) {
        FileHandle.standardError.write(Data("EMFY-E2D \(message)\n".utf8))
    }
    #endif

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

    /// Send to AI… (A3b): packages the whole drawing (the edited scene when diverged,
    /// else the original) as a PNG + text summary and hands it to the system share sheet.
    /// `includeOriginal` attaches the original file too (the confirm-sheet toggle, off).
    private func sendToAI(includeOriginal: Bool) {
        guard let model = loaded, let entry else { return }
        let opts = ExportScale.pngOptions(for: model.prepared.naturalSize, settings: settings)
        let source = AISharePackage.outputSource(
            isEditing: session.editing == .editing, hasDiverged: session.hasDivergedFromOpened)
        let recordCount = model.prepared.recordKinds.reduce(0) { $0 + $1.count }
        exporter.sendToAI(
            entry: entry, store: store, source: source,
            prepared: model.prepared, editedScene: session.editedScene,
            allText: findModel.copyAllText(), recordCount: recordCount,
            background: opts.background, options: settings.renderOptions,
            includeOriginal: includeOriginal)
    }

    // Computed bindings keep share/export state on the `@Observable` controller.
    private var shareSheetBinding: Binding<SharePayload?> {
        Binding(get: { exporter.sharePayload }, set: { exporter.sharePayload = $0 })
    }

    private var aiActivityBinding: Binding<AIActivityPayload?> {
        Binding(get: { exporter.aiActivityPayload }, set: { exporter.aiActivityPayload = $0 })
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
        // In edit mode the drawing is fed from the scene through the crisp tiled canvas
        // with the selection overlay (design calls E2b-1/-2). Read-only viewing keeps
        // the prepared-model tiled view.
        if session.editing == .editing {
            MetafileEditingContainer(
                session: session, editorModel: editorModel, controller: controller,
                displayScale: displayScale,
                tilePaint: ViewerTilePaint.make(
                    background: settings.pageBackground, darkMode: settings.darkPageMode, isDark: colorScheme == .dark
                ),
                options: settings.renderOptions,
                // The editable canvas fills the full width (E2c item 4); the drawing is
                // fitted and centred into the region the inspector overlay leaves clear.
                trailingInset: (showInspector && isRegularWidth) ? inspectorWidth : 0,
                // Light mode (E4): selection outline only, drag moves only — no handles.
                lightMode: editorMode == .light,
                findHighlights: findHighlightSet
            )
            .ignoresSafeArea()
            .overlay(alignment: .bottom) { rotationReadout }
        } else {
            readOnlyDrawingLayer
        }
    }

    /// The live rotation-angle readout while a two-finger rotation is in flight (E2b-6).
    @ViewBuilder
    private var rotationReadout: some View {
        if let readout = editorModel.rotationReadout {
            Text(readout)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 12).padding(.vertical, 6)
                .floatingSurface(in: Capsule())
                .padding(.bottom, 80)
        }
    }

    @ViewBuilder
    private var readOnlyDrawingLayer: some View {
        switch phase {
        case .loading:
            ProgressView()
                .accessibilityLabel("Loading drawing")   // A10
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, reservedInspectorWidth)   // keep clear of the inspector (P1)
        case .loaded(let model):
            if showsReplayCanvas {
                RecordReplayView(
                    image: replayDriver.image,
                    pixelSize: replayDriver.pixelSize,
                    deviceBounds: replayDriver.deviceBounds,
                    outlineDeviceRect: replayDriver.outlineDeviceRect,
                    contentToken: replayDriver.contentToken
                )
                .ignoresSafeArea()
                .padding(.trailing, reservedInspectorWidth)   // keep clear of the inspector (P1)
            } else {
            ZoomableMetafileView(
                prepared: model.prepared,
                naturalSize: model.displaySize,
                displayScale: displayScale,
                drawingLabel: canvasAccessibilityLabel,
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
                findHighlights: findHighlightSet,
                reservedTrailing: reservedInspectorWidth,
                reservedCentreTrailing: reservedInspectorCentreWidth,
                onSingleTap: { toggleChrome() }
            )
            .ignoresSafeArea()
            // iPad long-press drag out (F1 design call 3): provides the drawing as a
            // vector PDF file promise + PNG. Viewer-mode only — this read-only layer is
            // replaced by the editable canvas in edit mode, so the drag never competes
            // with element dragging.
            .onDrag {
                MetafileExportController.dragItemProvider(
                    prepared: model.prepared,
                    baseName: entry?.baseName ?? "Drawing",
                    pngScale: settings.defaultPNGScale.multiplier,
                    background: settings.pngBackground == .transparent ? .transparent : .white,
                    options: settings.renderOptions)
            }
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
                .padding(.trailing, reservedInspectorWidth)   // keep clear of the inspector (P1)
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

    /// The Edit / Done nav-bar button (design call E2b-1; E4 extends it to compact
    /// width for the iPhone light editor). Entering lifts the scene; Done clears the
    /// selection and flushes any pending save.
    @ToolbarContentBuilder
    private var editToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(session.editing == .editing ? "Done" : "Edit") { toggleEditMode() }
                .disabled(loaded == nil)
                .accessibilityIdentifier("viewerEdit")
        }
    }

    /// Whether the compact push must guard the Back button (U1): only while editing, and
    /// only in the compact stack (at regular width the viewer is a detail column with no
    /// back button). `isDirty` is not required — leaving edit mode mid-navigation runs the
    /// save flow regardless, and a clean session just pops.
    private var guardsBack: Bool { !isRegularWidth && session.editing == .editing }

    /// The custom Back button shown while `guardsBack`, routing the leave through the window
    /// model's save guard instead of letting the system pop the push unguarded (U1).
    @ToolbarContentBuilder
    private var backToolbarItem: some ToolbarContent {
        if guardsBack {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    editorModel.selection.clear()
                    editorModel.disarmTools()
                    onBack()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .accessibilityIdentifier("viewerGuardedBack")
            }
        }
    }

    /// Undo / Redo in edit mode (E2d), Freeform-style: iPad (regular width) only, in the
    /// nav bar's leading group, enabled per the scene history's canUndo/canRedo. They drive
    /// the same `UndoManager` the canvas vends, so a hardware ⌘Z and these buttons agree.
    @ToolbarContentBuilder
    private var undoRedoToolbar: some ToolbarContent {
        if isFullEditing {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button { session.undoManager.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!undoAvailable)
                    .accessibilityIdentifier("viewerUndo")
                Button { session.undoManager.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(!redoAvailable)
                    .accessibilityIdentifier("viewerRedo")
            }
        }
    }

    /// Reads `editVersion` (observed) so the enablement re-evaluates after every edit,
    /// undo and redo — `UndoManager.canUndo` itself isn't observable.
    private var undoAvailable: Bool { _ = session.editVersion; return session.undoManager.canUndo }
    private var redoAvailable: Bool { _ = session.editVersion; return session.undoManager.canRedo }

    /// The Shapes menu in edit mode (E3a design call 5): iPad (regular width) only,
    /// matching the Mac toolbar. Choosing a shape arms the creation tool; the canvas
    /// then draws it on a drag (or inserts a default on a tap).
    @ToolbarContentBuilder
    private var shapesToolbar: some ToolbarContent {
        if isFullEditing {
            if isRegularWidth {
                ToolbarItem(placement: .topBarLeading) { shapesMenu }
                ToolbarItem(placement: .topBarLeading) { penMenu }
                ToolbarItem(placement: .topBarLeading) { textButton }
                ToolbarItem(placement: .topBarLeading) { imageMenu }
                ToolbarItem(placement: .topBarLeading) { gridMenu }
                ToolbarItem(placement: .topBarLeading) { aiEditMenu }
            } else {
                // A narrow full-editor window (iPad Slide Over / a slim Stage Manager
                // window) can't fit six leading tool buttons, so they fold into one Tools
                // menu with each tool as a submenu (C5e L7).
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        shapesMenu
                        penMenu
                        textButton
                        imageMenu
                        gridMenu
                        aiEditMenu
                    } label: {
                        Label("Tools", systemImage: "pencil.and.outline")
                    }
                    .accessibilityIdentifier("viewerTools")
                }
            }
        }
    }

    /// The Shapes menu, reused both as its own toolbar item (regular width) and as a
    /// submenu of the folded Tools menu (compact width).
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
        .accessibilityIdentifier("viewerShapes")
    }

    /// The grid + snapping menu in edit mode (E3e design call 2/3): iPad (regular width).
    /// Show Grid draws the 10 mm editor grid; the two Snap toggles govern snapping to the
    /// grid and to smart guides. State lives on `EditorModel` (per session).
    private var gridMenu: some View {
        Menu {
            Toggle("Show Grid", isOn: Binding(get: { editorModel.showGrid }, set: { editorModel.showGrid = $0 }))
            Toggle("Snap to Grid", isOn: Binding(get: { editorModel.snapToGrid }, set: { editorModel.snapToGrid = $0 }))
            Toggle("Snap to Guides", isOn: Binding(get: { editorModel.snapToGuides }, set: { editorModel.snapToGuides = $0 }))
        } label: {
            Label("Grid", systemImage: "grid")
        }
        .tint(editorModel.showGrid ? Color.accentColor : nil)
        .accessibilityIdentifier("viewerGrid")
    }

    /// The Text tool (E3c design call 1): iPad (regular width) only. A tap arms it; the
    /// next canvas tap inserts a text element and opens its popover, then the tool
    /// disarms. An accent tint marks the armed state.
    private var textButton: some View {
        Button {
            if editorModel.armedTextTool { editorModel.disarmTools() } else { editorModel.armText() }
        } label: {
            Label("Text", systemImage: "textformat")
        }
        .tint(editorModel.armedTextTool ? Color.accentColor : nil)
        .accessibilityIdentifier("viewerText")
    }

    /// The Image menu (E3c design call 2): iPad (regular width) only. It offers Photos
    /// (the system photo picker) and Files (the document picker), both images-only;
    /// opening either disarms the other creation tools.
    private var imageMenu: some View {
        Menu {
            Button {
                editorModel.disarmTools()
                photoPickerPresented = true
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
            Button {
                editorModel.disarmTools()
                imageImporterPresented = true
            } label: {
                Label("Files", systemImage: "folder")
            }
        } label: {
            Label("Image", systemImage: "photo")
        }
        .accessibilityIdentifier("viewerImage")
    }

    /// The Photos picker, Files importer and the image-insert failure toast, isolated on a
    /// zero-size, non-interactive overlay so the main view body stays type-checkable.
    private var imageInsertControls: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .photosPicker(isPresented: $photoPickerPresented, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await insertPickedPhoto(item); photoItem = nil }
            }
            .fileImporter(isPresented: $imageImporterPresented, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
                handleImageImport(result)
            }
            .onChange(of: session.imageInsertFailed) { _, failed in
                if failed {
                    toast.show("This image couldn’t be added", systemImage: "photo.badge.exclamationmark")
                    session.clearImageInsertFailed()
                }
            }
    }

    /// Loads a picked Photos item's bytes and inserts it through the session's capped,
    /// metadata-stripping image path, selecting the new element (design call 2).
    private func insertPickedPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            session.markImageInsertFailed(); return
        }
        insertImageData(data)
    }

    /// Reads an imported file URL's bytes (security-scoped) and inserts them.
    private func handleImageImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { session.markImageInsertFailed(); return }
        insertImageData(data)
    }

    /// Inserts decoded image bytes centred on the page and selects the new element; a
    /// decode/cap failure sets `imageInsertFailed`, which the body observer toasts.
    private func insertImageData(_ data: Data) {
        // The decode/re-encode happens off the main thread inside insertImage (P7).
        Task { @MainActor in
            if let id = await session.insertImage(data: data) {
                editorModel.selection.replace(with: id)
            }
        }
    }

    /// The Pen tool (E3b design call 1/3): iPad (regular width) only. A tap toggles the pen
    /// (it stays armed until Esc or re-tap, unlike Shapes); long-pressing the button opens
    /// the palette of 6 colours and 3 widths, persisted on `EditorModel`. An Apple Pencil
    /// draws the pen even while unarmed (handled in the canvas); this button governs finger
    /// drawing and the armed tint.
    private var penMenu: some View {
        Menu {
            penPaletteMenuContent
        } label: {
            Label("Pen", systemImage: "pencil.tip")
        } primaryAction: {
            if editorModel.armedPen { editorModel.armedPen = false } else { editorModel.armPen() }
        }
        .tint(editorModel.armedPen ? Color.accentColor : nil)
        .accessibilityIdentifier("viewerPen")
    }

    private var penPaletteBinding: Binding<Bool> {
        Binding(get: { editorModel.penPalettePresented }, set: { editorModel.penPalettePresented = $0 })
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
                    await session.endEditing()
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        if isLightEditing {
            // The light editor's system bottom toolbar (E4 design call 2): Markup,
            // Colour, Text (edit the selected run), Delete, Undo and Redo.
            ToolbarItemGroup(placement: .bottomBar) {
                markupMenu
                colourButton
                aiEditMenu
                lightTextButton
                deleteButton
                Spacer()
                lightUndoButton
                lightRedoButton
            }
        } else if #available(iOS 27.0, *) {
            ToolbarItemGroup(placement: .bottomBar) {
                shareMenu
                findButton
                fitButton
                infoButton
            }
            .visibilityPriority(.high)
        } else {
            ToolbarItemGroup(placement: .bottomBar) {
                shareMenu
                findButton
                fitButton
                infoButton
            }
        }
    }

    /// The Find button (F3b): opens the find bar over the drawing.
    private var findButton: some View {
        Button {
            presentFind()
        } label: {
            Label("Find", systemImage: "magnifyingglass")
        }
        .disabled(loaded == nil)
        .accessibilityIdentifier("viewerFind")
    }

    // MARK: - Light editor bottom toolbar (E4)

    /// Markup (the E3b pen): a tap toggles the pen armed (a finger then draws); long-
    /// pressing opens the E3b pen palette (colour + width). Mirrors the iPad Pen button.
    private var markupMenu: some View {
        Menu {
            penPaletteMenuContent
        } label: {
            Label("Markup", systemImage: "pencil.tip")
        } primaryAction: {
            if editorModel.armedPen { editorModel.armedPen = false } else { editorModel.armPen() }
        }
        .tint(editorModel.armedPen ? Color.accentColor : nil)
        .accessibilityIdentifier("viewerMarkup")
    }

    /// The AI edit + recolour menu (X2a), shown in both the iPad full editor and the iPhone
    /// light editor. Both scope to the current selection.
    private var aiEditMenu: some View {
        Menu {
            if aiEnabled {
                Button { startEditorAIEdit() } label: { Label("Edit with AI…", systemImage: "wand.and.stars.inverse") }
                Button { startEditorTranslate() } label: { Label("Translate…", systemImage: "character.bubble") }
            }
            Button { startEditorRecolour() } label: { Label("Recolour…", systemImage: "paintpalette") }
        } label: {
            Label("AI & Colour", systemImage: "wand.and.stars")
        }
        .accessibilityIdentifier("viewerAIEdit")
    }

    private func startEditorAIEdit() {
        aiEditModel.reset()
        aiEditModel.configure(session: session, scope: editorModel.selection.ids)
        aiEditModel.providerStore = aiProviders
        showingAIEditSheet = true
    }

    private func startEditorRecolour() {
        showingRecolourSheet = true
        Task { await recolourModel.start(session: session, selection: editorModel.selection.ids) }
    }

    private func startEditorTranslate() {
        translateModel.providerStore = aiProviders
        showingTranslateSheet = true
        Task { await translateModel.prepare(session: session, selection: editorModel.selection.ids) }
    }

    /// Colour: opens the compact Colour sheet, applied to the selection (design call 2).
    private var colourButton: some View {
        Button {
            showColorSheet = true
        } label: {
            Label("Colour", systemImage: "paintpalette")
        }
        .disabled(editorModel.selection.ids.isEmpty)
        .accessibilityIdentifier("viewerColour")
    }

    /// Text: edits the SELECTED text element through the E2c popover (design call 2).
    /// It does not insert new text, so it is enabled only for a single text selection.
    private var lightTextButton: some View {
        Button {
            editSelectedTextElement()
        } label: {
            Label("Text", systemImage: "character.cursor.ibeam")
        }
        .disabled(!selectionIsSingleText)
        .accessibilityIdentifier("viewerLightText")
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            session.deleteSelection(editorModel.selection.ids)
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(editorModel.selection.ids.isEmpty)
        .accessibilityIdentifier("viewerDelete")
    }

    private var lightUndoButton: some View {
        Button {
            session.undoManager.undo()
        } label: {
            Label("Undo", systemImage: "arrow.uturn.backward")
        }
        .disabled(!undoAvailable)
        .accessibilityIdentifier("viewerLightUndo")
    }

    private var lightRedoButton: some View {
        Button {
            session.undoManager.redo()
        } label: {
            Label("Redo", systemImage: "arrow.uturn.forward")
        }
        .disabled(!redoAvailable)
        .accessibilityIdentifier("viewerLightRedo")
    }

    /// Whether the selection is exactly one text element (gates the light Text button).
    private var selectionIsSingleText: Bool {
        guard let scene = session.editingScene, editorModel.selection.ids.count == 1,
              let id = editorModel.selection.ids.first else { return false }
        return scene.elements.first { $0.id == id }?.kind == .text
    }

    /// Opens the E2c text-edit popover on the selected text element (anchored to the
    /// centre of the editing container in light mode, where there are no toolbars to
    /// steer the arrow). The container's popover commits through the session.
    private func editSelectedTextElement() {
        guard let scene = session.editingScene, let id = editorModel.selection.ids.first,
              let element = scene.elements.first(where: { $0.id == id }),
              element.kind == .text, let text = element.text else { return }
        editorModel.textEdit = TextEditRequest(id: id, anchor: .center, initialText: text.string)
    }

    /// The pen palette's colour and width choices, shared by the iPad Pen menu and the
    /// light-editor Markup menu (E3b `PenPalette`).
    @ViewBuilder
    private var penPaletteMenuContent: some View {
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
    }

    #if DEBUG
    /// The share actions the F1 screenshot (d) dialog can run — the same ones the share
    /// Menu offers, routed to the same exporter calls.
    enum DebugShareAction { case print, copy, copyImage, copyAllText, sharePNG, sharePDF }

    /// Runs a share action for the DEBUG dialog (screenshot d).
    private func debugRunShareAction(_ action: DebugShareAction) {
        guard let model = loaded, let entry else { return }
        let opts = ExportScale.pngOptions(for: model.prepared.naturalSize, settings: settings)
        switch action {
        case .print:
            exporter.printDrawing(prepared: model.prepared, options: settings.renderOptions, jobName: entry.displayName)
        case .copy:
            exporter.copyDrawing(prepared: model.prepared, scale: opts.scale, background: opts.background, options: settings.renderOptions, toast: toast)
        case .copyImage:
            exporter.copyImage(prepared: model.prepared, scale: opts.scale, background: opts.background, options: settings.renderOptions, toast: toast)
        case .copyAllText:
            copyAllText()
        case .sharePNG:
            exporter.share(.png, prepared: model.prepared, baseName: entry.baseName, scale: opts.scale, background: opts.background, options: settings.renderOptions)
        case .sharePDF:
            exporter.share(.pdf, prepared: model.prepared, baseName: entry.baseName, scale: opts.scale, background: opts.background, options: settings.renderOptions)
        }
    }
    #endif

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
            // Send to AI… (A3b): a PNG + text summary for an AI app the user already has,
            // through the system share sheet. Emfy sends nothing itself.
            Button {
                aiShareIncludeOriginal = false
                showAIShareConfirm = true
            } label: {
                Label(AISharePackage.menuTitle, systemImage: "sparkles")
            }
            .accessibilityIdentifier("sendToAI")
            Divider()
            // Print (F1): the vector PDF through UIPrintInteractionController.
            Button {
                exporter.printDrawing(prepared: model.prepared, options: settings.renderOptions, jobName: entry.displayName)
            } label: {
                Label("Print…", systemImage: "printer")
            }
            .accessibilityIdentifier("printDrawing")
            // Copy (F1): PDF + PNG to the pasteboard.
            Button {
                exporter.copyDrawing(prepared: model.prepared, scale: opts.scale, background: opts.background, options: settings.renderOptions, toast: toast)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("copyDrawing")
            Button {
                exporter.copyImage(prepared: model.prepared, scale: opts.scale, background: opts.background, options: settings.renderOptions, toast: toast)
            } label: {
                Label("Copy Image", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier("copyImage")
            Button {
                exporter.saveToPhotos(prepared: model.prepared, scale: opts.scale, background: opts.background, options: settings.renderOptions, toast: toast)
            } label: {
                Label("Save to Photos", systemImage: "square.and.arrow.down")
            }
            // Copy All Text (F3b): the drawing's text, reading order, plain text. Disabled
            // when the drawing has no text.
            Button {
                copyAllText()
            } label: {
                Label("Copy All Text", systemImage: "text.quote")
            }
            .disabled(!findModel.hasText)
            .accessibilityIdentifier("copyAllText")
            // Translate… (F3d): the system overlay for the current Find match or the drawing's
            // text. Hidden below iOS 17.4; disabled when the drawing has no text.
            if #available(iOS 17.4, *) {
                Button {
                    showTranslation = true
                } label: {
                    Label("Translate…", systemImage: "translate")
                }
                .disabled(!findModel.hasText)
                .accessibilityIdentifier("translateDrawing")
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

    // MARK: - Find (F3b)

    /// The page bounds (device) and natural size the current mode draws with: the edited
    /// scene in edit mode, the prepared model in viewer mode. `nil` when nothing is shown.
    private var findPageGeometry: (pageBoundsDevice: CGRect, naturalSize: CGSize)? {
        if session.editing == .editing, let scene = session.editedScene {
            return (scene.pageBoundsDevice, scene.pageSizeDevice)
        }
        if let model = loaded {
            return (model.prepared.deviceBounds, model.displaySize)
        }
        return nil
    }

    /// The find highlights for the current matches, in device space, for the overlays.
    private var findHighlightSet: FindHighlightSet {
        // The Check segment's selected-finding outline takes precedence while it is showing (X1a).
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

    /// Changes whenever the drawing the find model should search over changes.
    private var findRunsKey: String {
        "\(session.editing == .editing)-\(session.editVersion)-\(session.loadedContentID)"
    }

    /// Recomputes the find model's runs: the edited scene in edit mode (cheap), the
    /// renderer observation in viewer mode (off the main actor).
    private func refreshFindRuns() async {
        let contentID = findRunsKey.hashValue
        let ocrEnabled = settings.recognizeTextInPictures
        if session.editing == .editing, let scene = session.editedScene {
            findModel.setRuns(DrawingTextExtractor.extract(from: scene), contentID: contentID)
            startPictureOCR(ocrEnabled ? DrawingPictureEnumerator.pictures(from: scene) : [], contentID: contentID)
            return
        }
        guard let model = loaded else {
            findModel.setRuns([], contentID: contentID)
            return
        }
        let prepared = model.prepared
        let options = settings.renderOptions
        let (runs, pictures) = await Task.detached(priority: .userInitiated) {
            let observation = MetafileRenderer.observe(prepared, options: options)
            let runs = DrawingTextExtractor.extract(from: observation)
            let pictures = ocrEnabled ? DrawingPictureEnumerator.pictures(from: observation) : []
            return (runs, pictures)
        }.value
        findModel.setRuns(runs, contentID: contentID)
        startPictureOCR(pictures, contentID: contentID)
    }

    /// Kicks off the embedded-picture OCR pass for the current drawing (F3c). Drawing text is
    /// already searchable; the recognised picture text merges in when it completes, off the
    /// main actor, so the UI never blocks.
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

    /// Opens the find bar (⌘F / the Find button). The chrome is restored first so the bar
    /// is reachable even from immersive mode.
    private func presentFind() {
        if chromeHidden { chromeHidden = false }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { findModel.present() }
    }

    /// Copies the drawing's text (reading order, plain text) to the pasteboard (F3b).
    private func copyAllText() {
        let text = findModel.copyAllText()
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        toast.show("Copied all text", systemImage: "doc.on.doc")
    }

    /// The text handed to the Translate overlay (F3d): the current Find match's run text when
    /// one exists, else the drawing's text in Copy All Text order, truncated at a word boundary.
    private var translationText: String {
        DrawingTranslation.text(currentMatch: findModel.currentMatchRunText, allText: findModel.copyAllText())
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
            presentFind: isLoaded ? { presentFind() } : nil,
            findNext: isLoaded ? { presentFind(); findModel.goNext() } : nil,
            findPrevious: isLoaded ? { presentFind(); findModel.goPrevious() } : nil,
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
        // In edit mode the segmented Format | Layers | Info panel replaces Info (E2c design
        // call 1; Layers added E3d). It shows even with no selection so the Layers tab is
        // always reachable; Format then reads "No Selection".
        if session.editing == .editing, loaded != nil, entry != nil {
            EditorInspectorPanel(session: session, editorModel: editorModel, onClose: { closeInspector() }) {
                infoInspector
            }
            .environment(toast)
            .environment(settings)
        } else if let loaded, entry != nil {
            // Read-only viewing: the Info | Records segment (F5c).
            ViewerInspectorPanel(
                tab: $viewerInspectorTab,
                model: recordModel,
                summaries: replayDriver.summaries,
                diagnostics: loaded.diagnostics,
                onClose: { closeInspector() },
                checkModel: checkModel,
                summariseModel: summariseModel,
                onExportReport: exportCheckReport,
                askModel: aiInputs != nil ? askModel : nil,
                aiInputs: aiInputs
            ) {
                infoInspector
            }
            .environment(toast)
            .environment(settings)
        } else {
            infoInspector
        }
    }

    /// Whether the dedicated step-through replay canvas replaces the live tiled viewer
    /// (F5c): the Records segment is active in read-only viewing and this drawing
    /// supports per-record stepping.
    private var showsReplayCanvas: Bool {
        showInspector && viewerInspectorTab == .records
            && session.editing != .editing && recordModel.supportsPartial
    }

    /// Populates the Records model for the loaded drawing: the step-through engine for
    /// an EMF (off-main via the driver), or a list-only load for a WMF program.
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

    /// A change in this key re-runs `configureRecordsIfNeeded`.
    private var recordsConfigKey: String {
        "\(session.loadedContentID)·\(showInspector)·\(viewerInspectorTab == .records)·\(session.editing == .editing)"
    }

    @ViewBuilder
    private var infoInspector: some View {
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
                onZoomStep: { delta in controller.step(by: delta) },
                // On-device Describe (A1a) — only when AI is available.
                aiInputs: aiInputs,
                describeModel: aiInputs != nil ? describeModel : nil,
                altTextStore: aiInputs != nil ? altTextStore : nil
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

    // MARK: - On-device AI (A1a)

    /// Whether on-device AI is available and switched on.
    private var onDeviceReady: Bool {
        settings.useOnDeviceAI && DrawingAIAvailability.current().isAvailable
    }

    /// Whether the AI surface appears: on-device ready OR a provider configured (A2b).
    private var aiEnabled: Bool {
        guard let aiProviders else { return onDeviceReady }
        return aiProviders.shouldShowAISurface(onDeviceAvailable: onDeviceReady)
    }

    /// The AI inputs for this drawing, or `nil` when AI is off or there's nothing to
    /// describe. Read-only viewing only.
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

    // MARK: - Accessibility Check (X1a)

    private var checkConfigKey: String {
        "\(session.loadedContentID)·\(session.editVersion)·\(session.editing == .editing)·\(showInspector)·\(viewerInspectorTab == .check)"
    }

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

    /// Shares the Markdown accessibility report through the system share sheet (X1a §4).
    private func exportCheckReport() {
        guard let markdown = checkModel.markdownReport(title: "\(entry?.baseName ?? "Drawing") — accessibility report") else { return }
        exporter.shareReport(markdown: markdown, baseName: entry?.baseName ?? "Drawing")
    }

    /// Resets the AI models when the drawing changes, and seeds alt text when
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
        if UIAccessibility.isVoiceOverRunning {
            altTextStore.generateIfNeeded(
                contentID: inputs.contentID,
                dataProvider: inputs.dataProvider,
                fileName: inputs.fileName,
                unsupportedNotes: inputs.unsupportedNotes
            )
        }
    }

    private var subtitle: String {
        entry?.formatSizeSubtitle ?? ""
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

/// The pen palette shown as a sheet (E3b design call 5), opened by a Pencil squeeze /
/// double-tap or from the Pen toolbar menu: six colours and three widths, persisted on
/// `EditorModel` for the session.
private struct PenPaletteSheet: View {
    @Bindable var editorModel: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Colour") {
                    HStack(spacing: 8) {
                        ForEach(PenPalette.colors.indices, id: \.self) { i in
                            let swatch = PenPalette.colors[i]
                            Button {
                                editorModel.penStyle.color = swatch.color
                            } label: {
                                Circle()
                                    .fill(swatch.color.swiftUIColor)
                                    .frame(width: 34, height: 34)
                                    .overlay(
                                        Circle().strokeBorder(.primary, lineWidth: editorModel.penStyle.color == swatch.color ? 2.5 : 0)
                                    )
                                    // A 44 pt-tall full-width hit area; the swatch glyph stays 34 pt (C5e A5).
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(swatch.name)
                            .accessibilityAddTraits(editorModel.penStyle.color == swatch.color ? .isSelected : [])
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                Section("Width") {
                    Picker("Width", selection: $editorModel.penStyle.widthPoints) {
                        ForEach(PenPalette.widths, id: \.self) { width in
                            Text("\(Int(width)) pt").tag(width)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Pen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SheetDoneToolbar { dismiss() }   // C5e G3
            }
        }
    }
}

#if DEBUG
/// Hosts the F1 screenshot (d) share dialog as one modifier, so the viewer's large body
/// stays type-checkable. Presents the same actions the share Menu offers once the file
/// has loaded and `-EmfyDebugShareDialog` is set.
private struct DebugShareDialogModifier: ViewModifier {
    let loaded: Bool
    @Binding var isPresented: Bool
    let perform: (MetafileViewerScreen.DebugShareAction) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Share", isPresented: $isPresented, titleVisibility: .visible) {
                Button("Print…") { perform(.print) }
                Button("Copy") { perform(.copy) }
                Button("Copy Image") { perform(.copyImage) }
                Button("Copy All Text") { perform(.copyAllText) }
                Button("Share as PNG") { perform(.sharePNG) }
                Button("Share as PDF") { perform(.sharePDF) }
            }
            .onChange(of: loaded) { _, now in
                guard now, EditorDebugLaunch.shareDialog else { return }
                Task { try? await Task.sleep(for: .milliseconds(700)); isPresented = true }
            }
    }
}
#endif
