import CoreGraphics
import EMFRender
import SwiftUI
import UIKit

/// Drives the viewer's live zoom state across the UIKit bridge and exposes the
/// imperative commands the toolbar and keyboard shortcuts invoke. One per open
/// document; the SwiftUI screen observes it for the transient zoom pill and the
/// inspector's Zoom row (axiom-uikit uikit-bridging.md Part 4: an `@Observable`
/// shared model is the clean UIKit↔SwiftUI bridge).
@MainActor
@Observable
final class MetafileZoomController {
    /// Current zoom, where 1.0 == 100% (one natural device pixel per point).
    var zoom: CGFloat = 1
    /// True while a pinch is in flight — the only thing that shows the pill.
    var isZooming = false
    /// The scale that fits the picture in the current viewport.
    var fitScale: CGFloat = 1
    /// Mirrors the environment's Reduce Motion so button zooms honour it.
    var reduceMotion = false

    /// The scroll view is UIKit-owned; the controller only sends it commands.
    @ObservationIgnored weak var scrollView: UIScrollView?
    @ObservationIgnored private var announceTask: Task<Void, Never>?

    private let zoomStep: CGFloat = 1.5

    func fit() { setZoom(fitScale) }
    func actualSize() { setZoom(1) }
    /// `announce: false` is used by the adjustable element's increment/decrement,
    /// where VoiceOver already speaks the new value — so Emfy doesn't speak it twice
    /// (A12).
    func zoomIn(announce: Bool = true) { setZoom((scrollView?.zoomScale ?? zoom) * zoomStep, announce: announce) }
    func zoomOut(announce: Bool = true) { setZoom((scrollView?.zoomScale ?? zoom) / zoomStep, announce: announce) }

    /// Steps the zoom by an additive fraction of 100% — the Info row's − / + buttons
    /// step ±0.25 (25%), WCAG 2.5.1 single-pointer zoom (A14).
    func step(by delta: CGFloat) { setZoom((scrollView?.zoomScale ?? zoom) + delta) }

    private func setZoom(_ target: CGFloat, announce: Bool = true) {
        guard let scrollView else { return }
        let clamped = min(max(target, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
        scrollView.setZoomScale(clamped, animated: !reduceMotion)
        // setZoomScale(animated: false) may not fire the scroll delegate's
        // end-zooming callback, so announce here for every programmatic change.
        if announce { announceZoom(clamped) }
    }

    /// Announces the zoom to VoiceOver, debounced so a burst posts once, and only
    /// when VoiceOver is running. The one place both programmatic zooms and the
    /// coordinator's pinch route through, so they never double-announce.
    func announceZoom(_ scale: CGFloat) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let percent = Int((scale * 100).rounded())
        announceTask?.cancel()
        announceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            UIAccessibility.post(notification: .announcement, argument: "Zoom \(percent) percent")
        }
    }
}

/// A `UIScrollView` that reports its laid-out size, so the zoom range and the
/// initial fit can be set once real bounds exist (and reset when they change), and
/// reports when its safe-area insets change so the fit can follow the bars
/// appearing or hiding (v3-plan §9.1: fit inside the bars while shown).
private final class ZoomScrollView: UIScrollView {
    var onLayoutSize: ((CGSize) -> Void)?
    var onSafeAreaChange: (() -> Void)?
    private var lastReportedSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastReportedSize {
            lastReportedSize = bounds.size
            onLayoutSize?(bounds.size)
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onSafeAreaChange?()
    }
}

