import CoreGraphics
import EMFEdit
import EMFRender
import Foundation
import os
import SwiftUI
import UIKit

/// The iPad edit-mode detail content: it reads the editing `Scene` from the session
/// (keyed on `editVersion`) and hosts the interactive canvas, kept here so the
/// viewer screen never names EMFEdit types.
struct MetafileEditingContainer: View {
    let session: DocumentSession
    let editorModel: EditorModel
    let controller: MetafileZoomController
    var displayScale: CGFloat = 2
    var tilePaint: TilePaint = .plain
    var options: RenderOptions = .default
    /// Trailing width the inspector overlay occupies, so the drawing fits/centres into
    /// the clear region while the canvas itself fills the full width (E2c item 4).
    var trailingInset: CGFloat = 0

    var body: some View {
        @Bindable var editorModel = editorModel
        let _ = session.editVersion
        Group {
            if let scene = session.editingScene {
                EditableMetafileCanvas(
                    scene: scene, editorModel: editorModel, controller: controller,
                    displayScale: displayScale, tilePaint: tilePaint, options: options,
                    apply: { command, key in session.apply(command, coalescing: key) },
                    delete: { ids in session.deleteSelection(ids) },
                    // The scene's undo manager, vended by the overlay as first responder so
                    // ⌘Z/⇧⌘Z and the three-finger undo/redo gestures drive SceneHistory (E2d).
                    sceneUndoManager: session.undoManager,
                    trailingInset: trailingInset
                )
                .ignoresSafeArea()
            } else {
                Color(.systemGroupedBackground)
            }
        }
        .onChange(of: session.editVersion) { _, _ in
            if let scene = session.editingScene { editorModel.selection.prune(to: scene) }
        }
        // Undo/redo of a delete restores the selection (design call E2c-4).
        .onAppear { session.selectionRestore = { ids in editorModel.selection.replace(with: ids) } }
        // The double-tap text-edit popover, anchored to the run via a UnitPoint (E2c-5).
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

/// The iPad editor canvas (E2b, design calls 2/5/6): a `UIScrollView` wrapping the
/// tiled scene surface (fed by `SceneRenderer`, crisp at any zoom) with an
/// interactive selection overlay. Tap selects; a one-finger drag on the selection
/// moves it and on a handle resizes it; a two-finger rotation that starts on the
/// selection rotates it. Each drag rasterises a one-shot ghost and commits exactly
/// one `apply` on release (design call E2b-6). Pinch and two-finger pan still zoom
/// and scroll.
struct EditableMetafileCanvas: UIViewRepresentable {
    let scene: EMFEdit.Scene
    let editorModel: EditorModel
    let controller: MetafileZoomController
    var displayScale: CGFloat = 2
    var tilePaint: TilePaint = .plain
    var options: RenderOptions = .default
    let apply: (SceneCommand, SceneCoalescingKey?) -> Void
    /// Deletes the given ids as one undoable step (design call E2c-4).
    let delete: (Set<Int>) -> Void
    /// The scene's undo manager, vended by the overlay as first responder (E2d).
    let sceneUndoManager: UndoManager
    /// Trailing width the inspector overlay occupies (E2c item 4).
    var trailingInset: CGFloat = 0

    private var pageSize: CGSize { scene.pageSizeDevice }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = EditableIOSScrollView()
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .clear
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bouncesZoom = true

        let paper = UIView(frame: CGRect(origin: .zero, size: pageSize))
        let tiled = IOSTiledSceneView(scene: scene, pageSize: pageSize, displayScale: displayScale, options: options)
        tiled.frame = paper.bounds
        tiled.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tiled.setPaint(tilePaint)
        tiled.ensureSourcePrepared()
        paper.addSubview(tiled)

        let overlay = IOSEditorOverlayView(frame: paper.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.coordinator = context.coordinator
        overlay.sceneUndoManager = sceneUndoManager
        paper.addSubview(overlay)

        scrollView.addSubview(paper)
        scrollView.contentSize = pageSize

        context.coordinator.scrollView = scrollView
        context.coordinator.paper = paper
        context.coordinator.tiledView = tiled
        context.coordinator.overlay = overlay
        controller.scrollView = scrollView

        scrollView.onLayoutSize = { [weak coordinator = context.coordinator] size in
            coordinator?.configureZoomScales(for: size)
        }
        context.coordinator.installGestures(on: overlay, scrollView: scrollView)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.tiledView?.setScene(scene)
        context.coordinator.tiledView?.ensureSourcePrepared()
        context.coordinator.tiledView?.setPaint(tilePaint)
        context.coordinator.tiledView?.setOptions(options)
        controller.scrollView = scrollView
        // The inspector opening/closing changes the clear region but not the scroll
        // view's bounds, so re-fit/centre here (the canvas still fills the full width).
        context.coordinator.configureZoomScales(for: scrollView.bounds.size)
        context.coordinator.overlay?.setNeedsDisplay()
    }

    static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
        scrollView.delegate = nil
        (scrollView as? EditableIOSScrollView)?.onLayoutSize = nil
        coordinator.tiledView?.layer.contents = nil
        coordinator.tiledView?.removeFromSuperview()
        coordinator.overlay?.coordinator = nil
        coordinator.tiledView = nil
        coordinator.overlay = nil
        coordinator.scrollView = nil
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: EditableMetafileCanvas
        fileprivate weak var scrollView: UIScrollView?
        fileprivate weak var paper: UIView?
        fileprivate weak var tiledView: IOSTiledSceneView?
        fileprivate weak var overlay: IOSEditorOverlayView?

        private var hasSetInitialZoom = false
        private var lastViewport: CGSize = .zero
        private var lastTrailingInset: CGFloat = -1
        fileprivate var drag: DragState?

        init(_ parent: EditableMetafileCanvas) { self.parent = parent }

        var scene: EMFEdit.Scene { parent.scene }
        var selection: EditorSelection {
            get { parent.editorModel.selection }
            set { parent.editorModel.selection = newValue }
        }
        var zoom: CGFloat { scrollView?.zoomScale ?? 1 }

        /// device ↔ paper-view mapping. The iOS overlay is y-down (no flip); the tiled
        /// view applies its own UIKit flip when it draws.
        var mapping: EditorCanvasMapping {
            EditorCanvasMapping(pageBoundsDevice: scene.pageBoundsDevice, target: CGRect(origin: .zero, size: parent.pageSize), flipY: false)
        }

        // MARK: Zoom

        func configureZoomScales(for viewport: CGSize) {
            guard viewport.width > 0, viewport.height > 0, let scrollView else { return }
            // Fit into the region the inspector overlay leaves clear, not the full width,
            // so the drawing sits beside (not under) the inspector while the canvas fills.
            let insets = ViewerFit.Insets(top: 0, leading: 0, bottom: 0, trailing: parent.trailingInset)
            let fit = ViewerFit.fitScale(content: parent.pageSize, viewport: viewport, insets: insets, minScale: 0.01, maxScale: 100)
            // Re-fit when the viewport changes (the inspector opening/closing changes the
            // clear region) AND the user hadn't manually zoomed, so the drawing re-centres
            // instead of being stranded in a corner.
            let wasFitted = !hasSetInitialZoom || abs(scrollView.zoomScale - parent.controller.fitScale) < 0.001
            scrollView.minimumZoomScale = min(fit, 1)
            scrollView.maximumZoomScale = max(8, fit)
            parent.controller.fitScale = fit
            if !hasSetInitialZoom {
                hasSetInitialZoom = true
                scrollView.zoomScale = ViewerZoomPolicy.initialScale(
                    for: .fit, fit: fit,
                    minScale: scrollView.minimumZoomScale, maxScale: scrollView.maximumZoomScale
                )
                centreContent(scrollView)
            } else if (viewport != lastViewport || parent.trailingInset != lastTrailingInset), wasFitted {
                scrollView.zoomScale = min(max(fit, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
                centreContent(scrollView)
            } else if parent.trailingInset != lastTrailingInset {
                centreContent(scrollView)   // inset changed but the user had zoomed: re-centre only
            }
            lastViewport = viewport
            lastTrailingInset = parent.trailingInset
            if parent.controller.zoom != scrollView.zoomScale { parent.controller.zoom = scrollView.zoomScale }
            overlay?.setNeedsDisplay()
        }

        private func centreContent(_ scrollView: UIScrollView) {
            let scaled = parent.pageSize.applying(CGAffineTransform(scaleX: scrollView.zoomScale, y: scrollView.zoomScale))
            // Centre within the region the inspector overlay leaves clear (full width
            // minus the trailing inset), so the drawing sits beside the inspector.
            let clearWidth = max(0, scrollView.bounds.width - parent.trailingInset)
            let x = max(0, (clearWidth - scaled.width) / 2)
            let y = max(0, (scrollView.bounds.height - scaled.height) / 2)
            scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x + parent.trailingInset)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { paper }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centreContent(scrollView)
            if parent.controller.zoom != scrollView.zoomScale { parent.controller.zoom = scrollView.zoomScale }
            overlay?.setNeedsDisplay()
        }
        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { parent.controller.isZooming = true }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            parent.controller.isZooming = false
            if parent.controller.zoom != scale { parent.controller.zoom = scale }
        }

        // MARK: Selection geometry

        func selectionViewBounds() -> CGRect? {
            guard let box = selection.boundsDevice(in: scene) else { return nil }
            return mapping.viewRect(fromDevice: box)
        }
        private func strokeTolerance() -> CGFloat { mapping.deviceLength(fromViewLength: 10) }

        func handle(at viewPoint: CGPoint) -> ResizeHandle? {
            guard let box = selectionViewBounds() else { return nil }
            let hit = Self.handleHitRadius / zoom   // 44-pt hit target
            for handle in ResizeHandle.allCases {
                if hypot(viewPoint.x - handle.point(in: box).x, viewPoint.y - handle.point(in: box).y) <= hit { return handle }
            }
            return nil
        }
        static let handleHitRadius: CGFloat = 22   // 44-pt diameter target
        static let handleDrawSize: CGFloat = 12

        func hitElement(at viewPoint: CGPoint) -> Int? {
            EditorHitTest.topmost(in: scene, atDevice: mapping.devicePoint(fromView: viewPoint), strokeToleranceDevice: strokeTolerance())
        }

        // MARK: Gestures

        func installGestures(on overlay: UIView, scrollView: UIScrollView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.delegate = self
            overlay.addGestureRecognizer(tap)

            // Double-tap a text element to edit it (design call E2c-5); the single tap
            // waits for this to fail so a double-tap doesn't also re-select.
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.delegate = self
            overlay.addGestureRecognizer(doubleTap)
            tap.require(toFail: doubleTap)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            overlay.addGestureRecognizer(pan)

            let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
            rotate.delegate = self
            overlay.addGestureRecognizer(rotate)
        }

        /// Whether a shape-creation tool is armed (E3a).
        var isShapeToolArmed: Bool { parent.editorModel.armedShapeTool != nil }

        /// The pan only begins when it starts on the selection or a handle; otherwise it
        /// yields to the scroll view so the drawing still pans. An armed shape tool, though,
        /// claims the whole canvas so a drag anywhere draws the shape (E3a).
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.maximumNumberOfTouches == 1, let overlay {
                if isShapeToolArmed { return true }
                let p = touch.location(in: overlay)
                if handle(at: p) != nil { return true }
                if let box = selectionViewBounds(), box.contains(p) { return true }
                return false
            }
            return true
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // The rotation runs alongside the scroll view's pinch; the move/resize pan
            // does not (it disables scrolling while active).
            g is UIRotationGestureRecognizer || other is UIRotationGestureRecognizer
        }

        @objc private func handleTap(_ g: UITapGestureRecognizer) {
            guard let overlay else { return }
            let p = g.location(in: overlay)
            // An armed shape tool: a tap (no drag) inserts the 100 × 100 pt default
            // shape centred at the tap, selects it and disarms (design call 5).
            if let kind = parent.editorModel.armedShapeTool {
                let centre = mapping.devicePoint(fromView: p)
                let side = ShapeToolGeometry.pointsToDevice(ShapeToolGeometry.defaultSidePoints, deviceUnitsPerPoint: scene.deviceUnitsPerPoint)
                let rect = ShapeToolGeometry.defaultRect(centreDevice: centre, sideDevice: side)
                commitShape(kind: kind, rectDevice: rect)
                overlay.becomeFirstResponder()
                overlay.setNeedsDisplay()
                return
            }
            let id = hitElement(at: p)
            selection = selection.afterClick(hit: id, additive: false)
            // Take first responder so a hardware Delete key reaches the overlay's key
            // commands (design call E2c-4).
            if !selection.ids.isEmpty { overlay.becomeFirstResponder() }
            overlay.setNeedsDisplay()
        }

        @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard let overlay else { return }
            let p = g.location(in: overlay)
            guard let id = hitElement(at: p),
                  let element = scene.elements.first(where: { $0.id == id }),
                  element.kind == .text else { return }
            presentTextEdit(for: id)
        }

