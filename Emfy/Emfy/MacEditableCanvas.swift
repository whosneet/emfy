import AppKit
import CoreGraphics
import EMFEdit
import EMFRender
import Foundation
import os
import SwiftUI
import UniformTypeIdentifiers

/// The macOS edit-mode detail content. It reads the editing `Scene` from the session
/// (keyed on `editVersion` so each mutation re-pushes it) and hosts the interactive
/// canvas. Kept here — not in `MacViewerPane` — so the pane never imports EMFEdit
/// (whose `ExportFormat` would clash with the app's own).
struct MacEditingContainer: View {
    let session: DocumentSession
    let editorModel: EditorModel
    let controller: MacMetafileZoomController
    var pageShadow: Bool = true
    var tilePaint: TilePaint = .plain
    var options: RenderOptions = .default
    var findHighlights: FindHighlightSet = .empty

    var body: some View {
        @Bindable var editorModel = editorModel
        let _ = session.editVersion
        Group {
            if let scene = session.editingScene {
                MacEditableCanvas(
                    scene: scene, editorModel: editorModel, editVersion: session.editVersion, controller: controller,
                    // Reading the armed tools here makes the container observe them, so the
                    // canvas's cursor refreshes the moment a shape or pen is armed/disarmed.
                    armedTool: editorModel.armedShapeTool,
                    armedPen: editorModel.armedPen,
                    armedText: editorModel.armedTextTool,
                    pageShadow: pageShadow, tilePaint: tilePaint, options: options,
                    findHighlights: findHighlights,
                    apply: { command, key in session.apply(command, coalescing: key) },
                    delete: { ids in session.deleteSelection(ids) },
                    // Opens the coalesced "Insert Text" group; the popover's commit/cancel
                    // closes it (E3c design call 1).
                    beginInsertText: { element in session.beginInsertText(element) },
                    // A drag-and-dropped image inserts centred at the drop point (E3c).
                    insertImageData: { data, centreDevice in
                        Task { @MainActor in
                            if let id = await session.insertImage(data: data, centreDevice: centreDevice) {
                                editorModel.selection.replace(with: id)
                            }
                        }
                    },
                    align: { ids, alignment in session.alignSelection(ids, alignment) },
                    distribute: { ids, axis in session.distributeSelection(ids, axis) },
                    // The scene's undo manager, handled by the overlay as first responder so
                    // Edit ▸ Undo/Redo and ⌘Z/⇧⌘Z reach SceneHistory (E2d).
                    sceneUndoManager: session.undoManager
                )
                .ignoresSafeArea()
            } else {
                Color(nsColor: .underPageBackgroundColor)
            }
        }
        // Keep the selection valid across undo/redo/commit: prune ids that no longer
        // exist after each scene change (design call E2b-4).
        .onChange(of: session.editVersion) { _, _ in
            if let scene = session.editingScene { editorModel.selection.prune(to: scene) }
        }
        // Undo/redo of a delete restores the selection through this hook (design call E2c-4),
        // and a new insert goes into the active layer resolved against the live scene (E3d).
        .onAppear {
            session.selectionRestore = { ids in editorModel.selection.replace(with: ids) }
            session.activeLayerIDProvider = {
                guard let scene = session.editingScene else { return nil }
                return editorModel.resolvedActiveLayerID(in: scene)
            }
        }
        // The double-click text-edit popover, anchored to the run via a UnitPoint so the
        // arrow points at the glyphs (design call E2c-5).
        .popover(item: $editorModel.textEdit, attachmentAnchor: .point(editorModel.textEdit?.anchor ?? .center), arrowEdge: .top) { request in
            TextEditPopover(
                request: request,
                // Routes through the insert-text group when the run is a brand-new text
                // (one "Insert Text" undo); a plain `setText` for an existing element (E3c).
                onCommit: { string in session.commitInsertedText(id: request.id, string: string) },
                onCancel: { session.cancelInsertedText(id: request.id) },
                onClose: { editorModel.textEdit = nil }
            )
        }
    }
}

/// The Mac editor canvas (E2b, design calls 2/5/6): the same crisp, tiled scene
/// surface the viewer uses — but fed from the editable `Scene` through
/// `SceneRenderer`, not the prepared model — with an interactive selection overlay
/// on top. Pinch and ⌘-scroll still zoom and the trackpad still pans, so the drawing
/// stays crisp at any magnification while it is edited.
///
/// All pointer interaction lives in the AppKit layer (the overlay + coordinator), so
/// a drag never round-trips through SwiftUI per frame: the live drag moves a
/// one-shot ghost raster plus the overlay, and exactly one `apply` is committed on
/// release (design call E2b-6). Selection is shared with the pane through the
/// `@Observable` `EditorModel`.
struct MacEditableCanvas: NSViewRepresentable {
    let scene: EMFEdit.Scene
    let editorModel: EditorModel
    /// The session's edit version, so the coordinator can memoise per-edit-version derived
    /// data (the selection's device bounds) and rebuild it only when the scene actually
    /// changes (P4). Defaulted so only the container passes it.
    var editVersion: Int = 0
    let controller: MacMetafileZoomController
    /// The armed shape-creation tool (E3a). Stored so a change re-runs `updateNSView`
    /// and refreshes the canvas cursor (crosshair when armed); the coordinator reads
    /// the live value from `editorModel`.
    var armedTool: ShapeToolKind? = nil
    /// Whether the pen is armed (E3b). Stored for the same cursor-refresh reason.
    var armedPen: Bool = false
    /// Whether the text tool is armed (E3c). Stored for the same cursor-refresh reason.
    var armedText: Bool = false
    var pageShadow: Bool = true
    var tilePaint: TilePaint = .plain
    var options: RenderOptions = .default
    /// The find highlights to draw in the selection overlay (F3b). `.empty` draws none.
    var findHighlights: FindHighlightSet = .empty
    /// Commits one undoable mutation through `DocumentSession.apply`.
    let apply: (SceneCommand, SceneCoalescingKey?) -> Void
    /// Deletes the given ids as one undoable step (design call E2c-4).
    let delete: (Set<Int>) -> Void
    /// Begins the coalesced insert-text undo group for a new text element (E3c).
    let beginInsertText: (EMFEdit.Element) -> Void
    /// Inserts a drag-and-dropped image's bytes centred at a DEVICE-space point (E3c).
    let insertImageData: (Data, CGPoint) -> Void
    /// Aligns / distributes the selection as one undo entry (E3e).
    let align: (Set<Int>, EditorArrange.Alignment) -> Void
    let distribute: (Set<Int>, EditorArrange.Distribution) -> Void
    /// The scene's undo manager, handled by the overlay as first responder (E2d).
    let sceneUndoManager: UndoManager

    private var pageSize: CGSize { scene.pageSizeDevice }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = EditableScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = MacMetafileScrollView.backdropColor
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.01
        scrollView.maxMagnification = ZoomMath.maxZoom

        let clipView = EditableCenteringClipView()
        clipView.drawsBackground = true
        clipView.backgroundColor = MacMetafileScrollView.backdropColor
        scrollView.contentView = clipView

        let paper = NSView(frame: CGRect(origin: .zero, size: pageSize))
        paper.wantsLayer = true
        paper.layer?.backgroundColor = NSColor.white.cgColor
        paper.shadow = pageShadow ? MacMetafileScrollView.makePaperShadow() : nil

        let tiled = TiledSceneView(scene: scene, pageSize: pageSize, options: options)
        tiled.frame = paper.bounds
        tiled.autoresizingMask = [.width, .height]
        tiled.setPaint(tilePaint)
        tiled.ensureSourcePrepared()
        paper.addSubview(tiled)