/// A `UIScrollView` wrapping a `CATiledLayer`-backed view that re-rasterises the
/// vector metafile per tile at the on-screen resolution. Because it is vector,
/// the drawing stays crisp at any zoom (the acceptance test is no blur at 400%),
/// and because `CATiledLayer` only draws the visible tiles on its own background
/// queue, memory stays bounded to the screen — never a full-canvas bitmap at
/// 400% of a large file (v3-plan §4 I2). Pinch, pan, and double-tap come from
/// the scroll view; a single tap toggles the chrome.
struct ZoomableMetafileView: UIViewRepresentable {
    let prepared: MetafileRenderer.Prepared
    let naturalSize: CGSize
    let displayScale: CGFloat
    let drawingLabel: String
    let controller: MetafileZoomController
    let reduceMotion: Bool
    /// Whether the chrome is currently hidden — drives the VoiceOver toggle
    /// action's name ("Show controls" vs "Hide controls").
    let chromeHidden: Bool
    /// The default zoom a fresh open lands on (S1a-4). Applied once, so it never
    /// overrides a zoom kept across an identical-content reload (C4a M4).
    var defaultZoom: EmfySettings.DefaultZoom = .fit
    /// Whether the page carries its drop shadow (S1a-4). Toggles live.
    var pageShadow: Bool = true
    /// Toggles the chrome; reused as the drawing's "Show/Hide controls" action.
    let onSingleTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = ZoomScrollView()
        scrollView.delegate = context.coordinator
        // Configure the zoom range and the initial fit from `layoutSubviews`,
        // where the real bounds are known — `updateUIView` runs before layout and
        // isn't called again, so it would leave the scroll view stuck at the
        // default min=max=1. This also re-fits on every bounds change (rotation,
        // a Duo open/close, an iPad Split View resize).
        scrollView.onLayoutSize = { [weak coordinator = context.coordinator] size in
            coordinator?.configureZoomScales(for: size)
        }
        // Re-fit when the bars show or hide: their appearance changes the scroll
        // view's safe-area insets, and the fit must stay inside the visible region
        // (§5). `configureZoomScales` reads `chromeHidden` to decide the insets.
        scrollView.onSafeAreaChange = { [weak scrollView, weak coordinator = context.coordinator] in
            guard let scrollView else { return }
            coordinator?.configureZoomScales(for: scrollView.bounds.size)
        }
        scrollView.backgroundColor = .clear
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast

        let tiled = TiledMetafileView(
            prepared: prepared,
            naturalSize: naturalSize,
            displayScale: displayScale
        )
        tiled.frame = CGRect(origin: .zero, size: naturalSize)
        // The drawing is one accessibility element labelled e.g. "Drawing: House
        // sketch". It's adjustable (VoiceOver swipe up/down zooms) and carries
        // custom actions for Zoom In/Out, Fit, Actual Size and the chrome toggle.
        tiled.isAccessibilityElement = true
        tiled.accessibilityLabel = drawingLabel
        tiled.controller = controller
        tiled.onToggleChrome = onSingleTap
        tiled.applyAccessibility(chromeHidden: chromeHidden)
        tiled.setShadow(enabled: pageShadow)
        context.coordinator.tiledView = tiled
        scrollView.addSubview(tiled)
        scrollView.contentSize = naturalSize
        controller.scrollView = scrollView