        /// Opens the text-edit popover for a text element, anchored to the run. Shared by
        /// double-tap and the DEBUG hook.
        func presentTextEdit(for id: Int) {
            guard let element = scene.elements.first(where: { $0.id == id }),
                  element.kind == .text, let text = element.text else { return }
            selection = selection.afterClick(hit: id, additive: false)
            parent.editorModel.textEdit = TextEditRequest(id: id, anchor: anchor(for: element), initialText: text.string)
            overlay?.setNeedsDisplay()
        }

        /// The run's reference point as a fraction of the scroll view's visible viewport,
        /// so the popover's arrow points at the glyphs. A text element's bounds is the
        /// inherited page clip (EMFEdit text-bounds limitation), so the reference point
        /// gives a tight anchor.
        private func anchor(for element: Element) -> UnitPoint {
            guard let scrollView, let overlay else { return .center }
            let deviceAnchor = CGPoint(x: element.text?.referenceLogical.x ?? element.boundsDevice.midX,
                                       y: element.text?.referenceLogical.y ?? element.boundsDevice.midY)
            let paperPoint = mapping.viewPoint(fromDevice: deviceAnchor)
            let inScroll = overlay.convert(paperPoint, to: scrollView)
            let x = inScroll.x - scrollView.contentOffset.x
            let y = inScroll.y - scrollView.contentOffset.y
            let size = scrollView.bounds.size
            guard size.width > 0, size.height > 0 else { return .center }
            return UnitPoint(x: min(1, max(0, x / size.width)), y: min(1, max(0, y / size.height)))
        }

