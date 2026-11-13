import CoreGraphics
import EMFEdit
import Foundation
import Observation

// MARK: - The accessibility "Check" view-model (X1a)
//
// Drives the Check inspector segment: it runs the deterministic `DrawingAnalysis`
// off-main over the CURRENT scene (the edited scene while editing, else a scene
// imported from the open drawing's bytes), caches the result by content id / edit
// version, exposes the content report and findings for the panel, outlines a
// selected finding's elements on the canvas, and owns the fix flow — plan → preview →
// confirm → re-analyse. Every fix is applied ONLY through `DocumentSession` (one undo
// each, "fix all" as one group), never by mutating a scene directly, and never without
// the user confirming the preview first (CLAUDE.md security: no action without
// confirmation).
//
// The model imports EMFEdit; the EMFEdit-free Mac/iOS panes host it and read only its
// app-typed outputs (the report/findings are rendered by the EMFEdit-importing
// `DrawingCheckView`, and the highlight is a plain `FindHighlightSet`).

@MainActor
@Observable
final class DrawingCheckModel {

    /// The cache identity for an analysis: editing uses the edit version (so each edit
    /// re-analyses), read-only uses the drawing's content id (so a reload re-analyses,
    /// an identical reload doesn't). Pure, for the cache-key test.
    struct CacheKey: Equatable, Sendable {
        var editing: Bool
        var version: Int
    }

    nonisolated static func cacheKey(editing: Bool, editVersion: Int, contentID: Int) -> CacheKey {
        CacheKey(editing: editing, version: editing ? editVersion : contentID)
    }

    /// A planned, previewed fix awaiting the user's confirm. A fix is NEVER applied
    /// without one of these being presented and confirmed first.
    struct PendingFix: Identifiable {
        let id = UUID()
        enum Content {
            /// A single fix: before/after crops of the affected region plus an action title.
            case single(before: CGImage, after: CGImage, actionTitle: String)
            /// "Fix all of this kind": the count to confirm plus an action title.
            case all(count: Int, actionTitle: String)
        }
        var findingID: Int
        var content: Content
        /// The commands to apply on confirm (one for single, many for all).
        var commands: [SceneCommand]
        /// Whether to apply as one grouped undo ("fix all") or a single undo.
        var grouped: Bool
        var actionName: SceneActionName
    }

    // MARK: Published state

    private(set) var analysis: DrawingAnalysis?
    private(set) var isAnalysing = false
    /// Whether a fix preview is being rendered (off-main), so the UI can show a spinner.
    private(set) var isPreparingFix = false
    /// The previewed fix awaiting confirm; the view presents the preview sheet while set.
    var pendingFix: PendingFix?
    /// The selected finding, outlined on the canvas and showing its fix control.
    var selectedFindingID: Int?

    /// A stable key for the current analysis, so the AI summary resets when it changes.
    var analysisVersion: Int {
        guard let currentKey else { return 0 }
        return (currentKey.version << 1) | (currentKey.editing ? 1 : 0)
    }

    var report: ContentReport? { analysis?.report }
    var findings: [Finding] { analysis?.findings ?? [] }
    /// The analysis data block for the AI summary (counts + findings, no raw drawing text).
    var summaryData: String? { analysis?.summaryData() }

    /// The full Markdown report for export, as a plain `String` so the EMFEdit-free host
    /// panes can save/share it without importing EMFEdit.
    func markdownReport(title: String) -> String? { analysis?.markdownReport(title: title) }

    // MARK: Wiring (set by the host each refresh)

    @ObservationIgnored private weak var session: DocumentSession?
    @ObservationIgnored private var dataProvider: (@Sendable () async -> Data?)?
    @ObservationIgnored private var contentID = 0

    @ObservationIgnored private var currentKey: CacheKey?
    @ObservationIgnored private var scene: Scene?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var fixTask: Task<Void, Never>?

    // MARK: Lifecycle

    /// Points the model at the open drawing. Cheap; called from the host's `onAppear`
    /// and `onChange`. Does not itself re-analyse — `refreshIfNeeded` decides that.
    func configure(session: DocumentSession, dataProvider: @escaping @Sendable () async -> Data?, contentID: Int) {
        self.session = session
        self.dataProvider = dataProvider
        self.contentID = contentID
    }

    /// Runs the analysis when the cache key has changed (new drawing, reload, or edit),
    /// else does nothing.
    func refreshIfNeeded() {
        guard let session else { return }
        let editing = session.editing == .editing
        let key = Self.cacheKey(editing: editing, editVersion: session.editVersion, contentID: contentID)
        guard key != currentKey else { return }
        runAnalysis(key: key, editing: editing)
    }

    /// Forces a re-analysis after a fix is applied (the edit version moved, but the host
    /// may not have driven `refreshIfNeeded` yet).
    private func forceRefresh() {
        currentKey = nil
        refreshIfNeeded()
    }