        // Double tap toggles fit ↔ 2×; a single tap (that waits for the double
        // to fail) toggles the chrome.
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        controller.reduceMotion = reduceMotion
        if let tiled = context.coordinator.tiledView {
            tiled.controller = controller
            tiled.onToggleChrome = onSingleTap
            tiled.applyAccessibility(chromeHidden: chromeHidden)
            tiled.setShadow(enabled: pageShadow)
            // Follow the display across a scale change (e.g. moving between
            // displays) — re-render the tiles at the new resolution.
            tiled.updateContentsScale(displayScale)
        }
        // Re-fit when the chrome toggles (§5): hiding the bars uses `.zero` insets
        // (full screen), showing them fits inside. `safeAreaInsetsDidChange` covers
        // most toggles; this makes the refit reliable even when the insets don't
        // move. Other zoom-scale configuration happens from `layoutSubviews`.
        context.coordinator.refitIfChromeChanged(scrollView, chromeHidden: chromeHidden)
    }

    /// Stop the CATiledLayer drawing into a view about to be freed, and break the
    /// delegate/callback references.
    static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
        scrollView.delegate = nil
        (scrollView as? ZoomScrollView)?.onLayoutSize = nil
        (scrollView as? ZoomScrollView)?.onSafeAreaChange = nil
        if let tiled = coordinator.tiledView {
            tiled.controller = nil
            tiled.onToggleChrome = nil
            tiled.layer.contents = nil
            tiled.removeFromSuperview()
        }
        coordinator.tiledView = nil
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableMetafileView
        fileprivate weak var tiledView: TiledMetafileView?

        private var hasSetInitialZoom = false
        private var lastViewportSize: CGSize = .zero
        private var lastInsets: ViewerFit.Insets = .zero
        private var lastChromeHidden: Bool?
        private var appliedFitScale: CGFloat = 1

        init(_ parent: ZoomableMetafileView) { self.parent = parent }

        // MARK: Zoom configuration

        /// The safe-area insets to fit inside: the scroll view's own insets (which
        /// track the bars) while the chrome is shown, and `.zero` when it is hidden
        /// so the drawing fills the screen (§5).
        private func effectiveInsets(_ scrollView: UIScrollView) -> ViewerFit.Insets {
            guard !parent.chromeHidden else { return .zero }
            let i = scrollView.safeAreaInsets
            return ViewerFit.Insets(top: i.top, leading: i.left, bottom: i.bottom, trailing: i.right)
        }

        func configureZoomScales(for viewport: CGSize) {
            guard viewport.width > 0, viewport.height > 0,
                  let tiled = tiledView,
                  let scrollView = tiled.superview as? UIScrollView
            else { return }

            let natural = parent.naturalSize
            let insets = effectiveInsets(scrollView)
            // Fit inside the visible (bar-reduced) region, allowing a small drawing
            // to magnify to fill it (the I2 fit behaviour), so `maxScale` sits well
            // above any real fit.
            let fit = ViewerFit.fitScale(content: natural, viewport: viewport, insets: insets, minScale: 0.01, maxScale: 100)
            // Read whether the picture was fitted BEFORE touching min/max —
            // assigning minimumZoomScale clamps the current zoomScale, which would
            // corrupt the comparison.
            let wasFitted = !hasSetInitialZoom || abs(scrollView.zoomScale - appliedFitScale) < 0.01
            let geometryChanged = viewport != lastViewportSize || insets != lastInsets

            // Zoom range: fit (or 100%, whichever is smaller) up to 800%, always
            // wide enough to include the fit scale itself.
            scrollView.minimumZoomScale = min(fit, 1)
            scrollView.maximumZoomScale = max(8, fit)
            parent.controller.fitScale = fit

            if !hasSetInitialZoom {
                hasSetInitialZoom = true
                scrollView.zoomScale = ViewerZoomPolicy.initialScale(
                    for: parent.defaultZoom, fit: fit,
                    minScale: scrollView.minimumZoomScale, maxScale: scrollView.maximumZoomScale
                )
            } else if geometryChanged {
                // Keep the picture fitted across a resize or a bar toggle if it was
                // fitted before; otherwise just clamp the current zoom into range.
                if wasFitted {
                    scrollView.zoomScale = fit
                } else {
                    scrollView.zoomScale = min(max(scrollView.zoomScale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
                }
            }

            appliedFitScale = fit
            lastViewportSize = viewport
            lastInsets = insets
            lastChromeHidden = parent.chromeHidden
            centreContent(scrollView)
            updateZoomState(scrollView.zoomScale)
        }

        /// Re-fits when the chrome visibility changed, so hiding the bars grows the
        /// drawing into the former bar area and showing them shrinks it back (§5).
        func refitIfChromeChanged(_ scrollView: UIScrollView, chromeHidden: Bool) {
            guard hasSetInitialZoom, lastChromeHidden != chromeHidden else { return }
            configureZoomScales(for: scrollView.bounds.size)
        }

        /// Centres the drawing inside the visible region, keeping it clear of the
        /// bars while they show (ViewerFit computes the safe-area + slack inset).
        private func centreContent(_ scrollView: UIScrollView) {
            let natural = parent.naturalSize
            let insets = effectiveInsets(scrollView)
            let centred = ViewerFit.centringInset(
                content: natural,
                viewport: scrollView.bounds.size,
                scale: scrollView.zoomScale,
                insets: insets
            )
            scrollView.contentInset = UIEdgeInsets(top: centred.top, left: centred.leading, bottom: centred.bottom, right: centred.trailing)
        }

        /// Mirrors the live zoom into the controller (pill / inspector) and the
        /// drawing's accessibility value. Observation doesn't dedupe equal writes, so
        /// only write when the value actually moves, to avoid invalidating the
        /// zoom-percent leaves on a frame where the scale didn't change (P9).
        private func updateZoomState(_ scale: CGFloat) {
            if parent.controller.zoom != scale {
                parent.controller.zoom = scale
            }
            tiledView?.accessibilityValue = "\(Int((scale * 100).rounded())) percent"
        }

        // MARK: UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { tiledView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centreContent(scrollView)
            updateZoomState(scrollView.zoomScale)
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            parent.controller.isZooming = true
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            parent.controller.isZooming = false
            updateZoomState(scale)
            parent.controller.announceZoom(scale)
        }

        // MARK: Taps

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            // Under VoiceOver, don't let a tap hide the chrome — Fit and Info must
            // stay reachable; VoiceOver toggles via the drawing's custom action.
            guard !UIAccessibility.isVoiceOverRunning else { return }
            parent.onSingleTap()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let tiled = tiledView,
                  let scrollView = tiled.superview as? UIScrollView
            else { return }
            let fit = parent.controller.fitScale
            let atFit = abs(scrollView.zoomScale - fit) < 0.01
            if atFit {
                // Fit → 2×, centred on the tap.
                let target = min(max(2, fit), scrollView.maximumZoomScale)
                let point = gesture.location(in: tiled)
                scrollView.zoom(to: zoomRect(scrollView, scale: target, center: point), animated: !parent.reduceMotion)
                parent.controller.announceZoom(target)
            } else {
                // Back to fit, centred.
                scrollView.setZoomScale(fit, animated: !parent.reduceMotion)
                parent.controller.announceZoom(fit)
            }
        }

        private func zoomRect(_ scrollView: UIScrollView, scale: CGFloat, center: CGPoint) -> CGRect {
            let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
            return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        }
    }
}

