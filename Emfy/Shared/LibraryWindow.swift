import CoreSpotlight
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// One library window: a `NavigationSplitView` with a recents sidebar and a viewer
/// detail (v3-plan §9.1). On macOS and regular-width iPad it is a true multi-column
/// layout; on iPhone and narrow widths it collapses to the approved grid → viewer
/// push. Each window owns its selection and its `DocumentSession`, so multiple
/// windows never share viewer state (v3-plan §11.2).
///
/// Compact-width push: a `NavigationSplitView` only auto-pushes the detail when the
/// sidebar is a `List(selection:)`. The compact sidebar is the approved grid, so
/// the push is driven explicitly by a `navigationDestination` on the sidebar; at
/// regular width that destination is inert and the detail column shows instead.
struct LibraryWindow: View {
    @Environment(RecentsStore.self) private var store
    @Environment(OpenCoordinator.self) private var coordinator
    @Environment(EmfySettings.self) private var settings
    @Environment(AIProviderStore.self) private var aiProviders: AIProviderStore?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// The entry a data-driven "Open in New Window" asked for, or `nil` for an
    /// empty window (⌘N). Applied once the store has loaded.
    let initialSelection: UUID?

    @State private var model = LibraryWindowModel()
    /// The split-view column visibility, persisted per scene across relaunch (N2).
    /// `NavigationSplitViewVisibility` isn't `RawRepresentable`, so a string backs it in
    /// `@SceneStorage` and `columnVisibility` maps the two.
    @SceneStorage("library.columns") private var columnVisibilityRaw = "automatic"
    /// Drives the New Drawing presets sheet (E3a): the Mac File ▸ New Drawing… command
    /// sets it through the focused action; the iPad "+" presents its own copy.
    @State private var showNewDrawing = false
    /// Drives the "New Drawing from Description…" sheet (X2d); the Mac File menu sets it
    /// through the focused action.
    @State private var showGenerateDrawing = false
    #if os(macOS)
    /// Drives the Batch Convert sheet (F1); the Mac File menu sets it through the
    /// focused action.
    @State private var showBatchConvert = false
    #endif
    /// One toast surface and one removal coordinator per window, injected so the
    /// sidebar, the viewer and the inspector all post to the same surface (C4a H3,
    /// H6/A2, M3).
    @State private var toastCenter = ToastCenter()
    @State private var removal = RemovalCoordinator()
    /// Drives the "No File Selected" detail's Open… button (C4a L1).
    @State private var isImporting = false
    #if os(macOS)
    /// Whether this window is key, so the "couldn't open" alert shows only in the
    /// front window rather than every window or none (C4a M5).
    @State private var isKeyWindow = false
    #endif
    #if os(iOS)
    /// Drives the once-per-launch What's New sheet on iOS (C3b scope 7); hosted at
    /// the window level so it presents on both iPhone and iPad regardless of the
    /// sidebar variant.
    @State private var showLaunchWhatsNew = false
    #endif

    // Scene-scoped so each window (iOS multi-scene, Mac tabs/windows) restores its
    // own selection rather than sharing one.
    @SceneStorage("library.selection") private var storedSelection: String?

    /// Whether an AI engine (on-device or a configured provider) is available, so the
    /// "New Drawing from Description…" command shows only when it can actually run (X2d).
    private var generateDrawingAvailable: Bool {
        let onDevice = settings.useOnDeviceAI && DrawingAIAvailability.current().isAvailable
        if let aiProviders { return aiProviders.resolvedEngine(onDeviceAvailable: onDevice) != nil }
        return onDevice
    }

    var body: some View {
        // The body is split into chained `some View` layers grouped by concern (the split
        // view, the DEBUG hooks, the reactions) so each is a small type-check expression —
        // the whole modifier chain had reached the Swift type-checker's limit (F3d). The
        // modifier order is unchanged, so this is behaviour-neutral: `reactionsLayer` wraps
        // `debugLayer` wraps `splitLayer`.
        reactionsLayer
    }