        /// Deletes the current selection as one undoable step (design call E2c-4).
        func deleteSelection() {
            guard !selection.ids.isEmpty else { return }
            parent.delete(selection.ids)
        }

        @objc private func handlePan(_ g: UIPanGestureRecognizer) {
            guard let overlay, let scrollView else { return }
            let p = g.location(in: overlay)
            // An armed shape tool sweeps a new shape instead of moving/resizing (E3a).
            if let kind = parent.editorModel.armedShapeTool {
                handleShapePan(g, kind: kind, point: p, overlay: overlay, scrollView: scrollView)
                return
            }
            switch g.state {
            case .began:
                scrollView.isScrollEnabled = false
                if let h = handle(at: p) {
                    var state = DragState(kind: .resize, start: p, current: p)
                    state.handle = h; state.startViewBounds = selectionViewBounds()
                    drag = state
                } else if let box = selectionViewBounds(), box.contains(p) {
                    drag = DragState(kind: .move, start: p, current: p)
                } else { scrollView.isScrollEnabled = true; return }
                prepareGhost()
            case .changed:
                guard var state = drag else { return }
                state.current = p; drag = state
                drag?.liveTransform = liveViewTransform(state: state)
                overlay.setNeedsDisplay()
            case .ended:
                commitDrag(end: p)
                scrollView.isScrollEnabled = true
            default:
                cancelDrag(); scrollView.isScrollEnabled = true
            }
        }