/// A `CATiledLayer`-backed view that draws the vector metafile for each tile at
/// the tile's current resolution. The page is whited per tile so the paper
/// stays white in dark mode; the renderer draws the ink over it. Tiles are
/// rasterised on `CATiledLayer`'s own background queue, off the main thread.
private final class TiledMetafileView: UIView {
    private let prepared: MetafileRenderer.Prepared
    private let naturalSize: CGSize

    /// Zoom commands for the adjustable trait and the Zoom custom actions.
    weak var controller: MetafileZoomController?
    /// Toggles the viewer chrome, for the "Show/Hide controls" custom action.
    var onToggleChrome: (() -> Void)?
    private var chromeHidden = false
    /// The chrome state the accessibility actions were last built for, so
    /// `applyAccessibility` only rebuilds when it actually changed (P2).
    private var appliedChromeHidden: Bool?

    override class var layerClass: AnyClass { CATiledLayer.self }

    private var tiledLayer: CATiledLayer {
        // Safe by construction: `layerClass` guarantees the backing layer type.
        layer as! CATiledLayer
    }

    init(prepared: MetafileRenderer.Prepared, naturalSize: CGSize, displayScale: CGFloat) {
        self.prepared = prepared
        self.naturalSize = naturalSize
        super.init(frame: CGRect(origin: .zero, size: naturalSize))

        let tiled = tiledLayer
        // Four magnified levels keep 800% (2³) crisp with headroom; eight reduced
        // levels cover the fit scale of a large picture in a small viewport.
        tiled.levelsOfDetail = 8
        tiled.levelsOfDetailBias = 4
        tiled.tileSize = CGSize(width: 512, height: 512)
        // Render base tiles at the real display scale, not a constant — this is
        // where the I1 fixed-2× raster is replaced (v3-plan §4 I2).
        tiled.contentsScale = displayScale > 0 ? displayScale : 1

        backgroundColor = .clear
        isOpaque = false

        // A subtle paper shadow, as in the approved mockup. The path is updated
        // in layoutSubviews so it tracks the zoomed bounds.
        tiled.shadowColor = UIColor.black.cgColor
        tiled.shadowOpacity = 0.14
        tiled.shadowRadius = 10
        tiled.shadowOffset = CGSize(width: 0, height: 5)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        tiledLayer.shadowPath = UIBezierPath(rect: bounds).cgPath
    }