        let overlay = EditorOverlayView(frame: paper.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.coordinator = context.coordinator
        overlay.sceneUndoManager = sceneUndoManager
        // Accept dragged image files (Finder) and image data (other apps) onto the canvas.
        overlay.registerForDraggedTypes([.fileURL, .tiff, .png])
        paper.addSubview(overlay)

        scrollView.documentView = paper

        context.coordinator.scrollView = scrollView
        context.coordinator.tiledView = tiled
        context.coordinator.overlay = overlay
        controller.scrollView = scrollView

        scrollView.onLayout = { [weak coordinator = context.coordinator] viewport in
            coordinator?.configureZoomScales(for: viewport)
        }
        scrollView.onCommandScroll = { [weak coordinator = context.coordinator] event in
            coordinator?.handleCommandScroll(event) ?? false
        }
        context.coordinator.startObserving(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.tiledView?.setScene(scene, version: editVersion)
        context.coordinator.tiledView?.ensureSourcePrepared()
        context.coordinator.tiledView?.setPaint(tilePaint)
        context.coordinator.tiledView?.setOptions(options)
        scrollView.documentView?.shadow = pageShadow ? MacMetafileScrollView.makePaperShadow() : nil
        controller.scrollView = scrollView
        // A scene/selection/find/grid change redraws the overlay; an unrelated `updateView`
        // (a slider on another control, the text popover) leaves it alone (P8).
        if let overlay = context.coordinator.overlay {
            overlay.findHighlights = findHighlights   // live find highlights (F3b)
            if context.coordinator.overlayInputsChanged(version: editVersion, findHighlights: findHighlights) {
                overlay.needsDisplay = true
                overlay.window?.invalidateCursorRects(for: overlay)
            }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
        (scrollView as? EditableScrollView)?.onLayout = nil
        (scrollView as? EditableScrollView)?.onCommandScroll = nil
        coordinator.tiledView?.layer?.contents = nil
        coordinator.tiledView?.removeFromSuperview()
        coordinator.overlay?.coordinator = nil
        coordinator.tiledView = nil
        coordinator.overlay = nil
        coordinator.scrollView = nil
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        var parent: MacEditableCanvas
        fileprivate weak var scrollView: NSScrollView?
        fileprivate weak var tiledView: TiledSceneView?
        fileprivate weak var overlay: EditorOverlayView?

        private var hasSetInitialZoom = false
        /// The last UNOBSCURED region the page was fitted to. Tracking the available region
        /// (not just the viewport size) is what makes an inspector open/close re-fit: the
        /// inspector changes the scroll view's trailing SAFE-AREA INSET, not its frame size,
        /// so a plain size comparison never saw it (E3e fix B review).
        private var lastAvailableSize: CGSize = .zero
        private static let fitMargin: CGFloat = 24

        /// Live drag state. `nil` between drags.
        fileprivate var drag: DragState?

        /// Bumped at each drag start so an off-main ghost rasterisation that finishes after the
        /// drag ended (or after a newer drag began) discards its stale raster (P1).
        private var ghostGeneration = 0

        /// The last time the marquee re-ran its O(N) hit test, so a fast mouse-drag doesn't scan
        /// every element on every event — throttled to ~60 Hz, with a final exact pass on
        /// mouse-up (P3).
        private var lastMarqueeHitTime: TimeInterval = 0
        private static let marqueeHitInterval: TimeInterval = 1.0 / 60

        /// Runs the marquee hit test for `viewRect` and assigns the selection ONLY when the hit
        /// set actually changed, so dragging over empty space (or within the same elements)
        /// doesn't rewrite the selection — and re-run the whole viewer body — on every event (P3).
        private func updateMarqueeSelection(viewRect: CGRect) {
            let deviceRect = mapping.deviceRect(fromView: viewRect)
            let hits = EditorHitTest.marquee(in: scene, deviceRect: deviceRect)
            guard selection.ids != hits else { return }
            var next = selection
            next.replace(with: hits)
            selection = next
        }

        /// Whether anything the selection overlay actually draws changed since the last
        /// `updateView`, so an unrelated update (tile paint, render options, the text popover,
        /// the inspector trailing inset) doesn't force a redraw of the chrome (P8).
        private struct OverlayKey: Equatable {
            var version: Int
            var selection: Set<Int>
            var find: FindHighlightSet
            var showGrid: Bool
            var armedShape: ShapeToolKind?
            var armedPen: Bool
            var armedText: Bool
        }
        private var lastOverlayKey: OverlayKey?
        func overlayInputsChanged(version: Int, findHighlights: FindHighlightSet) -> Bool {
            let model = parent.editorModel
            let key = OverlayKey(
                version: version, selection: model.selection.ids, find: findHighlights,
                showGrid: model.showGrid,
                armedShape: model.armedShapeTool, armedPen: model.armedPen, armedText: model.armedTextTool)
            if key == lastOverlayKey { return false }
            lastOverlayKey = key
            return true
        }

        init(_ parent: MacEditableCanvas) {
            self.parent = parent
            super.init()
            #if DEBUG
            Self.debugActive = self
            #endif
        }

        #if DEBUG
        /// The most recently created editing coordinator, so the E3e `align-grid` capture
        /// script can drive a live snapped drag it can't produce with a synthetic pointer.
        static weak var debugActive: Coordinator?

        /// Numbers for the fix-B fit debugging (E3e review): the visible region, the page
        /// rect in that region's coordinates, and the magnification vs the fit.
        func debugFitReport() -> String {
            guard let scrollView else { return "no scrollView" }
            let viewport = scrollView.bounds.size
            let insets = ViewerFit.Insets(
                top: scrollView.safeAreaInsets.top, leading: scrollView.safeAreaInsets.left,
                bottom: scrollView.safeAreaInsets.bottom, trailing: scrollView.safeAreaInsets.right)
            let fit = ViewerFit.fitScale(content: parent.pageSize, viewport: viewport, insets: insets, margin: Self.fitMargin, minScale: 0.01, maxScale: ZoomMath.maxZoom)
            let visible = scrollView.documentVisibleRect
            let paper = scrollView.documentView?.frame ?? .zero
            let fits = visible.insetBy(dx: Self.fitMargin, dy: Self.fitMargin).contains(paper)
            return String(format: "scrollFrame=%@ clip=%@ visibleDoc=%@ paper=%@ safeInsets(t%.0f l%.0f b%.0f r%.0f) mag=%.4f min=%.4f max=%.4f fitForViewport=%.4f pageInsideVisible=%@",
                NSStringFromRect(scrollView.frame), NSStringFromRect(scrollView.contentView.bounds),
                NSStringFromRect(visible), NSStringFromRect(paper),
                insets.top, insets.leading, insets.bottom, insets.trailing,
                scrollView.magnification, scrollView.minMagnification, scrollView.maxMagnification, fit,
                fits ? "YES" : "NO")
        }

        /// Starts a live MOVE drag of `moveID` and drags its centre to within ~3 view-pt of
        /// `towardID`'s centre so the smart-guide snap engages, leaving the drag ACTIVE for a
        /// capture. Returns whether a guide is showing.
        @discardableResult
        func debugBeginSnappedMoveDrag(moveID: Int, towardID: Int) -> Bool {
            selection.replace(with: moveID)
            overlay?.needsDisplay = true
            guard let moveBox = scene.element(id: moveID)?.selectionBoundsDevice,
                  let targetBox = scene.element(id: towardID)?.selectionBoundsDevice else { return false }
            let startView = mapping.viewPoint(fromDevice: CGPoint(x: moveBox.midX, y: moveBox.midY))
            let endDevice = CGPoint(x: targetBox.midX + mapping.deviceLength(fromViewLength: 3), y: moveBox.midY)
            let endView = mapping.viewPoint(fromDevice: endDevice)
            mouseDown(at: startView, shift: false, command: false)
            mouseDragged(to: endView, shift: false, option: false, command: false)
            return !(drag?.snapGuideXsDevice.isEmpty ?? true) || !(drag?.snapGuideYsDevice.isEmpty ?? true)
        }
        #endif

        var scene: EMFEdit.Scene { parent.scene }
        var selection: EditorSelection {
            get { parent.editorModel.selection }
            set { parent.editorModel.selection = newValue }
        }

        /// The current on-screen magnification (1 = 100%).
        var magnification: CGFloat { scrollView?.magnification ?? 1 }

        /// device ↔ paper-view mapping for the current page (target origin is the
        /// paper's own 0,0; the magnification is applied by the scroll view).
        var mapping: EditorCanvasMapping {
            EditorCanvasMapping(pageBoundsDevice: scene.pageBoundsDevice, target: CGRect(origin: .zero, size: parent.pageSize))
        }

        // MARK: Zoom configuration (compact mirror of the viewer's)

        func startObserving(_ scrollView: NSScrollView) {
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipBoundsChanged),
                name: NSView.boundsDidChangeNotification, object: scrollView.contentView
            )
        }
        func stopObserving() { NotificationCenter.default.removeObserver(self) }

        @objc private func clipBoundsChanged() {
            guard let scrollView else { return }
            if parent.editorModel.selection.isEmpty == false || drag != nil { overlay?.needsDisplay = true }
            if parent.controller.zoom != scrollView.magnification { parent.controller.zoom = scrollView.magnification }
        }

        func configureZoomScales(for viewport: CGSize) {
            guard viewport.width > 0, viewport.height > 0, let scrollView else { return }
            let natural = parent.pageSize
            let insets = ViewerFit.Insets(
                top: scrollView.safeAreaInsets.top, leading: scrollView.safeAreaInsets.left,
                bottom: scrollView.safeAreaInsets.bottom, trailing: scrollView.safeAreaInsets.right
            )
            // The editor fits the drawing to FILL the canvas (upscale allowed, unlike
            // the read-only viewer's 1× cap), so a small drawing is large enough to edit
            // and its handles read clearly.
            // Fix B (E3e): keep the page fully inside the visible pane — re-fit on the
            // first layout, on an inspector open/close, and on a window resize, while a
            // manual zoom is left alone (the overflow clause still snaps back to fit when a
            // shrink would cut the page off), exactly as the iPad does.
            // Re-fit when the UNOBSCURED region changes — a viewport resize OR an inspector/
            // sidebar inset change (fix B review): the inspector only shifts the safe-area
            // insets, so comparing region sizes is what catches it.
            let available = ViewerFit.availableSize(viewport: viewport, insets: insets, margin: Self.fitMargin)
            let refit = ViewerFit.editorRefitScale(
                content: natural, viewport: viewport, insets: insets, margin: Self.fitMargin,
                minScale: 0.01, maxScale: ZoomMath.maxZoom,
                currentMagnification: scrollView.magnification, previousFitScale: parent.controller.fitScale,
                hasFittedBefore: hasSetInitialZoom, viewportChanged: available != lastAvailableSize)
            let fit = ViewerFit.fitScale(content: natural, viewport: viewport, insets: insets, margin: Self.fitMargin, minScale: 0.01, maxScale: ZoomMath.maxZoom)
            scrollView.minMagnification = ZoomMath.minMagnification(fit: fit)
            scrollView.maxMagnification = ZoomMath.maxMagnification(fit: fit)
            parent.controller.fitScale = fit
            if let refit {
                let wasFirst = !hasSetInitialZoom
                hasSetInitialZoom = true
                setMagnification(refit)
                if wasFirst {
                    DispatchQueue.main.async { [weak scrollView, weak overlay] in
                        guard let scrollView, scrollView.window?.firstResponder !== overlay else { return }
                        if let overlay { scrollView.window?.makeFirstResponder(overlay) }
                    }
                }
            }
            lastAvailableSize = available
            if parent.controller.zoom != scrollView.magnification { parent.controller.zoom = scrollView.magnification }
            overlay?.needsDisplay = true
        }

        private func setMagnification(_ value: CGFloat) {
            guard let scrollView else { return }
            let centre = ZoomMath.visibleCentre(of: scrollView.contentView.bounds)
            scrollView.setMagnification(value, centeredAt: centre)
        }

        func handleCommandScroll(_ event: NSEvent) -> Bool {
            guard let scrollView else { return false }
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
            guard delta != 0 else { return true }
            let newMag = ZoomMath.scrollZoomMagnification(
                current: scrollView.magnification, scrollDelta: delta, precise: event.hasPreciseScrollingDeltas,
                min: scrollView.minMagnification, max: scrollView.maxMagnification
            )
            let point = scrollView.contentView.convert(event.locationInWindow, from: nil)
            scrollView.setMagnification(newMag, centeredAt: point)
            if parent.controller.zoom != newMag { parent.controller.zoom = newMag }
            overlay?.needsDisplay = true
            return true
        }

        // MARK: Selection bounds

        /// Memoised selection device bounds (P4): the overlay draw and handle hit tests ask for
        /// this every pointer move, and computing it re-derives each selected element's bounds
        /// (text runs recompute their metrics). The scene only changes with the edit version and
        /// the selection changes between interactions, so cache by (version, ids).
        private var selectionBoundsCache: (version: Int, ids: Set<Int>, box: CGRect?)?
        private func selectionBoundsDevice() -> CGRect? {
            let version = parent.editVersion
            let ids = selection.ids
            if let c = selectionBoundsCache, c.version == version, c.ids == ids { return c.box }
            let box = selection.boundsDevice(in: scene)
            selectionBoundsCache = (version, ids, box)
            return box
        }

        /// The selection's bounding box in paper-view coordinates, or nil.
        func selectionViewBounds() -> CGRect? {
            guard let deviceBox = selectionBoundsDevice() else { return nil }
            return mapping.viewRect(fromDevice: deviceBox)
        }

        /// The stroke-hit tolerance in device units for the current zoom (4 view pt).
        private func strokeTolerance() -> CGFloat { mapping.deviceLength(fromViewLength: 4) }

        /// The handle whose on-screen point is within `hitPt` of the paper-view point,
        /// or nil.
        func handle(at viewPoint: CGPoint) -> ResizeHandle? {
            guard let box = selectionViewBounds() else { return nil }
            let hit = Self.handleHitRadius / magnification
            for handle in ResizeHandle.allCases {
                if hypot(viewPoint.x - handle.point(in: box).x, viewPoint.y - handle.point(in: box).y) <= hit {
                    return handle
                }
            }
            return nil
        }

        static let handleHitRadius: CGFloat = 11
        static let handleDrawSize: CGFloat = 9

        // MARK: Pointer

        /// Whether a shape-creation tool is currently armed (E3a).
        var isShapeToolArmed: Bool { parent.editorModel.armedShapeTool != nil }

        /// Whether the text-creation tool is currently armed (E3c).
        var isTextToolArmed: Bool { parent.editorModel.armedTextTool }

        /// Inserts a new text element at the clicked device point, selects it, opens the
        /// text popover on it (one coalesced "Insert Text" undo), and disarms the tool.
        /// The popover anchors to the just-built element directly — the coordinator's
        /// `scene` snapshot has not yet been refreshed with the insert this frame.
        private func insertText(at viewPoint: CGPoint) {
            let origin = mapping.devicePoint(fromView: viewPoint)
            let insertion = TextToolInsertion.element(originDevice: origin, in: scene)
            parent.beginInsertText(insertion.element)
            var next = EditorSelection()
            next.replace(with: insertion.id)
            selection = next
            parent.editorModel.armedTextTool = false
            if let overlay { overlay.window?.invalidateCursorRects(for: overlay) }
            parent.editorModel.textEdit = TextEditRequest(
                id: insertion.id, anchor: anchor(for: insertion.element),
                initialText: insertion.element.text?.string ?? TextToolInsertion.placeholder)
            overlay?.needsDisplay = true
        }

        func mouseDown(at viewPoint: CGPoint, shift: Bool, command: Bool) {
            overlay?.window?.makeFirstResponder(overlay)
            parent.editorModel.rotationReadout = nil

            // 0. An armed shape tool draws a new shape instead of selecting (E3a).
            if let tool = parent.editorModel.armedShapeTool {
                var state = DragState(kind: .shape, start: viewPoint, current: viewPoint, baseSelection: selection)
                state.shapeKind = tool
                state.snapCandidates = buildSnapCandidates()   // once per draw (design call 3)
                drag = state
                overlay?.needsDisplay = true
                return
            }

            // 0a. The armed text tool inserts a new text element at the click and opens its
            //     popover; the tool disarms after one insert (E3c design call 1).
            if parent.editorModel.armedTextTool {
                insertText(at: viewPoint)
                return
            }

            // 0b. The armed pen draws a freehand stroke (E3b); it stays armed on release.
            if parent.editorModel.armedPen {
                var state = DragState(kind: .pen, start: viewPoint, current: viewPoint, baseSelection: selection)
                state.penPoints = [viewPoint]
                drag = state
                lastPenPoint = viewPoint
                penHoldWorkItem?.cancel(); penHoldWorkItem = nil
                overlay?.needsDisplay = true
                return
            }

            // 1. A handle under the cursor starts a resize (or ⌘ = rotate) of the
            //    current selection.
            if !selection.isEmpty, let handle = handle(at: viewPoint) {
                if command, handle.isCorner {
                    beginRotate(at: viewPoint)
                } else {
                    beginResize(handle: handle, at: viewPoint)
                }
                return
            }

            // 2. Inside the selection bounds starts a move.
            if !selection.isEmpty, let box = selectionViewBounds(), box.insetBy(dx: -2, dy: -2).contains(viewPoint),
               hitElement(at: viewPoint) != nil || box.contains(viewPoint) {
                beginMove(at: viewPoint)
                return
            }

            // 3. A click on an element selects it; empty space starts a marquee.
            if let id = hitElement(at: viewPoint) {
                selection = selection.afterClick(hit: id, additive: shift || command)
                if !selection.contains(id) { overlay?.needsDisplay = true; return }
                beginMove(at: viewPoint)   // allow an immediate drag of the just-selected element
            } else {
                if !(shift || command) { selection.clear() }
                drag = DragState(kind: .marquee, start: viewPoint, current: viewPoint, baseSelection: selection)
            }
            overlay?.needsDisplay = true
        }

        func mouseDragged(to viewPoint: CGPoint, shift: Bool, option: Bool, command: Bool = false) {
            guard var state = drag else { return }
            state.snapDisabled = command   // ⌘ temporarily disables snapping (design call 3)
            // A resize or a shape draw snaps the DRAGGED point; a move snaps its whole
            // bounds (below, in updateLiveTransform); marquee/pen/rotate never snap.
            var effective = viewPoint
            if state.kind == .resize || state.kind == .shape {
                let (snapped, gx, gy) = snapViewPoint(state: state, view: viewPoint)
                effective = snapped
                state.snapGuideXsDevice = gx
                state.snapGuideYsDevice = gy
            }
            state.current = effective
            drag = state
            switch state.kind {
            case .marquee:
                // Throttle the O(N) hit test to ~60 Hz; mouse-up runs a final exact pass (P3).
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastMarqueeHitTime >= Self.marqueeHitInterval {
                    lastMarqueeHitTime = now
                    let rect = CGRect(x: min(state.start.x, viewPoint.x), y: min(state.start.y, viewPoint.y),
                                      width: abs(viewPoint.x - state.start.x), height: abs(viewPoint.y - state.start.y))
                    updateMarqueeSelection(viewRect: rect)
                }
            case .shape:
                if let kind = state.shapeKind {
                    drag?.shapePreviewRect = ShapeToolGeometry.sweptRect(
                        kind: kind, start: state.start, current: effective, shift: shift, fromCentre: option
                    )
                }
            case .pen:
                appendPenPoint(viewPoint)
                return   // appendPenPoint redraws; skip the shared redraw below
            case .move, .resize, .rotate:
                updateLiveTransform(state: state, shift: shift, option: option)
            }
            overlay?.needsDisplay = true
        }

        func mouseUp(at viewPoint: CGPoint, shift: Bool, option: Bool) {
            guard let state = drag else { return }
            defer { drag = nil; tiledView?.setHiddenIDs([]); parent.editorModel.rotationReadout = nil; overlay?.needsDisplay = true }
            switch state.kind {
            case .marquee:
                // A final exact pass so the release reflects the last rect even if the throttle
                // skipped the last drag event (P3).
                let rect = CGRect(x: min(state.start.x, viewPoint.x), y: min(state.start.y, viewPoint.y),
                                  width: abs(viewPoint.x - state.start.x), height: abs(viewPoint.y - state.start.y))
                updateMarqueeSelection(viewRect: rect)
            case .shape:
                commitShape(state: state, end: viewPoint, shift: shift, option: option)
            case .pen:
                penHoldWorkItem?.cancel(); penHoldWorkItem = nil
                commitPenStroke(state: state)
            case .move, .resize, .rotate:
                if let (command, key) = committedCommand(state: state, end: viewPoint, shift: shift, option: option) {
                    markDirtyRegion(old: state.startViewBounds ?? selectionViewBounds(),
                                    viewTransform: liveViewTransform(state: state, shift: shift, option: option))
                    parent.apply(command, key)
                }
            }
        }

        /// Commits one `.insert` for a drawn shape: a sweep becomes the swept rect, a
        /// click becomes the 100 × 100 pt default centred at the click. The new element
        /// becomes the selection and the tool disarms (Keynote behaviour, design call 5).
        private func commitShape(state: DragState, end: CGPoint, shift: Bool, option: Bool) {
            guard let kind = state.shapeKind else { return }
            // Snap the release corner to the same candidates the live preview used (E3e).
            let end = snapViewPoint(state: state, view: end).0
            let deviceRect: CGRect
            if ShapeToolGeometry.isDrag(start: state.start, current: end, magnification: magnification) {
                let viewRect = ShapeToolGeometry.sweptRect(kind: kind, start: state.start, current: end, shift: shift, fromCentre: option)
                deviceRect = sweptDeviceRect(fromView: viewRect)
            } else {
                let centre = mapping.devicePoint(fromView: end)
                let side = ShapeToolGeometry.pointsToDevice(ShapeToolGeometry.defaultSidePoints, deviceUnitsPerPoint: scene.deviceUnitsPerPoint)
                deviceRect = ShapeToolGeometry.defaultRect(centreDevice: centre, sideDevice: side)
            }
            let insertion = ShapeToolInsertion.command(kind: kind, rectDevice: deviceRect, in: scene)
            parent.apply(insertion.command, nil)
            var next = EditorSelection()
            next.replace(with: insertion.id)
            selection = next
            parent.editorModel.armedShapeTool = nil
        }

        /// Maps a view-space swept rect to a DEVICE-space rect, mapping the origin and
        /// far corner individually so a `.line`'s drag direction (a signed size) survives.
        private func sweptDeviceRect(fromView viewRect: CGRect) -> CGRect {
            let originDevice = mapping.devicePoint(fromView: viewRect.origin)
            let farDevice = mapping.devicePoint(fromView: CGPoint(
                x: viewRect.origin.x + viewRect.size.width, y: viewRect.origin.y + viewRect.size.height))
            return CGRect(origin: originDevice,
                          size: CGSize(width: farDevice.x - originDevice.x, height: farDevice.y - originDevice.y))
        }

        // MARK: Pen (E3b)

        /// Whether the freehand pen is armed.
        var isPenArmed: Bool { parent.editorModel.armedPen }

        /// The single outstanding pen-hold wake-up, re-armed on each qualifying move instead of
        /// scheduling a fresh `asyncAfter` per point (P18) — so a long stroke leaves at most one
        /// timer pending rather than hundreds that each fire and early-return.
        private var penHoldWorkItem: DispatchWorkItem?
        private var lastPenPoint: CGPoint = .zero
        private static let penHoldDelay: TimeInterval = 0.5

        /// The de-dup / RDP tolerances in device units for the current zoom: about 1 and
        /// 1.5 screen points (design call 2), floored so they never collapse to zero.
        private var penMinSpacingDevice: CGFloat { max(0.5, mapping.deviceLength(fromViewLength: 1 / magnification)) }
        private var penRdpToleranceDevice: CGFloat { max(0.75, mapping.deviceLength(fromViewLength: 1.5 / magnification)) }

        /// The pen's preview colour (its own colour) as a CGColor.
        func penPreviewColor() -> CGColor {
            let c = parent.editorModel.penStyle.color
            return CGColor(red: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: 1)
        }
        /// The pen stroke width in device units, for the live preview (overlay space == device).
        var penPreviewWidthDevice: CGFloat {
            ShapeToolGeometry.pointsToDevice(parent.editorModel.penStyle.widthPoints, deviceUnitsPerPoint: scene.deviceUnitsPerPoint)
        }

        /// Appends a freehand sample, tracks the end-of-stroke hold, and schedules the
        /// 0.5 s snap check after motion settles (design call 4).
        private func appendPenPoint(_ p: CGPoint) {
            guard drag?.kind == .pen else { return }
            // Append through the stored property so the array mutates in place — the old
            // `var copy = drag; copy.penPoints.append; drag = copy` kept two live references to
            // the buffer, forcing a copy-on-write of the whole point array on every move (O(n²)
            // over a stroke) (P5).
            drag?.penPoints.append(p)
            // A real move resets the hold: clear any snap preview and re-arm the single timer so
            // the check fires 0.5 s after the pointer last moved (P18).
            if hypot(p.x - lastPenPoint.x, p.y - lastPenPoint.y) > 2 / magnification {
                lastPenPoint = p
                drag?.penHoldElapsed = false
                drag?.penSnapPreview = nil
                penHoldWorkItem?.cancel()
                let item = DispatchWorkItem { [weak self] in self?.evaluatePenHold() }
                penHoldWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.penHoldDelay, execute: item)
            }
            overlay?.needsDisplay = true
        }