        @objc private func handleRotate(_ g: UIRotationGestureRecognizer) {
            guard let overlay, let scrollView else { return }
            switch g.state {
            case .began:
                guard let box = selectionViewBounds(), box.contains(g.location(in: overlay)) else { return }
                scrollView.pinchGestureRecognizer?.isEnabled = false
                var state = DragState(kind: .rotate, start: .zero, current: .zero)
                state.startViewBounds = box
                drag = state
                prepareGhost()
            case .changed:
                guard var state = drag, state.kind == .rotate, let box = state.startViewBounds else { return }
                let centre = CGPoint(x: box.midX, y: box.midY)
                state.rotation = g.rotation; drag = state
                drag?.liveTransform = CGAffineTransform(translationX: centre.x, y: centre.y)
                    .rotated(by: g.rotation).translatedBy(x: -centre.x, y: -centre.y)
                parent.editorModel.rotationReadout = String(format: "%.0f°", g.rotation * 180 / .pi)
                overlay.setNeedsDisplay()
            case .ended:
                commitRotation(radians: g.rotation)
                scrollView.pinchGestureRecognizer?.isEnabled = true
            default:
                cancelDrag(); scrollView.pinchGestureRecognizer?.isEnabled = true
            }
        }

        /// The shape-tool sweep: a one-finger drag draws a live preview; release commits
        /// one `.insert` (a sweep, or the default shape if the drag was tiny). No Shift/
        /// Option on touch (design call 5 lists those modifiers for the Mac).
        private func handleShapePan(_ g: UIPanGestureRecognizer, kind: ShapeToolKind, point p: CGPoint, overlay: IOSEditorOverlayView, scrollView: UIScrollView) {
            switch g.state {
            case .began:
                scrollView.isScrollEnabled = false
                drag = DragState(kind: .shape, start: p, current: p)
                drag?.shapeKind = kind
                overlay.setNeedsDisplay()
            case .changed:
                guard let state = drag else { return }
                drag?.current = p
                drag?.shapePreviewRect = ShapeToolGeometry.sweptRect(kind: kind, start: state.start, current: p, shift: false, fromCentre: false)
                overlay.setNeedsDisplay()
            case .ended:
                if let state = drag {
                    let rectDevice: CGRect
                    if ShapeToolGeometry.isDrag(start: state.start, current: p, magnification: zoom) {
                        rectDevice = sweptDeviceRect(fromView: ShapeToolGeometry.sweptRect(kind: kind, start: state.start, current: p, shift: false, fromCentre: false))
                    } else {
                        let centre = mapping.devicePoint(fromView: p)
                        let side = ShapeToolGeometry.pointsToDevice(ShapeToolGeometry.defaultSidePoints, deviceUnitsPerPoint: scene.deviceUnitsPerPoint)
                        rectDevice = ShapeToolGeometry.defaultRect(centreDevice: centre, sideDevice: side)
                    }
                    drag = nil
                    commitShape(kind: kind, rectDevice: rectDevice)
                }
                scrollView.isScrollEnabled = true
                overlay.setNeedsDisplay()
            default:
                drag = nil
                scrollView.isScrollEnabled = true
                overlay.setNeedsDisplay()
            }
        }