    /// Turns the paper drop shadow on or off (S1a-4 Page shadow). Off sets the
    /// shadow opacity to zero, leaving the crisp tiles untouched.
    func setShadow(enabled: Bool) {
        tiledLayer.shadowOpacity = enabled ? 0.14 : 0
    }

    // MARK: - Accessibility (adjustable zoom + custom actions)

    func applyAccessibility(chromeHidden: Bool) {
        self.chromeHidden = chromeHidden
        // `updateUIView` calls this every pass; the traits never change and the
        // actions only differ in the toggle's name, so rebuild just when the chrome
        // state actually moved — not on every unrelated update (P2).
        guard appliedChromeHidden != chromeHidden else { return }
        appliedChromeHidden = chromeHidden
        accessibilityTraits = [.image, .adjustable]
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Zoom In") { [weak self] _ in self?.controller?.zoomIn(); return true },
            UIAccessibilityCustomAction(name: "Zoom Out") { [weak self] _ in self?.controller?.zoomOut(); return true },
            UIAccessibilityCustomAction(name: "Fit") { [weak self] _ in self?.controller?.fit(); return true },
            UIAccessibilityCustomAction(name: "Actual Size") { [weak self] _ in self?.controller?.actualSize(); return true },
            UIAccessibilityCustomAction(name: chromeHidden ? "Show controls" : "Hide controls") { [weak self] _ in
                self?.onToggleChrome?()
                return true
            },
        ]
    }

    // The adjustable trait makes VoiceOver speak the new value itself, so suppress
    // Emfy's own zoom announcement here to avoid double speech (A12).
    override func accessibilityIncrement() { controller?.zoomIn(announce: false) }
    override func accessibilityDecrement() { controller?.zoomOut(announce: false) }

    /// Re-renders the tiles at a new display scale (e.g. moving between displays).
    func updateContentsScale(_ scale: CGFloat) {
        let resolved = scale > 0 ? scale : 1
        if tiledLayer.contentsScale != resolved {
            tiledLayer.contentsScale = resolved
            setNeedsDisplay()
        }
    }

    // `CATiledLayer` draws tiles on its own background thread, so this must be
    // `nonisolated` (a `@MainActor` draw trips Swift 6's executor check — the
    // tiled-layer thread isn't the main actor). It touches only immutable,
    // `Sendable` state: `prepared`, `naturalSize`, and the passed context. The
    // view is zoomed by the scroll view's transform, so `bounds` never changes
    // from `naturalSize` — using the constant avoids reading `@MainActor`
    // geometry off the main thread.
    nonisolated override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        // White only this tile — the metafile assumes a white page.
        context.setFillColor(UIColor.white.cgColor)
        context.fill(rect)
        // UIKit's draw context is y-down; the renderer maps device space onto a
        // y-up target (as its CGImage/PDF paths do), so flip around the full
        // height before playing the records. The tile clip (set by CATiledLayer)
        // limits what is actually rasterised.
        context.translateBy(x: 0, y: naturalSize.height)
        context.scaleBy(x: 1, y: -1)
        _ = MetafileRenderer.render(
            prepared,
            into: context,
            target: CGRect(origin: .zero, size: naturalSize)
        )
    }
}