    private func runAnalysis(key: CacheKey, editing: Bool) {
        currentKey = key
        analysisTask?.cancel()
        isAnalysing = true
        if editing, let editingScene = session?.editingScene {
            analyse(scene: editingScene)
        } else if let dataProvider {
            analysisTask = Task { [weak self] in
                let data = await dataProvider()
                let scene = data.flatMap { try? SceneImporter.import(data: $0) }
                guard let self, !Task.isCancelled else { return }
                guard let scene else { self.finishEmpty(); return }
                await self.analyseResolved(scene: scene)
            }
        } else {
            finishEmpty()
        }
    }

    private func analyse(scene: Scene) {
        analysisTask = Task { [weak self] in
            await self?.analyseResolved(scene: scene)
        }
    }

    private func analyseResolved(scene: Scene) async {
        let result = await Task.detached(priority: .userInitiated) { DrawingAnalysis(scene: scene) }.value
        guard !Task.isCancelled else { return }
        self.scene = scene
        analysis = result
        isAnalysing = false
        pruneSelection()
    }

    private func finishEmpty() {
        scene = nil
        analysis = nil
        isAnalysing = false
        selectedFindingID = nil
    }

    /// Drops a selection that no longer names a current finding (e.g. after a fix).
    private func pruneSelection() {
        if let id = selectedFindingID, !findings.contains(where: { $0.id == id }) {
            selectedFindingID = nil
        }
    }

    // MARK: Compare (X1b item 1)

    /// The current drawing as a scene, for Compare: the edited scene while editing, else
    /// the scene imported from the open bytes (the one the check analysed). Imports off
    /// the main actor when no analysed scene is available yet.
    func currentSceneForCompare() async -> Scene? {
        if let session, session.editing == .editing, let editingScene = session.editingScene {
            return editingScene
        }
        if let scene { return scene }
        guard let dataProvider, let data = await dataProvider() else { return nil }
        return try? await Task.detached(priority: .userInitiated) { try SceneImporter.import(data: data) }.value
    }

    /// Whether the drawing can be compared against the version it was opened at (a Mac
    /// revert snapshot exists for this document).
    var canCompareWithOpenedVersion: Bool {
        session?.canRevertToOpenedVersion ?? false
    }

    /// The opened-version snapshot bytes, when one exists, for the "Compare with opened
    /// version" action.
    func openedVersionBaselineData() -> Data? {
        session?.openedVersionSnapshotData()
    }

    // MARK: Clean-up (X1b item 2)

    /// The open drawing's bytes, for the clean-up & compatibility report.
    func cleanupData() async -> Data? { await dataProvider?() }

    /// A suggested base file name for a saved copy.
    var documentFileName: String { session?.currentDocumentFileName() ?? "Drawing.emf" }

    /// Whether the document has unsaved edits — clean-up works on the saved file, so the
    /// save actions are gated while this is true.
    var hasUnsavedChanges: Bool { session?.isDirty ?? false }

    // MARK: Canvas highlight

    /// The outline for the selected finding's elements, in device space, reusing the
    /// viewer's find-highlight overlay style. `.empty` when nothing is selected.
    var highlight: FindHighlightSet {
        guard let id = selectedFindingID, let scene,
              let finding = findings.first(where: { $0.id == id }) else { return .empty }
        let rects = finding.elementIDs
            .compactMap { eid in scene.elements.first { $0.id == eid }?.selectionBoundsDevice }
            .filter { !$0.isNull }
        guard !rects.isEmpty else { return .empty }
        return FindHighlightSet(
            pageBoundsDevice: scene.pageBoundsDevice,
            matchDeviceRects: rects,
            currentDeviceRect: rects.first)
    }

    func select(findingID: Int?) {
        selectedFindingID = findingID
    }

    // MARK: Fix flow

    /// Whether a one-tap fix exists for a finding (so the row shows a Fix control).
    func plannedFix(for findingID: Int) -> PlannedFix? {
        guard let scene, let finding = findings.first(where: { $0.id == findingID }) else { return nil }
        return DrawingFixPlanner.plan(for: finding, in: scene)
    }

    /// How many findings of the same kind as `findingID` have an applicable fix (for the
    /// "Fix all of this kind" count). 0 or 1 hide the "fix all" control.
    func fixAllCount(for findingID: Int) -> Int {
        guard let scene, let finding = findings.first(where: { $0.id == findingID }) else { return 0 }
        return DrawingFixPlanner.planAll(like: finding, findings: findings, in: scene).count
    }