        /// Commits one `.insert` for a drawn shape, selects it, and disarms the tool.
        private func commitShape(kind: ShapeToolKind, rectDevice: CGRect) {
            let insertion = ShapeToolInsertion.command(kind: kind, rectDevice: rectDevice, in: scene)
            parent.apply(insertion.command, nil)
            selection = selection.afterClick(hit: insertion.id, additive: false)
            parent.editorModel.armedShapeTool = nil
        }

        /// Maps a view-space swept rect to device space, mapping the origin and far
        /// corner individually so a `.line`'s drag direction survives.
        private func sweptDeviceRect(fromView viewRect: CGRect) -> CGRect {
            let originDevice = mapping.devicePoint(fromView: viewRect.origin)
            let farDevice = mapping.devicePoint(fromView: CGPoint(
                x: viewRect.origin.x + viewRect.size.width, y: viewRect.origin.y + viewRect.size.height))
            return CGRect(origin: originDevice,
                          size: CGSize(width: farDevice.x - originDevice.x, height: farDevice.y - originDevice.y))
        }

        private func liveViewTransform(state: DragState) -> CGAffineTransform {
            switch state.kind {
            case .move:
                return CGAffineTransform(translationX: state.current.x - state.start.x, y: state.current.y - state.start.y)
            case .resize:
                guard let handle = state.handle, let box = state.startViewBounds else { return .identity }
                return EditorTransform.resizeTransform(
                    bounds: box, handle: handle,
                    translation: CGVector(dx: state.current.x - state.start.x, dy: state.current.y - state.start.y),
                    aspectLocked: false, fromCenter: false
                )
            case .rotate, .marquee, .shape:
                return state.liveTransform
            }
        }

