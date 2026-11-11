import AppKit
import CoreGraphics
import EMFEdit
import EMFRender
import Foundation
import os
import SwiftUI

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

    var body: some View {
        @Bindable var editorModel = editorModel
        let _ = session.editVersion
        Group {
            if let scene = session.editingScene {
                MacEditableCanvas(
                    scene: scene, editorModel: editorModel, controller: controller,
                    pageShadow: pageShadow, tilePaint: tilePaint, options: options,
                    apply: { command, key in session.apply(command, coalescing: key) },
                    delete: { ids in session.deleteSelection(ids) }
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
        // Undo/redo of a delete restores the selection through this hook (design call E2c-4).
        .onAppear { session.selectionRestore = { ids in editorModel.selection.replace(with: ids) } }
        // The double-click text-edit popover, anchored to the run via a UnitPoint so the
        // arrow points at the glyphs (design call E2c-5).
        .popover(item: $editorModel.textEdit, attachmentAnchor: .point(editorModel.textEdit?.anchor ?? .center), arrowEdge: .top) { request in
            TextEditPopover(
                request: request,
                onCommit: { string in session.apply(.setText(id: request.id, string)) },
                onCancel: {},
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
    let controller: MacMetafileZoomController
    var pageShadow: Bool = true
    var tilePaint: TilePaint = .plain
    var options: RenderOptions = .default
    /// Commits one undoable mutation through `DocumentSession.apply`.
    let apply: (SceneCommand, SceneCoalescingKey?) -> Void
    /// Deletes the given ids as one undoable step (design call E2c-4).
    let delete: (Set<Int>) -> Void

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
        context.coordinator.tiledView?.setScene(scene)
        context.coordinator.tiledView?.ensureSourcePrepared()
        context.coordinator.tiledView?.setPaint(tilePaint)
        context.coordinator.tiledView?.setOptions(options)
        scrollView.documentView?.shadow = pageShadow ? MacMetafileScrollView.makePaperShadow() : nil
        controller.scrollView = scrollView
        // A scene/selection change (undo, redo, a committed edit) redraws the overlay.
        if let overlay = context.coordinator.overlay {
            overlay.needsDisplay = true
            overlay.window?.invalidateCursorRects(for: overlay)
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
        private var lastViewportSize: CGSize = .zero
        private static let fitMargin: CGFloat = 24

        /// Live drag state. `nil` between drags.
        fileprivate var drag: DragState?

        init(_ parent: MacEditableCanvas) {
            self.parent = parent
            super.init()
        }

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
            let fit = ViewerFit.fitScale(content: natural, viewport: viewport, insets: insets, margin: Self.fitMargin, minScale: 0.01, maxScale: ZoomMath.maxZoom)
            let wasFitted = !hasSetInitialZoom || ZoomMath.wasFitted(current: scrollView.magnification, fit: parent.controller.fitScale)
            scrollView.minMagnification = ZoomMath.minMagnification(fit: fit)
            scrollView.maxMagnification = ZoomMath.maxMagnification(fit: fit)
            parent.controller.fitScale = fit
            if !hasSetInitialZoom {
                hasSetInitialZoom = true
                setMagnification(fit)
                DispatchQueue.main.async { [weak scrollView, weak overlay] in
                    guard let scrollView, scrollView.window?.firstResponder !== overlay else { return }
                    if let overlay { scrollView.window?.makeFirstResponder(overlay) }
                }
            } else if viewport != lastViewportSize, wasFitted {
                setMagnification(fit)
            }
            lastViewportSize = viewport
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

        /// The selection's bounding box in paper-view coordinates, or nil.
        func selectionViewBounds() -> CGRect? {
            guard let deviceBox = selection.boundsDevice(in: scene) else { return nil }
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

        func mouseDown(at viewPoint: CGPoint, shift: Bool, command: Bool) {
            overlay?.window?.makeFirstResponder(overlay)
            parent.editorModel.rotationReadout = nil

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

        func mouseDragged(to viewPoint: CGPoint, shift: Bool, option: Bool) {
            guard var state = drag else { return }
            state.current = viewPoint
            drag = state
            switch state.kind {
            case .marquee:
                let rect = CGRect(x: min(state.start.x, viewPoint.x), y: min(state.start.y, viewPoint.y),
                                  width: abs(viewPoint.x - state.start.x), height: abs(viewPoint.y - state.start.y))
                let deviceRect = mapping.deviceRect(fromView: rect)
                var next = state.baseSelection
                next.replace(with: EditorHitTest.marquee(in: scene, deviceRect: deviceRect))
                selection = next
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
                break   // selection already updated live
            case .move, .resize, .rotate:
                if let (command, key) = committedCommand(state: state, end: viewPoint, shift: shift, option: option) {
                    markDirtyRegion(old: state.startViewBounds ?? selectionViewBounds(),
                                    viewTransform: liveViewTransform(state: state, shift: shift, option: option))
                    parent.apply(command, key)
                }
            }
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
                  let element = scene.elements.first(where: { $0.id == id }),
                  element.kind == .text else { return }
            presentTextEdit(for: id)
        }

        /// Opens the text-edit popover for a text element, anchored to the run. Shared by
        /// double-click and the DEBUG hook.
        func presentTextEdit(for id: Int) {
            guard let element = scene.elements.first(where: { $0.id == id }),
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

        // MARK: Drag kinds

        private func beginMove(at viewPoint: CGPoint) {
            drag = DragState(kind: .move, start: viewPoint, current: viewPoint, baseSelection: selection)
            prepareGhost()
        }
        private func beginResize(handle: ResizeHandle, at viewPoint: CGPoint) {
            var state = DragState(kind: .resize, start: viewPoint, current: viewPoint, baseSelection: selection)
            state.handle = handle
            state.startViewBounds = selectionViewBounds()
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
            drag?.ghost = GhostRasterizer.image(scene: scene, ids: selection.ids, deviceBounds: deviceBox, pixelScale: max(1, magnification) * (overlay?.window?.backingScaleFactor ?? 2))
            tiledView?.setHiddenIDs(selection.ids)
        }

        /// The live view-space transform for the current drag, used for the ghost.
        private func liveViewTransform(state: DragState, shift: Bool, option: Bool) -> CGAffineTransform {
            switch state.kind {
            case .move:
                return CGAffineTransform(translationX: state.current.x - state.start.x, y: state.current.y - state.start.y)
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
            case .marquee:
                return .identity
            }
        }

        private func updateLiveTransform(state: DragState, shift: Bool, option: Bool) {
            if state.kind == .rotate, let box = state.startViewBounds {
                let centre = CGPoint(x: box.midX, y: box.midY)
                let degrees = EditorTransform.rotationDegrees(center: centre, from: state.start, to: state.current)
                parent.editorModel.rotationReadout = String(format: "%.0f°", degrees)
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
                if drag != nil { cancelDrag() } else if !selection.isEmpty { selection.clear(); overlay?.needsDisplay = true }
                return true
            }
            if event.keyCode == 51 || event.keyCode == 117 {   // Delete (⌫) or forward Delete
                if !selection.isEmpty { deleteSelection(); return true }
                return false
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
        enum Kind { case marquee, move, resize, rotate }
        var kind: Kind
        var start: CGPoint
        var current: CGPoint
        var baseSelection: EditorSelection
        var handle: ResizeHandle?
        var startViewBounds: CGRect?
        var liveTransform: CGAffineTransform = .identity
        var ghost: CGImage?
        var ghostViewBounds: CGRect?
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

    func setScene(_ scene: EMFEdit.Scene) {
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
private final class EditorOverlayView: NSView {
    weak var coordinator: MacEditableCanvas.Coordinator?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func becomeFirstResponder() -> Bool { true }

    private var magnification: CGFloat { coordinator?.magnification ?? 1 }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let coordinator, let context = NSGraphicsContext.current?.cgContext else { return }
        let mag = magnification
        let accent = NSColor.controlAccentColor

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

        // Per-element selection outlines (thin accent box of each element's bounds).
        let draggingTransform = coordinator.drag.flatMap { $0.kind == .marquee ? nil : $0.liveTransform }
        context.saveGState()
        if let draggingTransform { context.concatenate(draggingTransform) }
        context.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1 / mag)
        for element in coordinator.scene.elements where coordinator.selection.contains(element.id) {
            let box = coordinator.mapping.viewRect(fromDevice: element.boundsDevice)
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
        coordinator?.mouseDragged(to: p, shift: event.modifierFlags.contains(.shift), option: event.modifierFlags.contains(.option))
    }
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        coordinator?.mouseUp(at: p, shift: event.modifierFlags.contains(.shift), option: event.modifierFlags.contains(.option))
    }
    override func keyDown(with event: NSEvent) {
        if coordinator?.keyDown(event) == true { return }
        super.keyDown(with: event)
    }

    // MARK: Cursors

    override func resetCursorRects() {
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