    /// The navigation split view with its environment, importer and "couldn't open" alert.
    private var splitLayer: some View {
        @Bindable var model = model
        return NavigationSplitView(columnVisibility: columnVisibility) {
            // Inject the window's observable environment INSIDE each column, not as a
            // modifier on the whole split view. `NavigationSplitView` hosts its columns
            // in separate UIKit containers; the app-switcher snapshot re-lays those
            // column hosts out under an override orientation, and an `.environment`
            // applied outside the split view isn't yet bridged into them at that point,
            // so an `@Environment(Observable.self)` read force-unwraps nil and traps
            // (C1: EXC_BREAKPOINT in EnvironmentBox.update during the snapshot rotation).
            // Each column carrying its own copy keeps the reads valid through that pass.
            withLibraryEnvironment {
                LibrarySidebar(selection: selectionBinding, isCompact: isCompactWindow)
                    #if os(iOS)
                    // Compact width collapses the split view to this stack; push the
                    // viewer explicitly when the grid sets a selection. Inert at
                    // regular width, where the detail column shows instead. The pushed
                    // viewer renders the model's shared session, not one of its own.
                    .navigationDestination(item: selectionBinding) { id in
                        withLibraryEnvironment {
                            if let session = model.session, session.entryID == id {
                                ViewerDetail(session: session, onRemove: { model.select(nil) })
                                    .id(id)
                            } else {
                                Color.clear
                            }
                        }
                    }
                    #endif
            }
        } detail: {
            withLibraryEnvironment { detailColumn }
        }
        .environment(toastCenter)
        .environment(removal)
        .toastOverlay(toastCenter)
        .recentsRemoval(removal, store: store, toast: toastCenter)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: MetafileTypes.readableContentTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { if let id = await store.handleOpenedURL(url) { model.select(id) } }
            }
        }
        // Host the "couldn't open" alert at the window (C4a M5): visible with the
        // sidebar collapsed or a compact viewer pushed, and — on macOS — only in the
        // key window, so several windows don't each raise it.
        .alert(
            "Couldn’t open file",
            isPresented: Binding(
                get: { store.lastErrorMessage != nil && errorAlertAllowed },
                set: { if !$0 { store.lastErrorMessage = nil } }
            ),
            presenting: store.lastErrorMessage
        ) { _ in
            Button("OK", role: .cancel) { store.lastErrorMessage = nil }
        } message: { message in
            Text(message)
        }
        .task {
            // Teach the model how to build a session for an entry, seeding each with the
            // current Rendering options so the opening render honours them (S1b). Set before
            // any selection can commit, since the model now owns the session (L4/N1).
            model.sessionFactory = { id in DocumentSession(entryID: id, store: store, options: settings.renderOptions) }
            // Guard a Remove of the open, dirty editing document so its unsaved edits aren't
            // thrown away (R2U3): the removal surface awaits this before it removes.
            removal.removalGuard = { [model] id in await model.guardRemoval(of: id) }
            // Guard a bulk Clear Recents the same way, so the open, dirty editing document's edits
            // aren't thrown away by a clear (item 0 / R2U3).
            removal.clearGuard = { [model] in await model.guardClear() }
            await store.loadIfNeeded()
            // Sync the settings-driven cap and Private mode into the store before the
            // first open can add anything (S1a-5).
            store.capLimit = settings.recentsToKeep.count
            store.setPrivate(settings.privateMode)
            // Index the recents already on disk, once per launch, throttled (F3d).
            SpotlightService.shared.syncOnLaunch()
            // Generate AI title/tags for recents lacking them, one at a time in the
            // background (A1b). Self-gates on the AI toggle, Private mode and availability.
            DrawingTitleTagService.shared.syncOnLaunch()
            #if DEBUG
            // UI-test seeding (DEBUG only): SIMCTL_CHILD_EMFY_SEED_RECEIVED=<n>.
            if let raw = ProcessInfo.processInfo.environment["EMFY_SEED_RECEIVED"], let n = Int(raw), n > 0 {
                await store.seedReceivedForUITesting(count: n)
            }
            // Seed specific host files as received entries (DEBUG only):
            // SIMCTL_CHILD_EMFY_SEED_FILES=<path1:path2:…> — used for screenshots.
            if let files = ProcessInfo.processInfo.environment["EMFY_SEED_FILES"], !files.isEmpty {
                await store.seedReceivedFilesForUITesting(paths: files.split(separator: ":").map(String.init))
            }
            // E2b screenshot hook: -EmfyDebugOpen opens a file into this window; the
            // viewer then reads -EmfyDebugEdit / -EmfyDebugSelect to enter edit mode
            // with a selection (design call E2b-8).
            // Always open a temp-dir COPY, never the tracked file in place (an armed
            // autosave must never be able to write into corpus/). A scripted gate flow
            // (E2d) opens its own temp copy directly, so a second launch can re-open the
            // edited file; both paths refuse anything under corpus/.
            // A scripted gate flow always opens its own script file (overriding any
            // restored selection, whose stale bookmark could otherwise hang the run);
            // the plain -EmfyDebugOpen path only fills an empty window.
            if let path = EditorDebugLaunch.scriptOpenPath() {
                if let id = await store.handleOpenedURL(URL(fileURLWithPath: path)) { model.select(id) }
            } else if model.selection == nil, let path = EditorDebugLaunch.safeCopiedOpenPath() ?? EditorDebugLaunch.pictureFixturePath() {
                if let id = await store.handleOpenedURL(URL(fileURLWithPath: path)) { model.select(id) }
            }
            #endif
            applyInitialSelection()
            #if os(iOS)
            // One scene, once per version, once per launch (C3b scope 7), gated by the
            // "Show What's New after updates" setting (S1a-5). Suppressed during a DEBUG
            // screenshot run so it never covers the captured edit mode.
            var allowWhatsNew = true
            #if DEBUG
            if EditorDebugLaunch.isActive { allowWhatsNew = false }
            // C5a screenshot: force the sheet for a deterministic Simulator capture.
            if EditorDebugLaunch.whatsNewSheet { showLaunchWhatsNew = true }
            #endif
            if allowWhatsNew, WhatsNewPresenter.claimLaunchPresentation(enabled: settings.showWhatsNewAfterUpdates) {
                showLaunchWhatsNew = true
            }
            #endif
        }
    }

    /// The DEBUG screenshot hooks and (DMG) updater surfaces layered over `splitLayer`.
    private var debugLayer: some View {
        splitLayer
        #if DEBUG && os(macOS)
        // E3a screenshot (a): open the New Drawing sheet at launch and capture the SHEET
        // itself via its layer tree (not captureAllWindows, which composites the parent
        // window behind it), then quit.
        .task {
            guard EditorDebugLaunch.newDrawingSheet, let base = EditorDebugLaunch.screenshotBase else { return }
            try? await Task.sleep(for: .milliseconds(700))
            showNewDrawing = true
            try? await Task.sleep(for: .milliseconds(1400))
            _ = EditorDebugScreenshot.captureAttachedSheetView(to: base + "-a-new-drawing.png")
            try? await Task.sleep(for: .milliseconds(200))
            exit(0)
        }
        // F1 screenshots (b)/(c): present the Batch Convert sheet at launch; the sheet's
        // own task pre-fills, (optionally) runs, captures and quits.
        .task {
            guard EditorDebugLaunch.batchSheet else { return }
            try? await Task.sleep(for: .milliseconds(700))
            showBatchConvert = true
        }
        // F1 correction 1 proof: count the ⌘C menu items (must be exactly 1), write it
        // next to the shots, then quit.
        .task {
            if EditorDebugLaunch.menuAudit, let base = EditorDebugLaunch.screenshotBase {
                try? await Task.sleep(for: .milliseconds(1200))
                let count = EditorDebugScreenshot.commandCItemCount()
                try? "command-C menu items: \(count)\n".write(toFile: base + "-menu-audit.txt", atomically: true, encoding: .utf8)
                try? await Task.sleep(for: .milliseconds(150))
                exit(0)
            }
            // F3c screenshot (f): the "Recognise text in pictures" toggle, hosted and captured
            // in an offscreen window (no Screen Recording needed). Folded into this existing
            // `.task` so the already-large body gains no modifier and stays type-checkable.
            if EditorDebugLaunch.settingsScene == "viewer", let base = EditorDebugLaunch.screenshotBase {
                try? await Task.sleep(for: .milliseconds(900))
                _ = SettingsSceneScreenshot.captureViewerTab(settings: settings, to: base + "-f-settings-toggle.png")
                try? await Task.sleep(for: .milliseconds(200))
                exit(0)
            }
            // F3d screenshot (i): the "Show drawings in Spotlight" toggle on the General tab,
            // captured offscreen in-process.
            if EditorDebugLaunch.settingsScene == "general", let base = EditorDebugLaunch.screenshotBase {
                try? await Task.sleep(for: .milliseconds(900))
                _ = SettingsSceneScreenshot.captureGeneralTab(store: store, settings: settings, to: base + "-i-spotlight-toggle.png")
                try? await Task.sleep(for: .milliseconds(200))
                exit(0)
            }
            // C5a screenshot: the What's New view (the 3.0 release notes), hosted offscreen
            // and captured in-process.
            if EditorDebugLaunch.settingsScene == "whatsnew", let base = EditorDebugLaunch.screenshotBase {
                try? await Task.sleep(for: .milliseconds(900))
                _ = SettingsSceneScreenshot.captureWhatsNew(to: base + "-whats-new.png")
                try? await Task.sleep(for: .milliseconds(200))
                exit(0)
            }
        }
        // F3d: the Translate-menu stand-in (screenshot g).
        .task { await SpotlightDebug.runTranslateMenuIfRequested() }
        #endif
        #if DEBUG
        // F3d: the real Core Spotlight round-trip (index + CSSearchQuery), cross-platform so
        // it can run where the index is reachable (the iOS Simulator); logs the hit count then
        // quits.
        .task { await SpotlightCheck.runIfRequested(settings: settings) }
        #endif
        #if DEBUG && os(macOS) && EMFY_DMG
        // U1 updater screenshots (first-launch sheet / Settings ▸ Updates), extracted
        // to a modifier to keep this body type-checkable.
        .modifier(UpdatesScreenshotModifier())
        // A3a screenshot: the MCP-server settings group, hosted offscreen and captured
        // in-process (DMG build only, where the group exists).
        .task {
            if EditorDebugLaunch.settingsScene == "mcp", let base = EditorDebugLaunch.screenshotBase {
                try? await Task.sleep(for: .milliseconds(900))
                // A throwaway settings seeded with the enable toggle on and two example
                // approved folders, so the S9 folder control is visible in the shot.
                let suite = UserDefaults(suiteName: "emfy.screenshot.mcp") ?? .standard
                for key in suite.dictionaryRepresentation().keys { suite.removeObject(forKey: key) }
                let shot = EmfySettings(defaults: suite, sharedDefaults: suite)
                shot.mcpServerEnabled = true
                shot.mcpAllowedFolders = [NSHomeDirectory() + "/Documents", NSHomeDirectory() + "/Desktop"]
                _ = SettingsSceneScreenshot.captureMCPTab(settings: shot, to: base + "-mcp-settings.png")
                try? await Task.sleep(for: .milliseconds(200))
                exit(0)
            }
        }
        #endif
        #if DEBUG && os(iOS)
        // E3a screenshot (e): present the New Drawing sheet at launch for a simulator
        // capture (the run stays alive; `simctl io screenshot` grabs it).
        .task {
            guard EditorDebugLaunch.newDrawingSheet else { return }
            try? await Task.sleep(for: .milliseconds(900))
            showNewDrawing = true
        }
        // R3: the live-resize refit profile harness (prints a summary and exits).
        .task { ZoomableMetafileView.runRefitProfileIfRequested() }
        #endif
    }

    /// The window's state reactions: selection reconciliation, external opens, the focused
    /// actions and sheets, layered over `debugLayer`.
    private var reactionsLayer: some View {
        debugLayer
        .onAppear { toastCenter.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, newValue in toastCenter.reduceMotion = newValue }
        // Reconcile selection when the shown entry is removed — here or in another
        // window, via Clear Recents or a prune — so the viewer never orphans (C4a H8).
        .onChange(of: store.entries) { _, _ in
            if let id = model.selection, store.entry(id: id) == nil {
                // The shown entry was removed (here, in another window, Clear Recents, or a
                // prune). If it's the open, dirty editing document its file may still exist, so
                // flush its edits to disk before tearing down rather than silently discarding
                // them (R2U3); otherwise the file is gone, so clear without the guard (C4a H8).
                if model.session?.editing == .editing, model.session?.isDirty == true {
                    model.handleSelectedEntryRemoved()
                } else {
                    model.clearSelection()
                }
            }
        }
        .onChange(of: model.selection) { _, id in
            // Never persist the selection of a session-private entry into scene
            // restoration, so a Private-mode file isn't re-selected on relaunch (S-L3).
            if let id, store.isSessionPrivate(id) {
                storedSelection = nil
            } else {
                storedSelection = id?.uuidString
            }
        }
        // Keep the store's Private mode in step with the setting (S1a-5): turning it
        // off drops this launch's Private entries; the persisted history is untouched.
        .onChange(of: settings.privateMode) { _, on in
            store.setPrivate(on)
        }
        // External opens (Finder, Files, Mail, Messages) land in the front window.
        // SwiftUI spawns a window for the file event and delivers the URL here; on
        // macOS, if another window already exists this is a duplicate — route the
        // file into the existing front window and close this one; otherwise (a cold
        // launch) show it here. iOS shows it in this active scene (v3-plan §9.1).
        .onOpenURL { url in
            Task { await openExternal(url) }
        }
        // Opening a Spotlight result (F3d): select the matching recents entry in this window;
        // an unknown or removed id is ignored. The store is loaded first, so a cold-launch
        // tap resolves the entry.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = CoreSpotlightActivity.entryID(from: activity) else { return }
            Task {
                await store.loadIfNeeded()
                if store.entry(id: id) != nil {
                    model.select(id)
                } else {
                    // The Spotlight index still held an entry that's been removed from Recents
                    // (C5e U6): tell the user instead of doing nothing.
                    toastCenter.show("That drawing is no longer in Recents", systemImage: "clock.badge.xmark")
                }
            }
        }
        // New Drawing (E3a): the Mac File menu fires this focused action; every window
        // publishes it so ⌘N works even in an empty window.
        .focusedSceneValue(\.newDrawingAction, NewDrawingCommand(present: { showNewDrawing = true }))
        .sheet(isPresented: $showNewDrawing) {
            NewDrawingSheet { preset in
                Task {
                    if let id = await NewDrawing.create(preset, in: store) {
                        model.select(id)
                    }
                }
            }
        }
        // New Drawing from Description (X2d): the Mac File menu fires this focused action,
        // published only when an AI engine is available; the sheet opens the generated
        // drawing as a new, unsaved document on Create.
        .focusedSceneValue(\.generateDrawingAction, generateDrawingAvailable
            ? NewDrawingCommand(present: { showGenerateDrawing = true }) : nil)
        .sheet(isPresented: $showGenerateDrawing) {
            GenerateDrawingSheet { data in
                Task {
                    if let id = await NewDrawing.create(data: data, in: store) {
                        model.select(id)
                    }
                }
            }
        }
        #if os(macOS)
        // Batch Convert (F1): the Mac File menu fires this focused action; every window
        // publishes it, and hosts its own sheet.
        .focusedSceneValue(\.batchConvertAction, BatchConvertCommand(present: { showBatchConvert = true }))
        .sheet(isPresented: $showBatchConvert) {
            MacBatchConvertSheet()
        }
        #endif
        #if os(iOS)
        // A window opened by "Open in New Window" (UIWindowScene.ActivationAction)
        // carries the entry to show in its user activity (v3-plan §9.1).
        .onContinueUserActivity(WindowOpenActivity.type) { activity in
            if let id = WindowOpenActivity.entryID(from: activity), store.entry(id: id) != nil {
                model.select(id)
            }
        }
        .sheet(isPresented: $showLaunchWhatsNew) {
            InfoSheet(title: "What's New") { WhatsNewView() }
        }
        #endif
        #if os(macOS)
        .onAppear {
            // The coordinator's stored selector holds `model` strongly, matching this
            // closure's own capture. It is released on `onDisappear` via `unregister`,
            // and `model` never references the coordinator, so there is no cycle.
            coordinator.register(windowID: model.windowID) { entryID in
                model.select(entryID)
            }
            // The app-global Clear Menu / Settings Clear Recents run the front window's save
            // guard before clearing, so a clear can't throw away an open, dirty WMF's edits
            // (item 0 / R2U3).
            coordinator.setClearGuard(windowID: model.windowID) { [model] in await model.guardClear() }
        }
        .onDisappear {
            coordinator.unregister(windowID: model.windowID)
        }
        .background(
            WindowFrontReporter { isKey in
                isKeyWindow = isKey
                if isKey { coordinator.markFront(windowID: model.windowID) }
            }
        )
        #endif
        #if os(iOS)
        // A small resize floor on iPad (the compact layout's size), so a window can't
        // shrink below where the UI works yet still allows the iPadOS 26 half-width and
        // portrait halves (audit L-A). iPad-only; never constrains iPhone.
        .background(SceneMinimumSize(minimumSize: CGSize(width: 320, height: 400)))
        #endif
    }

    /// Re-injects every observable the window's columns, pushed viewers and sheets
    /// read, so each separately-hosted `NavigationSplitView` column (and the compact
    /// pushed viewer) carries its own copy rather than relying on an injection made
    /// outside the split view surviving the snapshot re-layout (C1).
    @ViewBuilder
    private func withLibraryEnvironment<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .environment(store)
            .environment(coordinator)
            .environment(settings)
            .environment(toastCenter)
            .environment(removal)
            // The AI provider store is read as a non-optional @Environment by the AI
            // settings and inspector views; inject it on every column/pushed-viewer path
            // too (falling back to the shared instance) so a read can't trap (U3).
            .environment(aiProviders ?? AIProviderStore.shared)
    }

    // MARK: - Detail column

    /// Whether this window is compact (iPhone, narrow). The window-level size class
    /// is the right signal for sidebar and detail layout — a split view's sidebar
    /// column reports compact even on a regular-width iPad.
    private var isCompactWindow: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    @ViewBuilder
    private var detailColumn: some View {
        // At compact width the viewer is pushed by the sidebar's
        // navigationDestination, so the detail column stays empty — only one
        // DocumentSession ever exists.
        if isCompactWindow {
            Color.clear
        } else {
            regularDetail
        }
    }

    @ViewBuilder
    private var regularDetail: some View {
        if let id = model.selection, let session = model.session, session.entryID == id {
            ViewerDetail(session: session, onRemove: { model.select(nil) })
                .id(id)
        } else {
            // "No File Selected" now carries an Open… action, so the invitation to
            // "open one" is actionable (C4a L1).
            ContentUnavailableView {
                Label("No File Selected", systemImage: "doc.richtext")
            } description: {
                Text("Choose a file from the sidebar, or open one.")
            } actions: {
                Button("Open…") { isImporting = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Whether this window may raise the "couldn't open" alert: only the key window
    /// on macOS, always on iOS (one active scene) — so several windows don't each
    /// show it and a windowless open still surfaces one (C4a M5).
    private var errorAlertAllowed: Bool {
        #if os(macOS)
        isKeyWindow
        #else
        true
        #endif
    }

    // MARK: - Selection restoration

    /// Honours a window opened on a specific entry, else restores the window's last
    /// selection — each only when the entry still exists.
    private func applyInitialSelection() {
        let storedID = storedSelection.flatMap { UUID(uuidString: $0) }
        // "Reopen last file at launch" off starts the window empty unless a specific
        // entry was requested (Open in New Window), which is always honoured (S1a-5).
        guard let id = LaunchSelection.restored(
            reopenLastFile: settings.reopenLastFileAtLaunch,
            requested: initialSelection,
            stored: storedID
        ), store.entry(id: id) != nil else { return }
        model.select(id)
    }

    /// A binding over the scene-stored column visibility, mapping the persisted string
    /// to `NavigationSplitViewVisibility` (which isn't `RawRepresentable`) (N2).
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                switch columnVisibilityRaw {
                case "all": return .all
                case "doubleColumn": return .doubleColumn
                case "detailOnly": return .detailOnly
                default: return .automatic
                }
            },
            set: { newValue in
                if newValue == .all { columnVisibilityRaw = "all" }
                else if newValue == .doubleColumn { columnVisibilityRaw = "doubleColumn" }
                else if newValue == .detailOnly { columnVisibilityRaw = "detailOnly" }
                else { columnVisibilityRaw = "automatic" }
            }
        )
    }

    /// A guarded two-way binding over the model's selection: reads the committed value and
    /// routes every write (sidebar tap, grid tap, iOS back) through the save guard. When a
    /// switch is blocked or cancelled the committed value is unchanged, so the sidebar's
    /// highlight (and the compact push) reconcile back to the current document (U1).
    private var selectionBinding: Binding<UUID?> {
        // Read the OPTIMISTIC selection so a list tap / system Back reflects at once and doesn't
        // flicker or re-push while the guarded commit runs; a held or cancelled switch rolls it
        // back to the committed selection (A-B/R2N1).
        Binding(get: { model.displayedSelection }, set: { model.select($0) })
    }

    /// Imports a file arriving from Finder / Files / Mail / Messages and shows it per
    /// the "Open files in" setting (S1a-4c). `handlesExternalEvents(preferring:allowing:)`
    /// delivers the open to the front window (macOS) or the active scene (iOS); in
    /// front-window mode this selects it here, and in new-window mode it opens a
    /// value-keyed library window, which SwiftUI brings forward if one already shows
    /// the file (the dedup). The setting is honoured only where a second window can
    /// exist (Mac, iPad); on the iPhone it's hidden and an external open fills the
    /// front window. An empty front window is always filled, so a cold-launch open
    /// never strands the window SwiftUI spawned for it.
    private func openExternal(_ url: URL) async {
        await store.loadIfNeeded()
        // Capture this (front) window's emptiness before the import, so a
        // cold-launch open fills the spawned empty window instead of spawning beside it.
        let frontWindowIsEmpty = model.selection == nil
        guard let id = await store.handleOpenedURL(url) else { return }
        let destination = OpenRouting.externalDestination(
            openInNewWindow: settings.openFilesIn == .newWindow,
            hasOpenWindow: true,
            frontWindowIsEmpty: frontWindowIsEmpty,
            // The front window already showing this file keeps it — no duplicate
            // window when the same file is reopened (S1a-5 carry-over).
            frontWindowShowsFile: model.selection == id,
            supportsMultipleWindows: supportsMultipleWindows
        )
        switch destination {
        case .frontWindow:
            if model.selection != id { model.select(id) }
        case .newWindow:
            #if os(iOS)
            activateNewWindow(for: id)
            #else
            openWindow(id: "library", value: LibraryWindowValue(entryID: id))
            #endif
        }
    }

    #if os(iOS)
    /// Opens a new window for `id` through the scene-activation API so a failure falls
    /// back to the front window instead of silently dropping the open. The iPhone Duo
    /// outer display can't create a second window — and `supportsMultipleWindows` is
    /// true on BOTH Duo displays, so it can't tell them apart (Axiom resize-auditor §15)
    /// — so the request's error handler is the only reliable fallback (R1). iOS 17+. The
    /// carried user activity shows the entry in the new window (handled by
    /// `.onContinueUserActivity` above).
    private func activateNewWindow(for id: UUID) {
        var request = UISceneSessionActivationRequest(role: .windowApplication)
        request.userActivity = WindowOpenActivity.make(id)
        UIApplication.shared.activateSceneSession(for: request) { _ in
            Task { @MainActor in if model.selection != id { model.select(id) } }
        }
    }
    #endif
}

/// The detail: the platform viewer over a `DocumentSession` the window model owns and
/// loads (L4/N1). It no longer creates or loads the session itself — owning it above the
/// size-class branch means the compact `navigationDestination` push and the regular detail
/// column share one instance, so an iPad width change keeps its edit mode, undo stack and
/// load (v3-plan §11.2).
struct ViewerDetail: View {
    let session: DocumentSession
    /// Leaves the document (iOS back / removed from Recents), guarded by the window model.
    let onRemove: () -> Void

    var body: some View {
        #if os(macOS)
        MacViewerPane(session: session, onRemove: onRemove)
        #else
        MetafileViewerScreen(session: session, onRemove: onRemove, onBack: onRemove)
        #endif
    }
}