        private func prepareGhost() {
            guard let box = selectionViewBounds(), let deviceBox = selection.boundsDevice(in: scene) else { return }
            drag?.ghostViewBounds = box
            drag?.ghost = GhostRasterizer.image(scene: scene, ids: selection.ids, deviceBounds: deviceBox, pixelScale: max(1, zoom) * parent.displayScale)
            tiledView?.setHiddenIDs(selection.ids)
        }

        /// Invalidate only the region a committed edit touches (E2b item 5).
        private func markDirtyRegion(old: CGRect?, viewTransform: CGAffineTransform) {
            guard let old else { tiledView?.pendingDirtyRegion = nil; return }
            tiledView?.pendingDirtyRegion = old.union(old.applying(viewTransform)).insetBy(dx: -48, dy: -48)
        }

        private func commitDrag(end: CGPoint) {
            defer { finishDrag() }
            guard let state = drag else { return }
            let viewTransform = liveViewTransform(state: state)
            guard !viewTransform.isIdentity, !selection.ids.isEmpty else { return }
            markDirtyRegion(old: state.startViewBounds ?? selectionViewBounds(), viewTransform: viewTransform)
            if state.kind == .move {
                let device = mapping.deviceTransform(fromView: viewTransform)
                parent.apply(.translate(ids: selection.ids, dx: Double(device.tx), dy: Double(device.ty)), nil)
            } else {
                parent.apply(.applyTransform(ids: selection.ids, mapping.deviceTransform(fromView: viewTransform)), nil)
            }
        }

        private func commitRotation(radians: CGFloat) {
            defer { finishDrag() }
            guard let state = drag, let box = state.startViewBounds, !selection.ids.isEmpty, radians != 0 else { return }
            let centre = CGPoint(x: box.midX, y: box.midY)
            let viewTransform = CGAffineTransform(translationX: centre.x, y: centre.y).rotated(by: radians).translatedBy(x: -centre.x, y: -centre.y)
            markDirtyRegion(old: box, viewTransform: viewTransform)
            parent.apply(.applyTransform(ids: selection.ids, mapping.deviceTransform(fromView: viewTransform)), nil)
        }

        private func finishDrag() {
            drag = nil
            tiledView?.setHiddenIDs([])
            parent.editorModel.rotationReadout = nil
            overlay?.setNeedsDisplay()
        }

        func cancelDrag() { finishDrag() }
    }

    fileprivate struct DragState {
        enum Kind { case marquee, move, resize, rotate, shape }
        var kind: Kind
        var start: CGPoint
        var current: CGPoint
        var handle: ResizeHandle?
        var startViewBounds: CGRect?
        var rotation: CGFloat = 0
        var liveTransform: CGAffineTransform = .identity
        var ghost: CGImage?
        var ghostViewBounds: CGRect?
        /// The armed shape kind while `kind == .shape`.
        var shapeKind: ShapeToolKind?
        /// The constrained preview rect (view space) the overlay draws while sweeping.
        var shapePreviewRect: CGRect?
    }
}

// MARK: - Scroll view

private final class EditableIOSScrollView: UIScrollView {
    var onLayoutSize: ((CGSize) -> Void)?
    private var last: CGSize = .zero
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != last { last = bounds.size; onLayoutSize?(bounds.size) }
    }
}

// MARK: - Tiled scene view

private final class IOSTiledSceneView: UIView {
    private let sceneLock: OSAllocatedUnfairLock<EMFEdit.Scene>
    private let hiddenLock = OSAllocatedUnfairLock<Set<Int>>(initialState: [])
    private let paintLock = OSAllocatedUnfairLock<TilePaint>(initialState: .plain)
    private let optionsLock: OSAllocatedUnfairLock<RenderOptions>
    /// The source lifecycle (E2b-3): prepared once, off the main actor, when the
    /// canvas appears. While `.preparing`, tiles paint only the page background
    /// rather than each preparing the whole file internally.
    private let sourceStateLock = OSAllocatedUnfairLock<TileRenderSource>(initialState: .notNeeded)
    private var sourcePrepStarted = false
    private let pageSize: CGSize

    override class var layerClass: AnyClass { CATiledLayer.self }
    private var tiledLayer: CATiledLayer { layer as! CATiledLayer }