        /// After the pointer settles for 0.5 s mid-stroke: mark the hold and, if the stroke
        /// so far recognises as a shape, show that shape live (it commits on release).
        private func evaluatePenHold() {
            guard drag?.kind == .pen, let points = drag?.penPoints else { return }
            drag?.penHoldElapsed = true
            let devicePoints = points.map { mapping.devicePoint(fromView: $0) }
            drag?.penSnapPreview = ShapeRecognizer.recognize(points: devicePoints, rdpTolerance: penRdpToleranceDevice)
            overlay?.needsDisplay = true
        }

        /// Commits one `.insert` for a finished stroke: the smoothed curve, or the snapped
        /// shape when the pointer held. The pen stays armed and the stroke is NOT selected
        /// (design call 1).
        private func commitPenStroke(state: DragState) {
            let devicePoints = state.penPoints.map { mapping.devicePoint(fromView: $0) }
            guard let insertion = PenCommit.command(
                rawDevicePoints: devicePoints, held: state.penHoldElapsed,
                minSpacing: penMinSpacingDevice, rdpTolerance: penRdpToleranceDevice,
                pen: parent.editorModel.penStyle, in: scene) else { return }
            parent.apply(insertion.command, nil)
        }

        /// Invalidate only the region a committed edit touches — the union of the
        /// selection's old and new bounds plus an outset for strokes/antialiasing — so
        /// the tiled view repaints just those tiles rather than blanking the whole
        /// canvas (E2b item 5).
        private func markDirtyRegion(old: CGRect?, viewTransform: CGAffineTransform) {
            guard let old else { tiledView?.pendingDirtyRegion = nil; return }
            tiledView?.pendingDirtyRegion = old.union(old.applying(viewTransform)).insetBy(dx: -48, dy: -48)
        }

