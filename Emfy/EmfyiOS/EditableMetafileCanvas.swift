import CoreGraphics
import EMFEdit
import EMFRender
import Foundation
import os
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    /// The light editor (compact iPhone, E4): the selection shows an outline only, with
    /// no resize/rotate handles, and a drag on it only moves it.
    var lightMode: Bool = false
    /// The find highlights to draw in the overlay (F3b). `.empty` draws none.
    var findHighlights: FindHighlightSet = .empty

    var body: some View {
        @Bindable var editorModel = editorModel
        let _ = session.editVersion
        Group {
            if let scene = session.editingScene {
                EditableMetafileCanvas(
                    scene: scene, editorModel: editorModel, controller: controller,
                    displayScale: displayScale, tilePaint: tilePaint, options: options, lightMode: lightMode,
                    findHighlights: findHighlights,
                    apply: { command, key in session.apply(command, coalescing: key) },
                    delete: { ids in session.deleteSelection(ids) },
                    // Opens the coalesced "Insert Text" group; the popover's commit/cancel
                    // closes it (E3c design call 1).
                    beginInsertText: { element in session.beginInsertText(element) },
                    // A dropped image inserts centred at the drop point (E3c).
                    insertImageData: { data, centreDevice in
                        if let id = session.insertImage(data: data, centreDevice: centreDevice) {
                            editorModel.selection.replace(with: id)
                        }
                    },
                    align: { ids, alignment in session.alignSelection(ids, alignment) },
                    distribute: { ids, axis in session.distributeSelection(ids, axis) },
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
        // Undo/redo of a delete restores the selection (design call E2c-4), and a new insert
        // goes into the active layer resolved against the live scene (E3d).
        .onAppear {
            session.selectionRestore = { ids in editorModel.selection.replace(with: ids) }
            session.activeLayerIDProvider = {
                guard let scene = session.editingScene else { return nil }
                return editorModel.resolvedActiveLayerID(in: scene)
            }
        }
        // The double-tap text-edit popover, anchored to the run via a UnitPoint (E2c-5).
        .popover(item: $editorModel.textEdit, attachmentAnchor: .point(editorModel.textEdit?.anchor ?? .center), arrowEdge: .top) { request in
            TextEditPopover(
                request: request,
                // Routes through the insert-text group for a brand-new text (one "Insert
                // Text" undo); a plain `setText` for an existing element (E3c).
                onCommit: { string in session.commitInsertedText(id: request.id, string: string) },
                onCancel: { session.cancelInsertedText(id: request.id) },
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
    /// Light editor (compact iPhone, E4): selection outline only, drag moves only — no
    /// resize/rotate handles.
    var lightMode: Bool = false
    /// The find highlights to draw in the overlay (F3b). `.empty` draws none.
    var findHighlights: FindHighlightSet = .empty
    let apply: (SceneCommand, SceneCoalescingKey?) -> Void
    /// Deletes the given ids as one undoable step (design call E2c-4).
    let delete: (Set<Int>) -> Void
    /// Begins the coalesced insert-text undo group for a new text element (E3c).
    let beginInsertText: (EMFEdit.Element) -> Void
    /// Inserts a dropped image's bytes centred at a DEVICE-space point (E3c).
    let insertImageData: (Data, CGPoint) -> Void
    /// Aligns / distributes the selection as one undo entry (E3e).
    let align: (Set<Int>, EditorArrange.Alignment) -> Void
    let distribute: (Set<Int>, EditorArrange.Distribution) -> Void
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
        context.coordinator.overlay?.findHighlights = findHighlights   // live find highlights (F3b)
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
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate, UIDropInteractionDelegate {
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
            // Light mode shows no handles, so nothing resizes and a drag only moves (E4).
            guard !parent.lightMode, let box = selectionViewBounds() else { return nil }
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

            // Apple Pencil hover (supported iPads): a preview ring follows the Pencil while
            // it hovers over the canvas in edit mode (design call 5). Hover can't be tested
            // in the Simulator, so the glue is thin and the geometry is a pure helper.
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
            overlay.addGestureRecognizer(hover)

            // Drag-and-drop an image onto the canvas → insert at the drop point (E3c).
            overlay.addInteraction(UIDropInteraction(delegate: self))

            // Pencil double-tap and squeeze (design call 5): mapped to pure decisions.
            let pencil = UIPencilInteraction()
            pencil.delegate = self
            overlay.addInteraction(pencil)
        }

        /// Whether a shape-creation tool is armed (E3a).
        var isShapeToolArmed: Bool { parent.editorModel.armedShapeTool != nil }

        /// The touch type of the touch that started the current one-finger pan, so `handlePan`
        /// can tell an Apple Pencil (always draws) from a finger.
        private var panTouchType: UITouch.TouchType = .direct

        /// The pan begins when it starts on the selection or a handle (finger select/move),
        /// when an Apple Pencil touches (it always draws), or when a creation tool is armed —
        /// otherwise it yields to the scroll view so the drawing still pans (design call 1).
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.maximumNumberOfTouches == 1, let overlay {
                panTouchType = touch.type
                let mode = PenDrawMode.resolve(
                    isPencil: touch.type == .pencil,
                    armedPen: parent.editorModel.armedPen,
                    armedShape: isShapeToolArmed)
                if mode != .select { return true }   // the pencil, or an armed tool, draws
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
            // The armed text tool: a tap inserts a new text element at the tap, opens its
            // popover, selects it and disarms (E3c design call 1).
            if parent.editorModel.armedTextTool {
                insertText(at: p)
                overlay.becomeFirstResponder()
                overlay.setNeedsDisplay()
                return
            }
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

        /// Inserts a new text element at the tapped device point, selects it, opens the
        /// text popover on it (one coalesced "Insert Text" undo), and disarms the tool.
        /// The popover anchors to the just-built element directly — the coordinator's
        /// `scene` snapshot has not yet been refreshed with the insert this frame.
        private func insertText(at viewPoint: CGPoint) {
            let origin = mapping.devicePoint(fromView: viewPoint)
            let insertion = TextToolInsertion.element(originDevice: origin, in: scene)
            parent.beginInsertText(insertion.element)
            selection = selection.afterClick(hit: insertion.id, additive: false)
            parent.editorModel.armedTextTool = false
            parent.editorModel.textEdit = TextEditRequest(
                id: insertion.id, anchor: anchor(for: insertion.element),
                initialText: insertion.element.text?.string ?? TextToolInsertion.placeholder)
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

        // MARK: Context menu (E3d) — Arrange + Move Selection to Layer

        func arrange(_ direction: SceneArrange.Direction) {
            guard !selection.ids.isEmpty else { return }
            parent.apply(.arrange(ids: selection.ids, direction), nil)
        }

        /// Aligns / distributes the selection as one undo entry (E3e).
        func align(_ alignment: EditorArrange.Alignment) {
            guard !selection.ids.isEmpty else { return }
            parent.align(selection.ids, alignment)
        }
        func distribute(_ axis: EditorArrange.Distribution) {
            guard selection.ids.count >= 3 else { return }
            parent.distribute(selection.ids, axis)
        }

        func moveSelection(toLayer order: Int) {
            guard !selection.ids.isEmpty else { return }
            parent.apply(.moveElementsToLayer(ids: selection.ids, layer: order), nil)
        }

        /// The layer names (top-first) paired with their order index, for the move submenu.
        var layersTopFirst: [(order: Int, name: String)] {
            scene.layers.indices.reversed().map { (order: $0, name: scene.layers[$0].name) }
        }

        // MARK: Drag-and-drop image (E3c)

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier])
        }
        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            UIDropProposal(operation: .copy)
        }
        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            guard let overlay, let provider = session.items.first?.itemProvider else { return }
            let location = session.location(in: overlay)
            // Load the raw image bytes so the capped, metadata-stripping ingest sees the
            // original file; the completion runs off the main actor.
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
                guard let data else { return }
                Task { @MainActor in self?.handleImageDrop(data, at: location) }
            }
        }

        /// Inserts dropped image `data` centred at the drop point, mapped to device space
        /// through the SAME mapping the tap tools use.
        func handleImageDrop(_ data: Data, at viewPoint: CGPoint) {
            parent.insertImageData(data, mapping.devicePoint(fromView: viewPoint))
        }

        @objc private func handlePan(_ g: UIPanGestureRecognizer) {
            guard let overlay, let scrollView else { return }
            let p = g.location(in: overlay)
            let mode = PenDrawMode.resolve(
                isPencil: panTouchType == .pencil,
                armedPen: parent.editorModel.armedPen,
                armedShape: isShapeToolArmed)
            // An armed shape tool sweeps a new shape; the pen (Pencil, or a finger when armed)
            // draws a freehand stroke; otherwise a finger moves/resizes the selection.
            if mode == .shape, let kind = parent.editorModel.armedShapeTool {
                handleShapePan(g, kind: kind, point: p, overlay: overlay, scrollView: scrollView)
                return
            }
            if mode == .pen {
                handlePenPan(g, point: p, overlay: overlay, scrollView: scrollView)
                return
            }
            switch g.state {
            case .began:
                scrollView.isScrollEnabled = false
                if let h = handle(at: p) {
                    var state = DragState(kind: .resize, start: p, current: p)
                    state.handle = h; state.startViewBounds = selectionViewBounds()
                    state.snapCandidates = buildSnapCandidates()   // once per drag (design call 3)
                    drag = state
                } else if let box = selectionViewBounds(), box.contains(p) {
                    var state = DragState(kind: .move, start: p, current: p)
                    state.startViewBounds = box
                    state.snapCandidates = buildSnapCandidates()
                    drag = state
                } else { scrollView.isScrollEnabled = true; return }
                prepareGhost()
            case .changed:
                guard var state = drag else { return }
                // A resize snaps the dragged point; a move snaps its whole bounds (below).
                if state.kind == .resize {
                    let (snapped, gx, gy) = snapViewPoint(state: state, view: p)
                    state.current = snapped
                    state.snapGuideXsDevice = gx; state.snapGuideYsDevice = gy
                } else {
                    state.current = p
                }
                drag = state
                if state.kind == .move {
                    let raw = CGAffineTransform(translationX: state.current.x - state.start.x, y: state.current.y - state.start.y)
                    let (_, _, gx, gy) = moveSnap(state: state, rawView: raw)
                    drag?.snapGuideXsDevice = gx; drag?.snapGuideYsDevice = gy
                }
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
                // Light mode has no rotate (design call 2); the pinch still zooms.
                guard !parent.lightMode, let box = selectionViewBounds(), box.contains(g.location(in: overlay)) else { return }
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
                var state = DragState(kind: .shape, start: p, current: p)
                state.shapeKind = kind
                state.snapCandidates = buildSnapCandidates()   // once per draw (design call 3)
                drag = state
                overlay.setNeedsDisplay()
            case .changed:
                guard let state = drag else { return }
                let (snapped, gx, gy) = snapViewPoint(state: state, view: p)
                drag?.current = snapped
                drag?.snapGuideXsDevice = gx; drag?.snapGuideYsDevice = gy
                drag?.shapePreviewRect = ShapeToolGeometry.sweptRect(kind: kind, start: state.start, current: snapped, shift: false, fromCentre: false)
                overlay.setNeedsDisplay()
            case .ended:
                if let state = drag {
                    let p = snapViewPoint(state: state, view: p).0
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

        // MARK: Pen (E3b)

        private var penHoldSeq = 0
        private var lastPenPoint: CGPoint = .zero
        private static let penHoldDelay: TimeInterval = 0.5

        /// The Pencil hover point (overlay space), or nil when not hovering.
        fileprivate var hoverPoint: CGPoint?

        /// De-dup / RDP tolerances in device units for the current zoom (~1 and ~1.5 screen pt).
        private var penMinSpacingDevice: CGFloat { max(0.5, mapping.deviceLength(fromViewLength: 1 / max(zoom, 0.0001))) }
        private var penRdpToleranceDevice: CGFloat { max(0.75, mapping.deviceLength(fromViewLength: 1.5 / max(zoom, 0.0001))) }

        func penPreviewColor() -> CGColor {
            let c = parent.editorModel.penStyle.color
            return CGColor(red: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: 1)
        }
        var penPreviewWidthDevice: CGFloat {
            ShapeToolGeometry.pointsToDevice(parent.editorModel.penStyle.widthPoints, deviceUnitsPerPoint: scene.deviceUnitsPerPoint)
        }

        /// The freehand pen sweep: a drag draws a live preview; release commits one `.insert`
        /// (the smoothed curve, or the snapped shape after a hold). The pen stays armed and the
        /// stroke is NOT selected (design call 1/4).
        private func handlePenPan(_ g: UIPanGestureRecognizer, point p: CGPoint, overlay: IOSEditorOverlayView, scrollView: UIScrollView) {
            switch g.state {
            case .began:
                scrollView.isScrollEnabled = false
                var state = DragState(kind: .pen, start: p, current: p)
                state.penPoints = [p]
                drag = state
                lastPenPoint = p
                penHoldSeq += 1
                overlay.setNeedsDisplay()
            case .changed:
                appendPenPoint(p, overlay: overlay)
            case .ended:
                if let state = drag, state.kind == .pen { commitPenStroke(state: state) }
                drag = nil
                scrollView.isScrollEnabled = true
                overlay.setNeedsDisplay()
            default:
                drag = nil
                scrollView.isScrollEnabled = true
                overlay.setNeedsDisplay()
            }
        }

        private func appendPenPoint(_ p: CGPoint, overlay: IOSEditorOverlayView) {
            guard var state = drag, state.kind == .pen else { return }
            state.penPoints.append(p)
            if hypot(p.x - lastPenPoint.x, p.y - lastPenPoint.y) > 2 / max(zoom, 0.0001) {
                lastPenPoint = p
                state.penHoldElapsed = false
                state.penSnapPreview = nil
                penHoldSeq += 1
                let seq = penHoldSeq
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.penHoldDelay) { [weak self] in
                    self?.evaluatePenHold(seq: seq)
                }
            }
            drag = state
            overlay.setNeedsDisplay()
        }

        private func evaluatePenHold(seq: Int) {
            guard penHoldSeq == seq, var state = drag, state.kind == .pen else { return }
            state.penHoldElapsed = true
            let devicePoints = state.penPoints.map { mapping.devicePoint(fromView: $0) }
            state.penSnapPreview = ShapeRecognizer.recognize(points: devicePoints, rdpTolerance: penRdpToleranceDevice)
            drag = state
            overlay?.setNeedsDisplay()
        }

        private func commitPenStroke(state: DragState) {
            let devicePoints = state.penPoints.map { mapping.devicePoint(fromView: $0) }
            guard let insertion = PenCommit.command(
                rawDevicePoints: devicePoints, held: state.penHoldElapsed,
                minSpacing: penMinSpacingDevice, rdpTolerance: penRdpToleranceDevice,
                pen: parent.editorModel.penStyle, in: scene) else { return }
            parent.apply(insertion.command, nil)
        }

        // MARK: Pencil hover / squeeze / double-tap (design call 5)

        @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
            guard let overlay else { return }
            switch g.state {
            case .began, .changed: hoverPoint = g.location(in: overlay)
            default: hoverPoint = nil
            }
            overlay.setNeedsDisplay()
        }

        /// Maps UIKit's preferred tap action to the pure preference enum.
        fileprivate static func tapPreference(_ action: UIPencilPreferredAction) -> PenPencilTapPreference {
            switch action {
            case .ignore: return .ignore
            case .showColorPalette: return .showPalette
            case .switchEraser, .switchPrevious: return .switchTool
            default: return .systemDefault
            }
        }

        /// Toggles between the pen and selection, respecting the user's tap preference.
        fileprivate func performPencilDoubleTap() {
            switch PencilSupport.doubleTapAction(for: Self.tapPreference(UIPencilInteraction.preferredTapAction)) {
            case .togglePenSelect:
                if parent.editorModel.armedPen { parent.editorModel.armedPen = false } else { parent.editorModel.armPen() }
            case .showPalette:
                parent.editorModel.penPalettePresented = true
            case .none:
                break
            }
            overlay?.setNeedsDisplay()
        }

        /// A squeeze shows the pen palette (design call 5).
        fileprivate func performPencilSqueeze() {
            if PencilSupport.squeezeAction() == .showPalette { parent.editorModel.penPalettePresented = true }
        }

        // MARK: Snapping + grid (E3e)

        /// The finest displayed grid spacing in device units, for drawing and snapping.
        var gridSpacingDevice: CGFloat {
            let onScreenMajor = EditorGrid.deviceSpacing(deviceUnitsPerInch: scene.deviceUnitsPerInch ?? 96)
                * mapping.viewLength(fromDeviceLength: 1) * zoom
            return EditorGrid.displayedSpacing(deviceUnitsPerInch: scene.deviceUnitsPerInch ?? 96, onScreenMajorPoints: onScreenMajor)
        }

        /// The 6 view-pt snap threshold in device units at the current zoom.
        private var snapThresholdDevice: CGFloat { mapping.deviceLength(fromViewLength: 6 / max(zoom, 0.0001)) }

        /// Collects the snap candidates once at drag start (design call 3): other elements'
        /// and the page's edges/centres, plus the grid when shown. Empty when snapping is off.
        func buildSnapCandidates() -> EditorSnap.Candidates {
            let model = parent.editorModel
            let grid = (model.showGrid && model.snapToGrid) ? gridSpacingDevice : nil
            guard model.snapToGuides || grid != nil else { return .empty }
            var xs: [CGFloat] = []
            var ys: [CGFloat] = []
            if model.snapToGuides {
                for element in scene.elements where !selection.contains(element.id) {
                    let b = element.selectionBoundsDevice
                    guard !b.isNull else { continue }
                    xs.append(contentsOf: [b.minX, b.midX, b.maxX])
                    ys.append(contentsOf: [b.minY, b.midY, b.maxY])
                }
                let p = scene.pageBoundsDevice
                xs.append(contentsOf: [p.minX, p.midX, p.maxX])
                ys.append(contentsOf: [p.minY, p.midY, p.maxY])
            }
            return EditorSnap.Candidates(xs: xs, ys: ys, gridSpacing: grid)
        }

        /// The device adjustment + guide lines for a snapped MOVE, as a view translation.
        private func moveSnap(state: DragState, rawView: CGAffineTransform) -> (CGFloat, CGFloat, [CGFloat], [CGFloat]) {
            guard let candidates = state.snapCandidates, let base = state.startViewBounds else { return (0, 0, [], []) }
            let movedDevice = mapping.deviceRect(fromView: base.applying(rawView))
            let result = EditorSnap.snapMove(movedDevice, candidates: candidates, threshold: snapThresholdDevice)
            let dt = mapping.deviceToView
            return (result.dx * dt.a, result.dy * dt.d, result.guideXs, result.guideYs)
        }

        /// Snaps a dragged POINT (resize handle / draw corner) to the candidates.
        private func snapViewPoint(state: DragState, view: CGPoint) -> (CGPoint, [CGFloat], [CGFloat]) {
            guard let candidates = state.snapCandidates else { return (view, [], []) }
            let device = mapping.devicePoint(fromView: view)
            let result = EditorSnap.snap(xEdges: [device.x], yEdges: [device.y], candidates: candidates, threshold: snapThresholdDevice)
            let dt = mapping.deviceToView
            return (CGPoint(x: view.x + result.dx * dt.a, y: view.y + result.dy * dt.d), result.guideXs, result.guideYs)
        }

        private func liveViewTransform(state: DragState) -> CGAffineTransform {
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
                    aspectLocked: false, fromCenter: false
                )
            case .rotate, .marquee, .shape, .pen:
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
        enum Kind { case marquee, move, resize, rotate, shape, pen }
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
        /// The freehand sample points (overlay/view space) while `kind == .pen`.
        var penPoints: [CGPoint] = []
        /// Whether the pointer/Pencil paused ≥ 0.5 s before release (snap window).
        var penHoldElapsed = false
        /// The snapped shape preview shown live during a hold, or nil.
        var penSnapPreview: ShapeRecognizer.Match?
        /// Snapping (E3e): candidates pre-collected once at drag start; the device-space
        /// guide lines currently shown.
        var snapCandidates: EditorSnap.Candidates?
        var snapGuideXsDevice: [CGFloat] = []
        var snapGuideYsDevice: [CGFloat] = []
    }
}

// MARK: - Pencil interaction (design call 5)

extension EditableMetafileCanvas.Coordinator: UIPencilInteractionDelegate {
    /// Double-tap toggles pen/select, respecting the user's preferred action (iOS 17.5+).
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        performPencilDoubleTap()
    }

    /// Squeeze shows the pen palette (iOS 17.5+).
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        if squeeze.phase == .ended { performPencilSqueeze() }
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

    /// The find highlights to draw under the selection in edit mode (F3b).
    var findHighlights: FindHighlightSet = .empty

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

    /// The view-space rect for a snapped-shape preview, keeping a line's direction.
    static func penSnapViewRect(_ match: ShapeRecognizer.Match, mapping: EditorCanvasMapping) -> CGRect {
        guard match.kind == .line else { return mapping.viewRect(fromDevice: match.rect) }
        let origin = mapping.viewPoint(fromDevice: match.rect.origin)
        let far = mapping.viewPoint(fromDevice: CGPoint(x: match.rect.origin.x + match.rect.width, y: match.rect.origin.y + match.rect.height))
        return CGRect(origin: origin, size: CGSize(width: far.x - origin.x, height: far.y - origin.y))
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let coordinator, let box = coordinator.selectionViewBounds(), box.contains(location) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            // Arrange (reorder within the layer, E3d).
            let arrange = UIMenu(title: "Arrange", image: UIImage(systemName: "square.3.layers.3d"), children: [
                UIAction(title: "Bring to Front", image: UIImage(systemName: "square.3.layers.3d.top.filled")) { _ in coordinator.arrange(.toFront) },
                UIAction(title: "Bring Forward", image: UIImage(systemName: "square.2.layers.3d.top.filled")) { _ in coordinator.arrange(.forward) },
                UIAction(title: "Send Backward", image: UIImage(systemName: "square.2.layers.3d.bottom.filled")) { _ in coordinator.arrange(.backward) },
                UIAction(title: "Send to Back", image: UIImage(systemName: "square.3.layers.3d.bottom.filled")) { _ in coordinator.arrange(.toBack) },
            ])
            // Align / Distribute (E3e).
            let alignMenu = UIMenu(title: "Align", image: UIImage(systemName: "align.horizontal.left"), children: [
                UIAction(title: "Align Left", image: UIImage(systemName: "align.horizontal.left")) { _ in coordinator.align(.left) },
                UIAction(title: "Align Centre", image: UIImage(systemName: "align.horizontal.center")) { _ in coordinator.align(.centreHorizontal) },
                UIAction(title: "Align Right", image: UIImage(systemName: "align.horizontal.right")) { _ in coordinator.align(.right) },
                UIAction(title: "Align Top", image: UIImage(systemName: "align.vertical.top")) { _ in coordinator.align(.top) },
                UIAction(title: "Align Middle", image: UIImage(systemName: "align.vertical.center")) { _ in coordinator.align(.centreVertical) },
                UIAction(title: "Align Bottom", image: UIImage(systemName: "align.vertical.bottom")) { _ in coordinator.align(.bottom) },
            ])
            var children: [UIMenuElement] = [arrange, alignMenu]
            if coordinator.selection.ids.count >= 3 {
                let distributeMenu = UIMenu(title: "Distribute", image: UIImage(systemName: "distribute.horizontal"), children: [
                    UIAction(title: "Distribute Horizontally", image: UIImage(systemName: "distribute.horizontal")) { _ in coordinator.distribute(.horizontal) },
                    UIAction(title: "Distribute Vertically", image: UIImage(systemName: "distribute.vertical")) { _ in coordinator.distribute(.vertical) },
                ])
                children.append(distributeMenu)
            }
            // Move Selection to Layer, when there's more than one layer (E3d).
            let layers = coordinator.layersTopFirst
            if layers.count > 1 {
                let moveItems = layers.map { entry in
                    UIAction(title: entry.name) { _ in coordinator.moveSelection(toLayer: entry.order) }
                }
                children.append(UIMenu(title: "Move Selection to Layer", image: UIImage(systemName: "rectangle.stack"), children: moveItems))
            }
            let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                coordinator.deleteSelection()
            }
            children.append(delete)
            return UIMenu(children: children)
        }
    }

    override func draw(_ rect: CGRect) {
        guard let coordinator, let context = UIGraphicsGetCurrentContext() else { return }
        let mag = zoom
        let accent = UIColor.tintColor

        // Editing grid (E3e design call 2): editor-only, never exported.
        if coordinator.parent.editorModel.showGrid { drawGrid(coordinator: coordinator, into: context, mag: mag) }

        // Find highlights (F3b): under the selection chrome, mapped through the editor's own
        // device→view mapping so they land on the glyphs.
        if !findHighlights.isEmpty {
            let mapping = coordinator.mapping
            let all = findHighlights.matchDeviceRects.map { mapping.viewRect(fromDevice: $0) }
            let current = findHighlights.currentDeviceRect.map { mapping.viewRect(fromDevice: $0) }
            IOSFindHighlightPainter.paint(all: all, current: current, into: context, onScreenScale: mag)
        }

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

        // Live pen preview (design call 1/4): the snapped shape during a hold, else the raw
        // freehand trace, both in the pen's own colour.
        if let drag = coordinator.drag, drag.kind == .pen {
            let penColor = coordinator.penPreviewColor()
            if let match = drag.penSnapPreview {
                let viewRect = Self.penSnapViewRect(match, mapping: coordinator.mapping)
                Self.strokeShapePreview(kind: match.kind, rect: viewRect, into: context,
                                        lineWidth: coordinator.penPreviewWidthDevice, accent: UIColor(cgColor: penColor), cornerRadius: 0)
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

        // Pencil hover ring (design call 5): a ring at the hover point in the pen's colour
        // and width, shown while hovering and not actively drawing.
        if let hover = coordinator.hoverPoint, coordinator.drag == nil {
            let d = PencilSupport.hoverRingDiameter(widthDevice: coordinator.penPreviewWidthDevice)
            let r = CGRect(x: hover.x - d / 2, y: hover.y - d / 2, width: d, height: d)
            context.setStrokeColor(coordinator.penPreviewColor())
            context.setLineWidth(1.5 / mag)
            context.strokeEllipse(in: r)
        }

        // Live smart-guide lines while a drag is snapped (E3e design call 3).
        if let drag = coordinator.drag, !drag.snapGuideXsDevice.isEmpty || !drag.snapGuideYsDevice.isEmpty {
            drawSnapGuides(drag, coordinator: coordinator, into: context, mag: mag)
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

            // Light mode (E4 design call 2): a selection outline only, no handles.
            if coordinator.parent.lightMode { return }

            let handleBox = draggingTransform.map { box.applying($0) } ?? box
            let size = EditableMetafileCanvas.Coordinator.handleDrawSize / mag
            for handle in ResizeHandle.allCases {
                let p = handle.point(in: handleBox)
                let r = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
                // Fix A (E3e): a subtle dark drop shadow + ring under the white fill, so the
                // handle reads on any colour (white dots vanished over blue fills).
                context.saveGState()
                context.setShadow(offset: .zero, blur: 2.5 / mag, color: UIColor.black.withAlphaComponent(0.5).cgColor)
                context.setFillColor(UIColor.white.cgColor)
                context.fillEllipse(in: r)
                context.restoreGState()
                context.setStrokeColor(UIColor.black.withAlphaComponent(0.28).cgColor)
                context.setLineWidth(2.5 / mag)
                context.strokeEllipse(in: r.insetBy(dx: -0.6 / mag, dy: -0.6 / mag))
                context.setFillColor(UIColor.white.cgColor)
                context.fillEllipse(in: r)
                context.setStrokeColor(accent.cgColor)
                context.setLineWidth(1.5 / mag)
                context.strokeEllipse(in: r)
            }
        }
    }

    /// Draws the 10 mm editing grid over the page (E3e design call 2), subdividing when the
    /// major cell is large on screen so it stays crisp at any zoom.
    func drawGrid(coordinator: EditableMetafileCanvas.Coordinator, into context: CGContext, mag: CGFloat) {
        let scene = coordinator.scene
        let page = scene.pageBoundsDevice.standardized
        let perInch = scene.deviceUnitsPerInch ?? 96
        let major = EditorGrid.deviceSpacing(deviceUnitsPerInch: perInch)
        guard major > 0, page.width > 0, page.height > 0 else { return }
        let mapping = coordinator.mapping
        let onScreenMajor = major * abs(mapping.deviceToView.a) * mag
        let subdivisions = EditorGrid.subdivisions(onScreenMajorPoints: onScreenMajor)
        let fine = major / CGFloat(subdivisions)
        guard fine > 0, page.width / fine < 5000 else { return }
        // Fixed neutral ink, independent of appearance — the paper is always white (E3e review).
        let minor = UIColor(white: 0, alpha: 0.06)
        let majorColor = UIColor(white: 0, alpha: 0.12)
        let topV = mapping.viewPoint(fromDevice: CGPoint(x: page.minX, y: page.minY)).y
        let botV = mapping.viewPoint(fromDevice: CGPoint(x: page.minX, y: page.maxY)).y
        let leftV = mapping.viewPoint(fromDevice: CGPoint(x: page.minX, y: page.minY)).x
        let rightV = mapping.viewPoint(fromDevice: CGPoint(x: page.maxX, y: page.minY)).x
        var index = 0
        var dx = page.minX
        while dx <= page.maxX + 0.001 {
            let vx = mapping.viewPoint(fromDevice: CGPoint(x: dx, y: page.minY)).x
            let isMajor = index % subdivisions == 0
            context.setStrokeColor((isMajor ? majorColor : minor).cgColor)
            context.setLineWidth((isMajor ? 1 : 0.5) / mag)
            context.beginPath(); context.move(to: CGPoint(x: vx, y: topV)); context.addLine(to: CGPoint(x: vx, y: botV)); context.strokePath()
            index += 1; dx = page.minX + CGFloat(index) * fine
        }
        index = 0
        var dy = page.minY
        while dy <= page.maxY + 0.001 {
            let vy = mapping.viewPoint(fromDevice: CGPoint(x: page.minX, y: dy)).y
            let isMajor = index % subdivisions == 0
            context.setStrokeColor((isMajor ? majorColor : minor).cgColor)
            context.setLineWidth((isMajor ? 1 : 0.5) / mag)
            context.beginPath(); context.move(to: CGPoint(x: leftV, y: vy)); context.addLine(to: CGPoint(x: rightV, y: vy)); context.strokePath()
            index += 1; dy = page.minY + CGFloat(index) * fine
        }
    }

    /// Draws the smart-guide lines (device coords mapped to view) while a drag is snapped.
    func drawSnapGuides(_ drag: EditableMetafileCanvas.DragState, coordinator: EditableMetafileCanvas.Coordinator, into context: CGContext, mag: CGFloat) {
        let mapping = coordinator.mapping
        let page = coordinator.scene.pageBoundsDevice.standardized
        context.setStrokeColor(UIColor.systemYellow.cgColor)
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
}