    /// Builds the before/after preview for a single fix (off-main) and presents it. The
    /// fix is applied only when the user confirms the preview.
    func beginFix(findingID: Int) {
        guard let scene, let fix = plannedFix(for: findingID) else { return }
        fixTask?.cancel()
        isPreparingFix = true
        let title = Self.actionTitle(for: fix.kind)
        fixTask = Task { [weak self] in
            let crops = await Task.detached(priority: .userInitiated) {
                Self.renderCrops(scene: scene, command: fix.command, elementID: fix.elementID)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.isPreparingFix = false
            guard let crops else { return }
            self.pendingFix = PendingFix(
                findingID: findingID,
                content: .single(before: crops.before, after: crops.after, actionTitle: title),
                commands: [fix.command],
                grouped: false,
                actionName: fix.command.actionName)
        }
    }

    /// Presents a confirm for fixing every finding of the same kind as `findingID`, as
    /// one grouped undo. No crops — just the count to confirm.
    func beginFixAll(findingID: Int) {
        guard let scene, let finding = findings.first(where: { $0.id == findingID }) else { return }
        let plans = DrawingFixPlanner.planAll(like: finding, findings: findings, in: scene)
        guard !plans.isEmpty else { return }
        pendingFix = PendingFix(
            findingID: findingID,
            content: .all(count: plans.count, actionTitle: Self.fixAllTitle(for: finding.kind)),
            commands: plans.map(\.command),
            grouped: true,
            actionName: DrawingFixPlanner.fixAllActionName)
    }

    /// Dismisses the preview without applying.
    func cancelPendingFix() {
        pendingFix = nil
    }

    /// Applies the confirmed fix through `DocumentSession` (entering edit mode first if
    /// read-only), then re-analyses. A no-op when nothing is pending — so a fix is never
    /// applied without a presented, confirmed preview.
    func confirmPendingFix() async {
        guard let pending = pendingFix, let session else { pendingFix = nil; return }
        pendingFix = nil
        if session.editing != .editing {
            await session.beginEditing()
        }
        guard session.editing == .editing else { return }
        if pending.grouped {
            session.applyGroupedCommands(pending.commands, name: pending.actionName)
        } else if let command = pending.commands.first {
            session.apply(command)
        }
        selectedFindingID = nil
        forceRefresh()
    }

    // MARK: Rendering

    /// A before/after crop pair for a single fix. `@unchecked Sendable`: `CGImage` is an
    /// immutable value handed across the detached render boundary.
    private struct RenderedCrops: @unchecked Sendable {
        let before: CGImage
        let after: CGImage
    }

    /// Renders the affected region of `scene` before and after `command`, cropped to the
    /// same device rect so the two line up. Pure, so it runs off the main actor.
    nonisolated private static func renderCrops(scene: Scene, command: SceneCommand, elementID: Int) -> RenderedCrops? {
        var history = SceneHistory(scene: scene)
        try? history.apply(command)
        let afterScene = history.scene

        let beforeBounds = bounds(of: elementID, in: scene)
        let afterBounds = bounds(of: elementID, in: afterScene)
        var region = beforeBounds.isNull ? afterBounds : (afterBounds.isNull ? beforeBounds : beforeBounds.union(afterBounds))
        if region.isNull || region.width <= 0 || region.height <= 0 {
            region = scene.pageBoundsDevice   // fall back to the whole page
        }
        let pad = max(region.width, region.height) * 0.6 + 8
        region = region.insetBy(dx: -pad, dy: -pad).intersection(scene.pageBoundsDevice)
        guard let before = renderCrop(scene: scene, region: region),
              let after = renderCrop(scene: afterScene, region: region) else { return nil }
        return RenderedCrops(before: before, after: after)
    }

    nonisolated private static func bounds(of elementID: Int, in scene: Scene) -> CGRect {
        scene.elements.first { $0.id == elementID }?.selectionBoundsDevice ?? .null
    }

    nonisolated private static func renderCrop(scene: Scene, region: CGRect) -> CGImage? {
        guard let full = SceneRenderer.makeImage(scene, scale: 3),
              scene.pageSizeDevice.width > 0, scene.pageSizeDevice.height > 0 else { return nil }
        let ratioX = CGFloat(full.width) / scene.pageSizeDevice.width
        let ratioY = CGFloat(full.height) / scene.pageSizeDevice.height
        let originX = region.minX - scene.pageBoundsDevice.minX
        let originY = region.minY - scene.pageBoundsDevice.minY
        var px = CGRect(x: originX * ratioX, y: originY * ratioY,
                        width: region.width * ratioX, height: region.height * ratioY).integral
        px = px.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard px.width >= 1, px.height >= 1 else { return full }
        return full.cropping(to: px) ?? full
    }

    // MARK: Display text (the model names no display strings in EMFEdit)

    static func actionTitle(for kind: DrawingFixKind) -> String {
        switch kind {
        case .darkenText: return "Darken text"
        case .lightenText: return "Lighten text"
        case .enlargeText: return "Enlarge text"
        case .adjustColor: return "Adjust colour"
        }
    }

    static func fixAllTitle(for kind: Finding.Kind) -> String {
        switch kind {
        case .lowContrast: return "Fix all low-contrast text"
        case .tinyText: return "Enlarge all tiny text"
        case .colorPair: return "Separate all colour-only pairs"
        case .unlabelledImage: return "Fix all"
        }
    }
}