        /// Esc cancels an in-progress drag with no commit, restoring the live scene.
        func cancelDrag() {
            guard drag != nil else { return }
            penHoldWorkItem?.cancel(); penHoldWorkItem = nil
            drag = nil
            tiledView?.setHiddenIDs([])
            parent.editorModel.rotationReadout = nil
            overlay?.needsDisplay = true
        }

        func hitElement(at viewPoint: CGPoint) -> Int? {
            EditorHitTest.topmost(in: scene, atDevice: mapping.devicePoint(fromView: viewPoint), strokeToleranceDevice: strokeTolerance())
        }

        /// A double-click on a text element opens the text-edit popover anchored to the
        /// element (design call E2c-5); on anything else it is ignored.
        func doubleClick(at viewPoint: CGPoint) {
            guard let id = hitElement(at: viewPoint),
                  let element = scene.element(id: id),
                  element.kind == .text else { return }
            presentTextEdit(for: id)
        }

        /// Opens the text-edit popover for a text element, anchored to the run. Shared by
        /// double-click and the DEBUG hook.
        func presentTextEdit(for id: Int) {
            guard let element = scene.element(id: id),
                  element.kind == .text, let text = element.text else { return }
            selection.replace(with: id)
            parent.editorModel.textEdit = TextEditRequest(id: id, anchor: anchor(for: element), initialText: text.string)
            overlay?.needsDisplay = true
        }

        /// The run's reference point as a fraction of the scroll view's visible viewport,
        /// so the popover's arrow points at the glyphs. A text element's own bounds is the
        /// inherited page clip (EMFEdit text-bounds limitation), so the run's reference
        /// point gives a tight anchor.
        private func anchor(for element: Element) -> UnitPoint {
            guard let scrollView, let overlay else { return .center }
            let deviceAnchor = CGPoint(x: element.text?.referenceLogical.x ?? element.boundsDevice.midX,
                                       y: element.text?.referenceLogical.y ?? element.boundsDevice.midY)
            let paperPoint = mapping.viewPoint(fromDevice: deviceAnchor)
            let clip = scrollView.contentView
            let inClip = overlay.convert(paperPoint, to: clip)
            let bounds = clip.bounds
            guard bounds.width > 0, bounds.height > 0 else { return .center }
            // The clip view is y-up; a UnitPoint is y-down (top-left origin).
            let x = (inClip.x - bounds.minX) / bounds.width
            let y = 1 - (inClip.y - bounds.minY) / bounds.height
            return UnitPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
        }

        /// Deletes the current selection as one undoable step (design call E2c-4).
        func deleteSelection() {
            guard !selection.isEmpty else { return }
            parent.delete(selection.ids)
        }

        // MARK: Accessibility (C5g / audit A1)

        /// The editable elements exposed to VoiceOver / Switch Control, in reading order.
        func accessibilityDescriptors() -> [EditorAccessibility.ElementDescriptor] {
            EditorAccessibility.descriptors(in: scene, selection: selection)
        }

        /// Cycles the selection through the unlocked elements in reading order (Option-Tab /
        /// Option-Shift-Tab keyboard selection, C5g; plain Tab stays with the focus loop).
        /// Returns whether it was handled.
        @discardableResult
        func cycleSelection(forward: Bool) -> Bool {
            guard let id = EditorAccessibility.cycleSelection(from: selection.ids, forward: forward, in: scene) else { return false }
            selection.replace(with: id)
            if let overlay {
                overlay.needsDisplay = true
                overlay.window?.invalidateCursorRects(for: overlay)
                NSAccessibility.post(element: overlay, notification: .selectedChildrenChanged)
            }
            return true
        }

        /// Performs a custom accessibility action over `id`, routing through the SAME scene
        /// commands and undo as a pointer edit. Returns whether it was handled.
        @discardableResult
        func accessibilityPerform(_ action: EditorAccessibility.Action, on id: Int) -> Bool {
            switch action {
            case .select:
                selection.replace(with: id)
                overlay?.window?.makeFirstResponder(overlay)
                overlay?.needsDisplay = true
                if let overlay { NSAccessibility.post(element: overlay, notification: .selectedChildrenChanged) }
                return true
            case .delete:
                if !selection.contains(id) { selection.replace(with: id) }
                parent.delete([id])
                overlay?.needsDisplay = true
                return true
            case .editText:
                selection.replace(with: id)
                presentTextEdit(for: id)
                return true
            default:
                guard let command = EditorAccessibility.command(for: action, elementID: id, in: scene) else { return false }
                if !selection.contains(id) { selection.replace(with: id) }
                parent.apply(command, nil)
                overlay?.needsDisplay = true
                if let overlay { NSAccessibility.post(element: overlay, notification: .layoutChanged) }
                return true
            }
        }

        #if DEBUG
        /// A text dump of the live accessibility tree (label, value, traits, actions).
        func debugAccessibilityDump() -> String {
            EditorAccessibility.debugDump(in: scene, selection: selection)
        }
        #endif

        // MARK: Context menu (E3d) — Arrange + Move Selection to Layer