    init(scene: EMFEdit.Scene, pageSize: CGSize, displayScale: CGFloat, options: RenderOptions) {
        self.sceneLock = OSAllocatedUnfairLock<EMFEdit.Scene>(initialState: scene)
        self.optionsLock = OSAllocatedUnfairLock<RenderOptions>(initialState: options)
        self.pageSize = pageSize
        super.init(frame: CGRect(origin: .zero, size: pageSize))
        let tiled = tiledLayer
        tiled.levelsOfDetail = 8
        tiled.levelsOfDetailBias = 4
        tiled.tileSize = CGSize(width: 512, height: 512)
        tiled.contentsScale = displayScale > 0 ? displayScale : 1
        backgroundColor = .clear
        isOpaque = false
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A view-space region to invalidate on the next `setScene` instead of the whole
    /// view, so a committed edit only repaints the changed tiles (E2b item 5).
    var pendingDirtyRegion: CGRect?

    /// Prepares the render source once, off the main actor, for a scene that needs
    /// it; a no-op for a pure-geometry scene. On arrival the view redraws so every
    /// tile reuses it (E2b-3).
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
            self.setNeedsDisplay()
            self.tiledLayer.setNeedsDisplay()
        }
    }

    func setScene(_ scene: EMFEdit.Scene) {
        sceneLock.withLock { $0 = scene }
        if let region = pendingDirtyRegion {
            pendingDirtyRegion = nil
            setNeedsDisplay(region)
            tiledLayer.setNeedsDisplay(region)
        } else {
            setNeedsDisplay()
            tiledLayer.setNeedsDisplay()
        }
    }
    func setHiddenIDs(_ ids: Set<Int>) {
        let changed = hiddenLock.withLock { c -> Bool in guard c != ids else { return false }; c = ids; return true }
        if changed { setNeedsDisplay(); tiledLayer.setNeedsDisplay() }
    }
    func setPaint(_ paint: TilePaint) {
        let changed = paintLock.withLock { c -> Bool in guard c != paint else { return false }; c = paint; return true }
        if changed { setNeedsDisplay(); tiledLayer.setNeedsDisplay() }
    }
    func setOptions(_ options: RenderOptions) {
        let changed = optionsLock.withLock { c -> Bool in guard c != options else { return false }; c = options; return true }
        if changed { setNeedsDisplay(); tiledLayer.setNeedsDisplay() }
    }

    nonisolated override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let paint = paintLock.withLock { $0 }
        let hidden = hiddenLock.withLock { $0 }
        let state = sourceStateLock.withLock { $0 }
        let natural = pageSize
        // While a needed source is still preparing, paint only the page background —
        // never prepare per tile (one full-file parse per visible tile on the tiled
        // layer's threads). The redraw on arrival paints the ink (E2b-3).
        if state.tileAction == .backgroundOnly {
            TilePainter.paint(paint, into: context, rect: rect) { _ in }
            return
        }
        var scene = sceneLock.withLock { $0 }
        if !hidden.isEmpty { scene = SceneGhostSupport.hiding(ids: hidden, in: scene) }
        // Only the elements reaching this tile are rendered (E2b item 5). The iOS tiled
        // view is y-down (flipY: false); the UIKit flip below is applied when drawing,
        // separately from this pointer-space filter.
        let tileScene = SceneTileFilter.subscene(scene, viewRect: rect, target: CGRect(origin: .zero, size: natural), flipY: false)
        TilePainter.paint(paint, into: context, rect: rect) { ctx in
            ctx.translateBy(x: 0, y: natural.height)
            ctx.scaleBy(x: 1, y: -1)
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

private final class IOSEditorOverlayView: UIView, UIContextMenuInteractionDelegate {
    weak var coordinator: EditableMetafileCanvas.Coordinator?

    /// The scene's undo manager, vended to the responder chain so ⌘Z/⇧⌘Z and the system
    /// three-finger undo/redo gestures drive `SceneHistory` while this is first responder
    /// (E2d). `undoManager` is overridden to return it.
    var sceneUndoManager: UndoManager?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        // Long-press the selection for a Delete action (design call E2c-4, iPad).
        addInteraction(UIContextMenuInteraction(delegate: self))
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var zoom: CGFloat { coordinator?.zoom ?? 1 }

    // MARK: Hardware keyboard + undo + context menu delete

    override var canBecomeFirstResponder: Bool { true }

    /// The scene's undo manager, so Undo/Redo gestures and ⌘Z/⇧⌘Z reach `SceneHistory`.
    override var undoManager: UndoManager? { sceneUndoManager ?? super.undoManager }

    /// Take first responder on entering edit mode, so keyboard/gesture undo works before
    /// any selection (e.g. to undo a delete that cleared the selection).
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    override var keyCommands: [UIKeyCommand]? {
        guard let coordinator, !coordinator.selection.ids.isEmpty else { return nil }
        let backspace = UIKeyCommand(input: "\u{8}", modifierFlags: [], action: #selector(deleteCommand))
        backspace.wantsPriorityOverSystemBehavior = true
        let forward = UIKeyCommand(input: "\u{7F}", modifierFlags: [], action: #selector(deleteCommand))
        forward.wantsPriorityOverSystemBehavior = true
        return [backspace, forward]
    }

    @objc private func deleteCommand() { coordinator?.deleteSelection() }

    /// Strokes (and lightly fills, for closed kinds) the shape-tool preview outline in
    /// the overlay's view space (y-down). A line keeps its drag direction; closed kinds
    /// use the standardised box, with the triangle apex at the top edge.
    static func strokeShapePreview(kind: ShapeToolKind, rect: CGRect, into context: CGContext, lineWidth: CGFloat, accent: UIColor, cornerRadius: CGFloat) {
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
            context.move(to: CGPoint(x: box.midX, y: box.minY))
            context.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
            context.addLine(to: CGPoint(x: box.minX, y: box.maxY))
            context.closePath()
            context.drawPath(using: .fillStroke)
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let coordinator, let box = coordinator.selectionViewBounds(), box.contains(location) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                coordinator.deleteSelection()
            }
            return UIMenu(children: [delete])
        }
    }

    override func draw(_ rect: CGRect) {
        guard let coordinator, let context = UIGraphicsGetCurrentContext() else { return }
        let mag = zoom
        let accent = UIColor.tintColor

        if let drag = coordinator.drag, drag.kind != .marquee, let ghost = drag.ghost, let bounds = drag.ghostViewBounds {
            context.saveGState()
            context.concatenate(drag.liveTransform)
            context.setAlpha(0.85)
            // CGContext.draw is y-up; the overlay is y-down, so flip within the ghost rect.
            context.translateBy(x: bounds.minX, y: bounds.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(ghost, in: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
            context.restoreGState()
        }

        // Live shape-tool preview (view space, design call 5).
        if let drag = coordinator.drag, drag.kind == .shape, let kind = drag.shapeKind, let rect = drag.shapePreviewRect {
            let cornerRadius = ShapeToolGeometry.pointsToDevice(16, deviceUnitsPerPoint: coordinator.scene.deviceUnitsPerPoint)
            Self.strokeShapePreview(kind: kind, rect: rect, into: context, lineWidth: 1.5 / mag, accent: accent, cornerRadius: cornerRadius)
        }

        let draggingTransform = coordinator.drag.flatMap { $0.kind == .marquee ? nil : $0.liveTransform }
        context.saveGState()
        if let draggingTransform { context.concatenate(draggingTransform) }
        context.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1 / mag)
        for element in coordinator.scene.elements where coordinator.selection.contains(element.id) {
            let box = coordinator.mapping.viewRect(fromDevice: element.selectionBoundsDevice)
            if !box.isNull { context.stroke(box.insetBy(dx: -0.5 / mag, dy: -0.5 / mag)) }
        }
        context.restoreGState()

        if let box = coordinator.selectionViewBounds() {
            context.saveGState()
            if let draggingTransform { context.concatenate(draggingTransform) }
            context.setStrokeColor(accent.cgColor)
            context.setLineWidth(1.5 / mag)
            context.stroke(box)
            context.restoreGState()

            let handleBox = draggingTransform.map { box.applying($0) } ?? box
            let size = EditableMetafileCanvas.Coordinator.handleDrawSize / mag
            for handle in ResizeHandle.allCases {
                let p = handle.point(in: handleBox)
                let r = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
                context.setFillColor(UIColor.white.cgColor)
                context.fillEllipse(in: r)
                context.setStrokeColor(accent.cgColor)
                context.setLineWidth(1.5 / mag)
                context.strokeEllipse(in: r)
            }
        }
    }
}
