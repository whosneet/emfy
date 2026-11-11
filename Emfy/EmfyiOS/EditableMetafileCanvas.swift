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

    var body: some View {
        let _ = session.editVersion
        Group {
            if let scene = session.editingScene {
                EditableMetafileCanvas(
                    scene: scene, editorModel: editorModel, controller: controller,
                    displayScale: displayScale, tilePaint: tilePaint, options: options,
                    apply: { command, key in session.apply(command, coalescing: key) }
                )
                .ignoresSafeArea()
            } else {
                Color(.systemGroupedBackground)
            }
        }
        .onChange(of: session.editVersion) { _, _ in
            if let scene = session.editingScene { editorModel.selection.prune(to: scene) }
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
            let fit = ViewerFit.fitScale(content: parent.pageSize, viewport: viewport, insets: .zero, minScale: 0.01, maxScale: 100)
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
            }
            if parent.controller.zoom != scrollView.zoomScale { parent.controller.zoom = scrollView.zoomScale }
            overlay?.setNeedsDisplay()
        }

        private func centreContent(_ scrollView: UIScrollView) {
            let scaled = parent.pageSize.applying(CGAffineTransform(scaleX: scrollView.zoomScale, y: scrollView.zoomScale))
            let x = max(0, (scrollView.bounds.width - scaled.width) / 2)
            let y = max(0, (scrollView.bounds.height - scaled.height) / 2)
            scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
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

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            overlay.addGestureRecognizer(pan)

            let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
            rotate.delegate = self
            overlay.addGestureRecognizer(rotate)
        }

        /// The pan only begins when it starts on the selection or a handle; otherwise it
        /// yields to the scroll view so the drawing still pans.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.maximumNumberOfTouches == 1, let overlay {
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
            let id = hitElement(at: p)
            selection = selection.afterClick(hit: id, additive: false)
            overlay.setNeedsDisplay()
        }

        @objc private func handlePan(_ g: UIPanGestureRecognizer) {
            guard let overlay, let scrollView else { return }
            let p = g.location(in: overlay)
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
            case .rotate, .marquee:
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
        enum Kind { case marquee, move, resize, rotate }
        var kind: Kind
        var start: CGPoint
        var current: CGPoint
        var handle: ResizeHandle?
        var startViewBounds: CGRect?
        var rotation: CGFloat = 0
        var liveTransform: CGAffineTransform = .identity
        var ghost: CGImage?
        var ghostViewBounds: CGRect?
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
    /// The source parsed/observed once per editing session (E2b-3), prepared off
    /// the main actor; nil until ready, so early tiles fall back to the per-render
    /// preparation.
    private let sourceLock = OSAllocatedUnfairLock<SceneRenderer.SceneRenderSource?>(initialState: nil)
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
        guard SceneRenderer.requiresPreparedSource(scene) else { return }
        sourcePrepStarted = true
        let lock = sourceLock
        Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) { SceneRenderer.prepare(scene) }.value
            lock.withLock { $0 = prepared }
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
        var scene = sceneLock.withLock { $0 }
        let source = sourceLock.withLock { $0 }
        let natural = pageSize
        if !hidden.isEmpty { scene = SceneGhostSupport.hiding(ids: hidden, in: scene) }
        // Only the elements reaching this tile are rendered (E2b item 5). The iOS tiled
        // view is y-down (flipY: false); the UIKit flip below is applied when drawing,
        // separately from this pointer-space filter.
        let tileScene = SceneTileFilter.subscene(scene, viewRect: rect, target: CGRect(origin: .zero, size: natural), flipY: false)
        TilePainter.paint(paint, into: context, rect: rect) { ctx in
            ctx.translateBy(x: 0, y: natural.height)
            ctx.scaleBy(x: 1, y: -1)
            // Reuse the prepared source so the tile doesn't re-parse the file (E2b-3);
            // fall back to the internal preparation until it's ready.
            if let source {
                SceneRenderer.render(tileScene, into: ctx, target: CGRect(origin: .zero, size: natural), source: source)
            } else {
                SceneRenderer.render(tileScene, into: ctx, target: CGRect(origin: .zero, size: natural))
            }
        }
    }
}

// MARK: - Overlay

private final class IOSEditorOverlayView: UIView {
    weak var coordinator: EditableMetafileCanvas.Coordinator?

    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear; isOpaque = false }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var zoom: CGFloat { coordinator?.zoom ?? 1 }

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