        /// The right-click menu for a non-empty selection: Arrange (reorder within the
        /// layer) and a Move Selection to Layer submenu. `nil` when nothing is selected.
        func contextMenu() -> NSMenu? {
            guard !selection.isEmpty else { return nil }
            let menu = NSMenu()
            menu.addItem(arrangeItem("Bring to Front", #selector(bringToFront(_:))))
            menu.addItem(arrangeItem("Bring Forward", #selector(bringForward(_:))))
            menu.addItem(arrangeItem("Send Backward", #selector(sendBackward(_:))))
            menu.addItem(arrangeItem("Send to Back", #selector(sendToBack(_:))))

            // Align / Distribute (E3e).
            menu.addItem(.separator())
            let alignItem = NSMenuItem(title: "Align Objects", action: nil, keyEquivalent: "")
            alignItem.submenu = alignSubmenu()
            menu.addItem(alignItem)
            let distributeItem = NSMenuItem(title: "Distribute Objects", action: nil, keyEquivalent: "")
            let distributeMenu = NSMenu()
            distributeMenu.addItem(alignActionItem("Distribute Horizontally", #selector(distributeHorizontally(_:))))
            distributeMenu.addItem(alignActionItem("Distribute Vertically", #selector(distributeVertically(_:))))
            distributeItem.submenu = distributeMenu
            distributeItem.isEnabled = selection.count >= 3
            menu.addItem(distributeItem)

            if parent.scene.layers.count > 1 {
                menu.addItem(.separator())
                let move = NSMenuItem(title: "Move Selection to Layer", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                // Top layer first, matching the panel's order.
                for order in parent.scene.layers.indices.reversed() {
                    let item = NSMenuItem(title: parent.scene.layers[order].name, action: #selector(moveToLayer(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = order
                    submenu.addItem(item)
                }
                move.submenu = submenu
                menu.addItem(move)
            }
            return menu
        }

        private func arrangeItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        @objc private func bringToFront(_ sender: Any?) { parent.apply(.arrange(ids: selection.ids, .toFront), nil) }
        @objc private func bringForward(_ sender: Any?) { parent.apply(.arrange(ids: selection.ids, .forward), nil) }
        @objc private func sendBackward(_ sender: Any?) { parent.apply(.arrange(ids: selection.ids, .backward), nil) }
        @objc private func sendToBack(_ sender: Any?) { parent.apply(.arrange(ids: selection.ids, .toBack), nil) }

        /// The Align submenu (E3e): the six edges, with horizontal and vertical grouped.
        private func alignSubmenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(alignActionItem("Align Left", #selector(alignLeft(_:))))
            menu.addItem(alignActionItem("Align Centre", #selector(alignCentreH(_:))))
            menu.addItem(alignActionItem("Align Right", #selector(alignRight(_:))))
            menu.addItem(.separator())
            menu.addItem(alignActionItem("Align Top", #selector(alignTop(_:))))
            menu.addItem(alignActionItem("Align Middle", #selector(alignMiddle(_:))))
            menu.addItem(alignActionItem("Align Bottom", #selector(alignBottom(_:))))
            return menu
        }
        private func alignActionItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }
        @objc private func alignLeft(_ sender: Any?) { parent.align(selection.ids, .left) }
        @objc private func alignCentreH(_ sender: Any?) { parent.align(selection.ids, .centreHorizontal) }
        @objc private func alignRight(_ sender: Any?) { parent.align(selection.ids, .right) }
        @objc private func alignTop(_ sender: Any?) { parent.align(selection.ids, .top) }
        @objc private func alignMiddle(_ sender: Any?) { parent.align(selection.ids, .centreVertical) }
        @objc private func alignBottom(_ sender: Any?) { parent.align(selection.ids, .bottom) }
        @objc private func distributeHorizontally(_ sender: Any?) { parent.distribute(selection.ids, .horizontal) }
        @objc private func distributeVertically(_ sender: Any?) { parent.distribute(selection.ids, .vertical) }
        @objc private func moveToLayer(_ sender: NSMenuItem) {
            parent.apply(.moveElementsToLayer(ids: selection.ids, layer: sender.tag), nil)
        }

        // MARK: Drag-and-drop image (E3c)

        /// Inserts dropped image `data` centred at the drop point, mapped to device space
        /// through the SAME mapping the click tools use.
        func handleImageDrop(_ data: Data, at viewPoint: CGPoint) {
            parent.insertImageData(data, mapping.devicePoint(fromView: viewPoint))
        }

        // MARK: Drag kinds

        private func beginMove(at viewPoint: CGPoint) {
            var state = DragState(kind: .move, start: viewPoint, current: viewPoint, baseSelection: selection)
            state.startViewBounds = selectionViewBounds()
            state.snapCandidates = buildSnapCandidates()   // once per drag (design call 3)
            drag = state
            prepareGhost()
        }
        private func beginResize(handle: ResizeHandle, at viewPoint: CGPoint) {
            var state = DragState(kind: .resize, start: viewPoint, current: viewPoint, baseSelection: selection)
            state.handle = handle
            state.startViewBounds = selectionViewBounds()
            state.snapCandidates = buildSnapCandidates()   // once per drag (design call 3)
            drag = state
            prepareGhost()
        }
        private func beginRotate(at viewPoint: CGPoint) {
            var state = DragState(kind: .rotate, start: viewPoint, current: viewPoint, baseSelection: selection)
            state.startViewBounds = selectionViewBounds()
            drag = state
            prepareGhost()
        }

        /// Hides the selected elements in the tiled scene (one re-render) and
        /// rasterises them into a ghost image the overlay moves live (design call E2b-6).
        private func prepareGhost() {
            guard let box = selectionViewBounds(), let deviceBox = selection.boundsDevice(in: scene) else { return }
            drag?.ghostViewBounds = box
            // Hide the selection on the tile immediately and let the overlay draw the moving
            // outline; rasterise the ghost OFF the main thread, reusing the tile's prepared
            // source, so a text/image/EMF+ selection never re-parses and re-observes the whole
            // file on the main thread at drag start (P1). The outline shows until the raster lands.
            tiledView?.setHiddenIDs(selection.ids)
            let scene = self.scene
            let ids = selection.ids
            let pixelScale = max(1, magnification) * (overlay?.window?.backingScaleFactor ?? 2)
            let source = tiledView?.readyRenderSource
            ghostGeneration &+= 1
            let generation = ghostGeneration
            Task { [weak self] in
                let raster = await Task.detached(priority: .userInitiated) {
                    GhostRaster(image: GhostRasterizer.image(scene: scene, ids: ids, deviceBounds: deviceBox, pixelScale: pixelScale, source: source))
                }.value
                guard let self, self.ghostGeneration == generation, self.drag != nil else { return }
                self.drag?.ghost = raster.image
                self.overlay?.needsDisplay = true
            }
        }

        // MARK: Snapping + grid (E3e)

        /// The finest displayed grid spacing in device units, for drawing and snapping.
        var gridSpacingDevice: CGFloat {
            EditorGrid.displayedSpacing(
                deviceUnitsPerInch: scene.deviceUnitsPerInch ?? 96,
                onScreenMajorPoints: EditorGrid.deviceSpacing(deviceUnitsPerInch: scene.deviceUnitsPerInch ?? 96)
                    * mapping.viewLength(fromDeviceLength: 1) * magnification)
        }

        /// The snap threshold (6 view-pt) in device units at the current zoom.
        private var snapThresholdDevice: CGFloat { mapping.deviceLength(fromViewLength: 6 / magnification) }

        /// Collects the snap candidates ONCE at drag start (design call 3): other elements'
        /// and the page's edges/centres (smart guides), plus the grid when it's shown. Empty
        /// when both snapping modes are off.
        private func buildSnapCandidates() -> EditorSnap.Candidates {
            let model = parent.editorModel
            let guides = model.snapToGuides
            let grid = (model.showGrid && model.snapToGrid) ? gridSpacingDevice : nil
            guard guides || grid != nil else { return .empty }
            var xs: [CGFloat] = []
            var ys: [CGFloat] = []
            if guides {
                scene.forEachElement { element in
                    guard !selection.contains(element.id) else { return }
                    let b = element.selectionBoundsDevice
                    guard !b.isNull else { return }
                    xs.append(contentsOf: [b.minX, b.midX, b.maxX])
                    ys.append(contentsOf: [b.minY, b.midY, b.maxY])
                }
                let p = scene.pageBoundsDevice
                xs.append(contentsOf: [p.minX, p.midX, p.maxX])
                ys.append(contentsOf: [p.minY, p.midY, p.maxY])
            }
            return EditorSnap.Candidates(xs: xs, ys: ys, gridSpacing: grid)
        }

        /// The device adjustment + guide lines for a snapped MOVE, converted from the raw
        /// view translation. Returns `(viewAdjX, viewAdjY, guideXsDevice, guideYsDevice)`.
        private func moveSnap(state: DragState, rawView: CGAffineTransform) -> (CGFloat, CGFloat, [CGFloat], [CGFloat]) {
            guard !state.snapDisabled, let candidates = state.snapCandidates, let base = state.startViewBounds else {
                return (0, 0, [], [])
            }
            let movedDevice = mapping.deviceRect(fromView: base.applying(rawView))
            let result = EditorSnap.snapMove(movedDevice, candidates: candidates, threshold: snapThresholdDevice)
            let dt = mapping.deviceToView
            return (result.dx * dt.a, result.dy * dt.d, result.guideXs, result.guideYs)
        }

        /// Snaps a dragged POINT (a resize handle or a draw corner) to the candidates,
        /// returning the adjusted VIEW point and the device-space guide lines.
        private func snapViewPoint(state: DragState, view: CGPoint) -> (CGPoint, [CGFloat], [CGFloat]) {
            guard !state.snapDisabled, let candidates = state.snapCandidates else { return (view, [], []) }
            let device = mapping.devicePoint(fromView: view)
            let result = EditorSnap.snap(xEdges: [device.x], yEdges: [device.y], candidates: candidates, threshold: snapThresholdDevice)
            let dt = mapping.deviceToView
            return (CGPoint(x: view.x + result.dx * dt.a, y: view.y + result.dy * dt.d), result.guideXs, result.guideYs)
        }

        /// The live view-space transform for the current drag, used for the ghost.
        private func liveViewTransform(state: DragState, shift: Bool, option: Bool) -> CGAffineTransform {
            switch state.kind {
            case .move:
                let raw = CGAffineTransform(translationX: state.current.x - state.start.x, y: state.current.y - state.start.y)
                let (adjX, adjY, _, _) = moveSnap(state: state, rawView: raw)
                return raw.concatenating(CGAffineTransform(translationX: adjX, y: adjY))
            case .resize:
                guard let handle = state.handle, let box = state.startViewBounds else { return .identity }
                return EditorTransform.resizeTransform(
                    bounds: box, handle: handle,
                    translation: CGVector(dx: state.current.x - state.start.x, dy: state.current.y - state.start.y),
                    aspectLocked: shift, fromCenter: option
                )
            case .rotate:
                guard let box = state.startViewBounds else { return .identity }
                let centre = CGPoint(x: box.midX, y: box.midY)
                return EditorTransform.rotationTransform(center: centre, from: state.start, to: state.current)
            case .marquee, .shape, .pen:
                return .identity
            }
        }

        private func updateLiveTransform(state: DragState, shift: Bool, option: Bool) {
            if state.kind == .rotate, let box = state.startViewBounds {
                let centre = CGPoint(x: box.midX, y: box.midY)
                let degrees = EditorTransform.rotationDegrees(center: centre, from: state.start, to: state.current)
                // Write the readout only when the displayed integer-degree string changes, so an
                // unchanged value doesn't fire the observation (P2).
                let readout = String(format: "%.0f°", degrees)
                if parent.editorModel.rotationReadout != readout { parent.editorModel.rotationReadout = readout }
            }
            if state.kind == .move {
                // Capture the live smart-guide lines for the overlay (E3e).
                let raw = CGAffineTransform(translationX: state.current.x - state.start.x, y: state.current.y - state.start.y)
                let (_, _, gx, gy) = moveSnap(state: state, rawView: raw)
                drag?.snapGuideXsDevice = gx
                drag?.snapGuideYsDevice = gy
            }
            drag?.liveTransform = liveViewTransform(state: state, shift: shift, option: option)
        }

        /// The one committed command for a finished drag, or nil for a no-op.
        private func committedCommand(state: DragState, end: CGPoint, shift: Bool, option: Bool) -> (SceneCommand, SceneCoalescingKey?)? {
            let viewTransform = liveViewTransform(state: state, shift: shift, option: option)
            guard !viewTransform.isIdentity else { return nil }
            let ids = selection.ids
            guard !ids.isEmpty else { return nil }
            if state.kind == .move {
                // A pure move commits as .translate (one undo entry, cheap).
                let deviceMove = mapping.deviceTransform(fromView: viewTransform)
                return (.translate(ids: ids, dx: Double(deviceMove.tx), dy: Double(deviceMove.ty)), nil)
            }
            let deviceTransform = mapping.deviceTransform(fromView: viewTransform)
            return (.applyTransform(ids: ids, deviceTransform), nil)
        }

        // MARK: Keyboard

        /// Arrow nudges (1 device unit, 10 with Shift) coalesce into one undo entry;
        /// Esc cancels a drag or clears the selection; ⌘A selects all.
        func keyDown(_ event: NSEvent) -> Bool {
            if event.keyCode == 53 {   // Esc
                // An armed creation tool (shape, pen or text) disarms first, cancelling any draw.
                if isShapeToolArmed || isPenArmed || isTextToolArmed {
                    cancelDrag()
                    parent.editorModel.disarmTools()
                    if let overlay { overlay.window?.invalidateCursorRects(for: overlay) }
                    return true
                }
                if drag != nil { cancelDrag() } else if !selection.isEmpty { selection.clear(); overlay?.needsDisplay = true }
                return true
            }
            if event.keyCode == 51 || event.keyCode == 117 {   // Delete (⌫) or forward Delete
                if !selection.isEmpty { deleteSelection(); return true }
                return false
            }
            // ⌥Tab / ⌥⇧Tab cycle the selection (keyboard a11y, C5g). Plain Tab is left to
            // the normal focus loop so the canvas is never a keyboard trap (WCAG 2.1.2).
            if let forward = EditorAccessibility.selectionCycleDirection(
                keyCode: event.keyCode,
                optionDown: event.modifierFlags.contains(.option),
                shiftDown: event.modifierFlags.contains(.shift)) {
                return cycleSelection(forward: forward)
            }
            let large = event.modifierFlags.contains(.shift)
            // Arrow direction in VIEW space, then into device via the mapping.
            var viewDelta: CGVector?
            switch event.keyCode {
            case 126: viewDelta = CGVector(dx: 0, dy: large ? 10 : 1)    // up (y-up view → up)
            case 125: viewDelta = CGVector(dx: 0, dy: large ? -10 : -1)  // down
            case 123: viewDelta = CGVector(dx: large ? -10 : -1, dy: 0)  // left
            case 124: viewDelta = CGVector(dx: large ? 10 : 1, dy: 0)    // right
            default: break
            }
            if let viewDelta, !selection.isEmpty {
                let viewMove = CGAffineTransform(translationX: viewDelta.dx, y: viewDelta.dy)
                markDirtyRegion(old: selectionViewBounds(), viewTransform: viewMove)
                let device = mapping.deviceTransform(fromView: viewMove)
                parent.apply(.translate(ids: selection.ids, dx: Double(device.tx), dy: Double(device.ty)), EditorNudge.coalescingKey)
                return true
            }
            return false
        }
    }

    /// The transient state of a drag.
    fileprivate struct DragState {
        enum Kind { case marquee, move, resize, rotate, shape, pen }
        var kind: Kind
        var start: CGPoint
        var current: CGPoint
        var baseSelection: EditorSelection
        var handle: ResizeHandle?
        var startViewBounds: CGRect?
        var liveTransform: CGAffineTransform = .identity
        var ghost: CGImage?
        var ghostViewBounds: CGRect?
        /// The armed shape kind while `kind == .shape`.
        var shapeKind: ShapeToolKind?
        /// The constrained preview rect (view space) the overlay draws while sweeping.
        var shapePreviewRect: CGRect?
        /// The freehand sample points (overlay/view space) while `kind == .pen`.
        var penPoints: [CGPoint] = []
        /// Whether the pointer paused ≥ 0.5 s before release (snap-to-shape window).
        var penHoldElapsed = false
        /// The snapped shape preview (view-space rect) shown live during a hold, or nil.
        var penSnapPreview: ShapeRecognizer.Match?
        /// Snapping (E3e): candidates pre-collected once at drag start; the device-space
        /// guide lines currently shown; and whether ⌘ is disabling snapping this event.
        var snapCandidates: EditorSnap.Candidates?
        var snapGuideXsDevice: [CGFloat] = []
        var snapGuideYsDevice: [CGFloat] = []
        var snapDisabled = false
    }
}

// MARK: - Scroll view / clip view

private final class EditableScrollView: NSScrollView {
    var onLayout: ((CGSize) -> Void)?
    var onCommandScroll: ((NSEvent) -> Bool)?

    override func layout() {
        super.layout()
        onLayout?(contentView.frame.size)
    }
    override func scrollWheel(with event: NSEvent) {
        if allowsMagnification, event.modifierFlags.contains(.command), onCommandScroll?(event) == true { return }
        super.scrollWheel(with: event)
    }
}

private final class EditableCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let insets = enclosingScrollView?.safeAreaInsets ?? safeAreaInsets
        let sx = frame.width > 0 ? bounds.width / frame.width : 1
        let sy = frame.height > 0 ? bounds.height / frame.height : 1
        rect.origin = ViewerFit.centeredClipOrigin(
            proposed: rect.origin, content: documentView.frame.size, bounds: rect.size,
            insets: ViewerFit.Insets(top: insets.top * sy, leading: insets.left * sx, bottom: insets.bottom * sy, trailing: insets.right * sx)
        )
        return rect
    }
}

// MARK: - Tiled scene view

/// A `CATiledLayer`-backed view that draws the editable `Scene` through
/// `SceneRenderer` per tile, so the edited drawing stays crisp at any zoom (design
/// call E2b-2). `hiddenIDs` are skipped while a ghost drag is live.
private final class TiledSceneView: NSView {
    private let sceneLock: OSAllocatedUnfairLock<EMFEdit.Scene>
    private let hiddenLock = OSAllocatedUnfairLock<Set<Int>>(initialState: [])
    private let paintLock = OSAllocatedUnfairLock<TilePaint>(initialState: .plain)
    private let optionsLock: OSAllocatedUnfairLock<RenderOptions>
    /// The source lifecycle (E2b-3): the source is prepared once, off the main
    /// actor, when the canvas appears. While it is `.preparing`, tiles paint only
    /// the page background rather than each preparing the whole file internally.
    private let sourceStateLock = OSAllocatedUnfairLock<TileRenderSource>(initialState: .notNeeded)
    private var sourcePrepStarted = false
    private let pageSize: CGSize

    init(scene: EMFEdit.Scene, pageSize: CGSize, options: RenderOptions) {
        self.sceneLock = OSAllocatedUnfairLock<EMFEdit.Scene>(initialState: scene)
        self.optionsLock = OSAllocatedUnfairLock<RenderOptions>(initialState: options)
        self.pageSize = pageSize
        super.init(frame: CGRect(origin: .zero, size: pageSize))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer {
        let tiled = CATiledLayer()
        tiled.levelsOfDetail = ZoomMath.tiledLevelsOfDetail(forLongSide: max(pageSize.width, pageSize.height))
        tiled.levelsOfDetailBias = 4
        tiled.tileSize = CGSize(width: 512, height: 512)
        tiled.contentsScale = window?.backingScaleFactor ?? 2
        return tiled
    }

    override var isFlipped: Bool { false }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        if let tiled = layer as? CATiledLayer, tiled.contentsScale != scale {
            tiled.contentsScale = scale
            setNeedsDisplay(bounds)
        }
    }

    /// A view-space region to invalidate on the next `setScene` instead of the whole
    /// view, so a committed move/resize/nudge only repaints the changed tiles (E2b item
    /// 5). Set on the main thread by the coordinator before it applies the edit.
    var pendingDirtyRegion: CGRect?

    /// The prepared render source once ready, so the ghost rasteriser can reuse the one
    /// file parse/observe instead of re-parsing on the main thread at drag start (P1).
    var readyRenderSource: SceneRenderer.SceneRenderSource? {
        if case .ready(let source) = sourceStateLock.withLock({ $0 }) { return source }
        return nil
    }

    /// Prepares the render source once, off the main actor, for a scene that needs
    /// it (replay/passthrough/EMF+). A pure-geometry scene needs none, so this is a
    /// no-op there. When the source lands, the whole view redraws so every tile
    /// starts reusing it (E2b-3).
    func ensureSourcePrepared() {
        guard !sourcePrepStarted else { return }
        let scene = sceneLock.withLock { $0 }
        guard SceneRenderer.requiresPreparedSource(scene) else { return }   // stays .notNeeded
        sourcePrepStarted = true
        sourceStateLock.withLock { $0 = .preparing }
        let lock = sourceStateLock
        Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) { SceneRenderer.prepare(scene) }.value
            lock.withLock { $0 = prepared.map { .ready($0) } ?? .failed }
            guard let self else { return }
            self.setNeedsDisplay(self.bounds)
            self.layer?.setNeedsDisplay()
        }
    }

    /// The edit version of the scene last stored, so an `updateView` that did not change the
    /// scene (a slider tick on an unrelated control, arming a tool, opening the text popover)
    /// skips the full-view repaint entirely (P8). `Int.min` forces the first store.
    private var lastSceneVersion = Int.min

    func setScene(_ scene: EMFEdit.Scene, version: Int) {
        // Unchanged scene ⇒ nothing to repaint. The tiles already hold this scene.
        guard version != lastSceneVersion else { return }
        lastSceneVersion = version
        sceneLock.withLock { $0 = scene }
        if let region = pendingDirtyRegion {
            pendingDirtyRegion = nil
            setNeedsDisplay(region)
            (layer as? CATiledLayer)?.setNeedsDisplay(region)
        } else {
            setNeedsDisplay(bounds)
            layer?.setNeedsDisplay()
        }
    }
    func setHiddenIDs(_ ids: Set<Int>) {
        let changed = hiddenLock.withLock { current -> Bool in
            guard current != ids else { return false }; current = ids; return true
        }
        if changed { setNeedsDisplay(bounds); layer?.setNeedsDisplay() }
    }
    func setPaint(_ paint: TilePaint) {
        let changed = paintLock.withLock { current -> Bool in guard current != paint else { return false }; current = paint; return true }
        if changed { setNeedsDisplay(bounds); layer?.setNeedsDisplay() }
    }
    func setOptions(_ options: RenderOptions) {
        let changed = optionsLock.withLock { current -> Bool in guard current != options else { return false }; current = options; return true }
        if changed { setNeedsDisplay(bounds); layer?.setNeedsDisplay() }
    }

    nonisolated override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let paint = paintLock.withLock { $0 }
        let hidden = hiddenLock.withLock { $0 }
        let state = sourceStateLock.withLock { $0 }
        let natural = pageSize
        // While a needed source is still preparing, paint only the page background —
        // never prepare per tile (that would run one full-file parse per visible tile
        // on the tiled layer's threads). The redraw on arrival paints the ink (E2b-3).
        if state.tileAction == .backgroundOnly {
            TilePainter.paint(paint, into: context, rect: dirtyRect) { _ in }
            return
        }
        var scene = sceneLock.withLock { $0 }
        if !hidden.isEmpty { scene = SceneGhostSupport.hiding(ids: hidden, in: scene) }
        // Only the elements that reach this tile are rendered, so a tile's cost is
        // bounded by its own content rather than the whole scene (E2b item 5). The Mac
        // tiled view is y-up, matching SceneRenderer's target (flipY: true).
        let tileScene = SceneTileFilter.subscene(scene, viewRect: dirtyRect, target: CGRect(origin: .zero, size: natural), flipY: true)
        TilePainter.paint(paint, into: context, rect: dirtyRect) { ctx in
            // Reuse the prepared source so the tile doesn't re-parse the file (E2b-3).
            if case .ready(let source) = state {
                SceneRenderer.render(tileScene, into: ctx, target: CGRect(origin: .zero, size: natural), source: source)
            } else {   // .notNeeded (pure geometry) or .failed (prepare returned nil)
                SceneRenderer.render(tileScene, into: ctx, target: CGRect(origin: .zero, size: natural))
            }
        }
    }
}

// MARK: - Overlay

/// The transparent overlay on top of the tiled scene: it draws the selection
/// outlines, the eight handles, the marquee and the live ghost, and routes pointer
/// and keyboard events to the coordinator. Handles are drawn at a constant screen
/// size by dividing by the magnification.
private final class EditorOverlayView: NSView, NSMenuItemValidation {
    weak var coordinator: MacEditableCanvas.Coordinator?

    /// The scene's undo manager. As first responder in edit mode this view handles the
    /// Edit ▸ Undo/Redo items (and ⌘Z/⇧⌘Z), so they drive `SceneHistory` directly through
    /// the responder chain — not the window's cached undo manager, which SwiftUI owns and
    /// never routes here (E2d).
    var sceneUndoManager: UndoManager?

    /// The find highlights to draw under the selection in edit mode (F3b).
    var findHighlights: FindHighlightSet = .empty

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func becomeFirstResponder() -> Bool { true }

    /// The right-click Arrange / Move-to-Layer menu for a selection (E3d).
    override func menu(for event: NSEvent) -> NSMenu? {
        coordinator?.contextMenu()
    }

    // MARK: Undo / redo (first-responder handler for the Edit menu + ⌘Z/⇧⌘Z)

    override var undoManager: UndoManager? { sceneUndoManager ?? super.undoManager }

    @objc func undo(_ sender: Any?) { sceneUndoManager?.undo() }
    @objc func redo(_ sender: Any?) { sceneUndoManager?.redo() }

    /// Enables the Undo/Redo menu items when the scene history allows, and sets their
    /// titles to the step name ("Undo Change Fill", "Redo Move") — the responder-chain
    /// equivalent of NSWindow's automatic undo-menu titling (NSMenuItemValidation).
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            if let manager = sceneUndoManager { item.title = manager.undoMenuItemTitle }
            return sceneUndoManager?.canUndo ?? false
        case #selector(redo(_:)):
            if let manager = sceneUndoManager { item.title = manager.redoMenuItemTitle }
            return sceneUndoManager?.canRedo ?? false
        default:
            // Only reached for actions this view implements (undo:/redo:); other items
            // are validated against their own targets, not this one.
            return true
        }
    }

    private var magnification: CGFloat { coordinator?.magnification ?? 1 }

    // MARK: Accessibility (C5g / audit A1)

    override func isAccessibilityElement() -> Bool { false }   // a container of per-element elements
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Drawing canvas" }
    override func accessibilityChildren() -> [Any]? { buildAccessibilityChildren() }

    /// One `NSAccessibilityElement` per editable element, driven by the shared model: the
    /// same labels, values and custom actions as iOS, each routing back through the
    /// coordinator (the same scene commands as pointer edits). Rebuilt each read so the
    /// frames track the live zoom and scroll. Locked elements are static text with no
    /// actions.
    private func buildAccessibilityChildren() -> [Any] {
        guard let coordinator else { return [] }
        return coordinator.accessibilityDescriptors().map { descriptor -> MacEditorAXElement in
            let id = descriptor.id
            let element = MacEditorAXElement()
            element.coordinator = coordinator
            element.elementID = id
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(descriptor.isLocked ? .staticText : .button)
            element.setAccessibilityLabel(descriptor.label)
            element.setAccessibilityValue(descriptor.value)
            element.setAccessibilityFrame(screenFrame(forDevice: descriptor.boundsDevice))
            element.setAccessibilitySelected(descriptor.isSelected)
            element.setAccessibilityCustomActions(descriptor.actions.map { action in
                NSAccessibilityCustomAction(name: action.name) { [weak coordinator] in
                    // VoiceOver invokes this on the main thread; the coordinator is @MainActor.
                    MainActor.assumeIsolated { coordinator?.accessibilityPerform(action, on: id) ?? false }
                }
            })
            return element
        }
    }

    /// The element's device bounds in SCREEN coordinates, for `NSAccessibilityElement`.
    /// The overlay is scaled by the scroll view magnification, which `convert(_:to:nil)`
    /// folds in, so the frame stays correct at any zoom.
    private func screenFrame(forDevice bounds: CGRect) -> NSRect {
        guard let coordinator, let window else { return .zero }
        let viewRect = coordinator.mapping.viewRect(fromDevice: bounds)
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    #if DEBUG
    /// A text dump of the live accessibility tree (label, value, traits, actions) — the
    /// DEBUG evidence hook.
    func debugAccessibilityDump() -> String {
        coordinator?.debugAccessibilityDump() ?? "no coordinator"
    }
    #endif

    // MARK: Drawing

    /// Draws the 10 mm editing grid over the page in paper-view space (E3e design call 2),
    /// subdividing when the major cell is large on screen so it stays crisp at any zoom.
    private func drawGrid(coordinator: MacEditableCanvas.Coordinator, into context: CGContext, mag: CGFloat) {
        let scene = coordinator.scene
        let page = scene.pageBoundsDevice.standardized
        let perInch = scene.deviceUnitsPerInch ?? 96
        let major = EditorGrid.deviceSpacing(deviceUnitsPerInch: perInch)
        guard major > 0, page.width > 0, page.height > 0 else { return }
        let mapping = coordinator.mapping
        let dt = mapping.deviceToView
        let onScreenMajor = major * abs(dt.a) * mag
        let subdivisions = EditorGrid.subdivisions(onScreenMajorPoints: onScreenMajor)
        let fine = major / CGFloat(subdivisions)
        guard fine > 0, page.width / fine < 5000 else { return }   // never flood on a huge page

        // Fixed neutral ink, independent of the window appearance — the paper is always
        // white, so a semantic colour (which goes light in Dark Mode) would vanish (E3e review).
        let minor = NSColor(white: 0, alpha: 0.06)
        let majorColor = NSColor(white: 0, alpha: 0.12)
        let topView = mapping.viewPoint(fromDevice: CGPoint(x: page.minX, y: page.minY)).y
        let bottomView = mapping.viewPoint(fromDevice: CGPoint(x: page.minX, y: page.maxY)).y

        // Vertical lines (constant device x).
        var index = 0
        var deviceX = page.minX
        while deviceX <= page.maxX + 0.001 {
            let vx = mapping.viewPoint(fromDevice: CGPoint(x: deviceX, y: page.minY)).x
            let isMajor = index % subdivisions == 0
            context.setStrokeColor((isMajor ? majorColor : minor).cgColor)
            context.setLineWidth((isMajor ? 1 : 0.5) / mag)
            context.beginPath()
            context.move(to: CGPoint(x: vx, y: topView))
            context.addLine(to: CGPoint(x: vx, y: bottomView))
            context.strokePath()
            index += 1
            deviceX = page.minX + CGFloat(index) * fine
        }
        // Horizontal lines (constant device y).
        let leftView = mapping.viewPoint(fromDevice: CGPoint(x: page.minX, y: page.minY)).x
        let rightView = mapping.viewPoint(fromDevice: CGPoint(x: page.maxX, y: page.minY)).x
        index = 0
        var deviceY = page.minY
        while deviceY <= page.maxY + 0.001 {
            let vy = mapping.viewPoint(fromDevice: CGPoint(x: page.minX, y: deviceY)).y
            let isMajor = index % subdivisions == 0
            context.setStrokeColor((isMajor ? majorColor : minor).cgColor)
            context.setLineWidth((isMajor ? 1 : 0.5) / mag)
            context.beginPath()
            context.move(to: CGPoint(x: leftView, y: vy))
            context.addLine(to: CGPoint(x: rightView, y: vy))
            context.strokePath()
            index += 1
            deviceY = page.minY + CGFloat(index) * fine
        }
    }

    /// Draws the smart-guide lines (device coords mapped to view) while a drag is snapped.
    private func drawSnapGuides(_ drag: MacEditableCanvas.DragState, coordinator: MacEditableCanvas.Coordinator, into context: CGContext, mag: CGFloat) {
        let mapping = coordinator.mapping
        let page = coordinator.scene.pageBoundsDevice.standardized
        context.setStrokeColor(NSColor.systemYellow.cgColor)
        context.setLineWidth(1 / mag)
        let topV = mapping.viewPoint(fromDevice: CGPoint(x: page.minX, y: page.minY)).y
        let botV = mapping.viewPoint(fromDevice: CGPoint(x: page.minX, y: page.maxY)).y
        let leftV = mapping.viewPoint(fromDevice: CGPoint(x: page.minX, y: page.minY)).x
        let rightV = mapping.viewPoint(fromDevice: CGPoint(x: page.maxX, y: page.minY)).x
        for dx in drag.snapGuideXsDevice {
            let vx = mapping.viewPoint(fromDevice: CGPoint(x: dx, y: page.minY)).x
            context.beginPath(); context.move(to: CGPoint(x: vx, y: topV)); context.addLine(to: CGPoint(x: vx, y: botV)); context.strokePath()
        }
        for dy in drag.snapGuideYsDevice {
            let vy = mapping.viewPoint(fromDevice: CGPoint(x: page.minX, y: dy)).y
            context.beginPath(); context.move(to: CGPoint(x: leftV, y: vy)); context.addLine(to: CGPoint(x: rightV, y: vy)); context.strokePath()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let coordinator, let context = NSGraphicsContext.current?.cgContext else { return }
        let mag = magnification
        let accent = NSColor.controlAccentColor

        // Editing grid (E3e design call 2): light semantic lines in the overlay, crisp at
        // any zoom; editor-only, never exported.
        if coordinator.parent.editorModel.showGrid { drawGrid(coordinator: coordinator, into: context, mag: mag) }

        // Find highlights (F3b): under the selection chrome, mapped through the editor's
        // own device→paper mapping so they land on the glyphs.
        if !findHighlights.isEmpty {
            let mapping = coordinator.mapping
            let all = findHighlights.matchDeviceRects.map { mapping.viewRect(fromDevice: $0) }
            let current = findHighlights.currentDeviceRect.map { mapping.viewRect(fromDevice: $0) }
            FindHighlightPainter.paint(all: all, current: current, into: context, onScreenScale: mag)
        }

        // Live ghost during a drag.
        if let drag = coordinator.drag, drag.kind != .marquee, let ghost = drag.ghost, let bounds = drag.ghostViewBounds {
            context.saveGState()
            context.concatenate(drag.liveTransform)
            context.setAlpha(0.85)
            context.draw(ghost, in: bounds)
            context.restoreGState()
        }

        // Marquee rectangle.
        if let drag = coordinator.drag, drag.kind == .marquee {
            let rect = CGRect(x: min(drag.start.x, drag.current.x), y: min(drag.start.y, drag.current.y),
                              width: abs(drag.current.x - drag.start.x), height: abs(drag.current.y - drag.start.y))
            context.setFillColor(accent.withAlphaComponent(0.12).cgColor)
            context.fill(rect)
            context.setStrokeColor(accent.cgColor)
            context.setLineWidth(1 / mag)
            context.stroke(rect)
        }

        // Live shape-tool preview (view space, design call 5).
        if let drag = coordinator.drag, drag.kind == .shape, let kind = drag.shapeKind, let rect = drag.shapePreviewRect {
            let cornerRadius = ShapeToolGeometry.pointsToDevice(16, deviceUnitsPerPoint: coordinator.scene.deviceUnitsPerPoint)
            Self.strokeShapePreview(kind: kind, rect: rect, into: context, lineWidth: 1.5 / mag, accent: accent, cornerRadius: cornerRadius)
        }

        // Live pen preview (view space, design call 1/4): the snapped shape during a hold,
        // else the raw freehand trace, both in the pen's own colour.
        if let drag = coordinator.drag, drag.kind == .pen {
            let penColor = coordinator.penPreviewColor()
            if let match = drag.penSnapPreview {
                let viewRect = Self.penSnapViewRect(match, mapping: coordinator.mapping)
                let penNSColor = NSColor(cgColor: penColor) ?? accent
                Self.strokeShapePreview(kind: match.kind, rect: viewRect, into: context, lineWidth: coordinator.penPreviewWidthDevice, accent: penNSColor, cornerRadius: 0)
            } else if drag.penPoints.count > 1 {
                context.setStrokeColor(penColor)
                context.setLineWidth(coordinator.penPreviewWidthDevice)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.beginPath()
                context.move(to: drag.penPoints[0])
                for p in drag.penPoints.dropFirst() { context.addLine(to: p) }
                context.strokePath()
            }
        }

        // Live smart-guide lines while a drag is snapped (E3e design call 3).
        if let drag = coordinator.drag, !drag.snapGuideXsDevice.isEmpty || !drag.snapGuideYsDevice.isEmpty {
            drawSnapGuides(drag, coordinator: coordinator, into: context, mag: mag)
        }

        // Per-element selection outlines (thin accent box of each element's bounds).
        let draggingTransform = coordinator.drag.flatMap { $0.kind == .marquee ? nil : $0.liveTransform }
        context.saveGState()
        if let draggingTransform { context.concatenate(draggingTransform) }
        context.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1 / mag)
        coordinator.scene.forEachElement { element in
            guard coordinator.selection.contains(element.id) else { return }
            let box = coordinator.mapping.viewRect(fromDevice: element.selectionBoundsDevice)
            if !box.isNull { context.stroke(box.insetBy(dx: -0.5 / mag, dy: -0.5 / mag)) }
        }
        context.restoreGState()

        // Selection bounding box + 8 handles (constant screen size). While dragging
        // the box follows the live transform.
        if let box = coordinator.selectionViewBounds() {
            context.saveGState()
            if let draggingTransform { context.concatenate(draggingTransform) }
            context.setStrokeColor(accent.cgColor)
            context.setLineWidth(1.5 / mag)
            context.stroke(box)
            context.restoreGState()

            // Handles are drawn in the UN-transformed box while idle; during a drag
            // they ride the transformed box so they stay on the ghost.
            let handleBox = draggingTransform.map { box.applying($0) } ?? box
            let size = MacEditableCanvas.Coordinator.handleDrawSize / mag
            for handle in ResizeHandle.allCases {
                let p = handle.point(in: handleBox)
                let r = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
                // Fix A (E3e): a subtle dark outer ring under the white fill, so the handle
                // reads on any colour (white dots vanished over blue fills).
                context.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
                context.setLineWidth(3 / mag)
                context.stroke(r.insetBy(dx: -0.75 / mag, dy: -0.75 / mag))
                context.setFillColor(NSColor.white.cgColor)
                context.fill(r)
                context.setStrokeColor(accent.cgColor)
                context.setLineWidth(1.5 / mag)
                context.stroke(r)
            }
        }
    }

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            coordinator?.doubleClick(at: p)
            return
        }
        coordinator?.mouseDown(at: p, shift: event.modifierFlags.contains(.shift), command: event.modifierFlags.contains(.command))
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        coordinator?.mouseDragged(to: p, shift: event.modifierFlags.contains(.shift),
                                  option: event.modifierFlags.contains(.option),
                                  command: event.modifierFlags.contains(.command))
    }
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        coordinator?.mouseUp(at: p, shift: event.modifierFlags.contains(.shift), option: event.modifierFlags.contains(.option))
    }
    override func keyDown(with event: NSEvent) {
        if coordinator?.keyDown(event) == true { return }
        super.keyDown(with: event)
    }

    // MARK: Drag-and-drop image (E3c)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.droppableImageData(sender) != nil ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.droppableImageData(sender) != nil ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let data = Self.droppableImageData(sender) else { return false }
        coordinator?.handleImageDrop(data, at: convert(sender.draggingLocation, from: nil))
        return true
    }

    /// The image bytes for a drop: a dragged image FILE's contents (preferred, so the
    /// capped, metadata-stripping ingest sees the real file), else an image rendition on
    /// the pasteboard.
    private static func droppableImageData(_ sender: NSDraggingInfo) -> Data? {
        let pb = sender.draggingPasteboard
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           let url = urls.first, let data = try? Data(contentsOf: url) {
            return data
        }
        return pb.data(forType: .png) ?? pb.data(forType: .tiff)
    }

    /// Strokes (and lightly fills, for closed kinds) the shape-tool preview outline in
    /// the overlay's view space. `rect` may carry a signed size (a line keeps its drag
    /// direction); closed kinds use its standardised box.
    static func strokeShapePreview(kind: ShapeToolKind, rect: CGRect, into context: CGContext, lineWidth: CGFloat, accent: NSColor, cornerRadius: CGFloat) {
        context.setStrokeColor(accent.cgColor)
        context.setFillColor(accent.withAlphaComponent(0.15).cgColor)
        context.setLineWidth(lineWidth)
        let box = rect.standardized
        switch kind {
        case .line:
            context.move(to: rect.origin)
            context.addLine(to: CGPoint(x: rect.origin.x + rect.size.width, y: rect.origin.y + rect.size.height))
            context.strokePath()
        case .rect:
            context.fill(box); context.stroke(box)
        case .roundRect:
            let r = min(cornerRadius, min(box.width, box.height) / 2)
            let path = CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil)
            context.addPath(path); context.fillPath()
            context.addPath(path); context.strokePath()
        case .ellipse:
            context.fillEllipse(in: box); context.strokeEllipse(in: box)
        case .triangle:
            context.move(to: CGPoint(x: box.midX, y: box.maxY))
            context.addLine(to: CGPoint(x: box.maxX, y: box.minY))
            context.addLine(to: CGPoint(x: box.minX, y: box.minY))
            context.closePath()
            context.drawPath(using: .fillStroke)
        }
    }

    /// The view-space rect for a snapped-shape preview, keeping a line's drawn direction by
    /// mapping its two endpoints individually.
    static func penSnapViewRect(_ match: ShapeRecognizer.Match, mapping: EditorCanvasMapping) -> CGRect {
        guard match.kind == .line else { return mapping.viewRect(fromDevice: match.rect) }
        let origin = mapping.viewPoint(fromDevice: match.rect.origin)
        let far = mapping.viewPoint(fromDevice: CGPoint(x: match.rect.origin.x + match.rect.width, y: match.rect.origin.y + match.rect.height))
        return CGRect(origin: origin, size: CGSize(width: far.x - origin.x, height: far.y - origin.y))
    }

    // MARK: Cursors

    override func resetCursorRects() {
        // An armed creation tool (shape, pen or text) shows a crosshair across the canvas.
        if coordinator?.isShapeToolArmed == true || coordinator?.isPenArmed == true || coordinator?.isTextToolArmed == true {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }
        guard let coordinator, let box = coordinator.selectionViewBounds() else { return }
        let size = MacEditableCanvas.Coordinator.handleHitRadius / magnification
        for handle in ResizeHandle.allCases {
            let p = handle.point(in: box)
            let rect = CGRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2)
            addCursorRect(rect, cursor: Self.cursor(for: handle))
        }
    }

    private static func cursor(for handle: ResizeHandle) -> NSCursor {
        // The overlay is y-up (NSView default), so a handle whose point uses the
        // smaller y (`ResizeHandle` "top") sits at the VISUAL bottom; flip the
        // vertical sense here so the cursor matches where the handle appears.
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch handle {
            case .topLeft: position = .bottomLeft
            case .top: position = .bottom
            case .topRight: position = .bottomRight
            case .right: position = .right
            case .bottomRight: position = .topRight
            case .bottom: position = .top
            case .bottomLeft: position = .topLeft
            case .left: position = .left
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }
}

// MARK: - Accessibility element (C5g / audit A1)

/// An `NSAccessibilityElement` for one editable scene element, so VoiceOver / Full
/// Keyboard Access / Switch Control can select it (press) and reach its custom actions —
/// the same operations the pointer and keyboard drive.
private final class MacEditorAXElement: NSAccessibilityElement {
    weak var coordinator: MacEditableCanvas.Coordinator?
    var elementID: Int = -1

    override func accessibilityPerformPress() -> Bool {
        let coordinator = self.coordinator
        let id = self.elementID
        return MainActor.assumeIsolated {
            guard let coordinator else { return false }
            return coordinator.accessibilityPerform(.select, on: id)
        }
    }
}
