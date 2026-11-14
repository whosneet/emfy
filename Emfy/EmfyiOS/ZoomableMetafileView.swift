import CoreGraphics
import EMFRender
import os
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

    /// Scrolls a DEVICE-space rect (a find match) into view, zooming OUT first when the
    /// match is larger than the viewport (F3b). iOS device space is y-down, like the zoom
    /// view's own space, so the mapping never flips. Works in both viewer and edit mode —
    /// `scrollView` points at whichever is active, and its zoom view (the tiled view or the
    /// paper) is at `naturalSize`.
    func scrollDeviceRectToVisible(_ deviceRect: CGRect, pageBoundsDevice: CGRect, naturalSize: CGSize) {
        guard let scrollView, naturalSize.width > 0, naturalSize.height > 0 else { return }
        let mapping = EditorCanvasMapping(
            pageBoundsDevice: pageBoundsDevice,
            target: CGRect(origin: .zero, size: naturalSize), flipY: false)
        if let target = FindHighlightGeometry.zoomToFit(
            deviceRect: deviceRect, mapping: mapping, viewport: scrollView.bounds.size,
            currentZoom: scrollView.zoomScale, minZoom: scrollView.minimumZoomScale) {
            scrollView.setZoomScale(target, animated: false)
        }
        let scale = scrollView.zoomScale
        let contentRect = mapping.viewRect(fromDevice: deviceRect)
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .insetBy(dx: -40, dy: -40)
        scrollView.scrollRectToVisible(contentRect, animated: !reduceMotion)
    }

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
    /// How the tiles are painted — page background + dark-mode treatment (S1a-4b).
    var tilePaint: TilePaint = .plain
    /// The render-time Rendering options — antialiasing, font substitutions, EMF+
    /// arbitration (S1b). A change redraws the tiles; the prepare-time option (the
    /// WMF embedded-EMF choice) arrives as a new `prepared` through the view's
    /// content identity, so this view never swaps `prepared`.
    var options: RenderOptions = .default
    /// The find highlights to draw above the tiles (F3b). `.empty` draws nothing.
    var findHighlights: FindHighlightSet = .empty
    /// Trailing width the FIT keeps clear for the inspector COLUMN (iPad read-only), so
    /// the fitted page is always narrow enough to clear the whole column. The scroll view
    /// fills the full width. Zero on iPhone (the inspector is a sheet) and when closed.
    var reservedTrailing: CGFloat = 0
    /// Trailing width the CENTRING uses — the inspector's floating translucent PANEL
    /// footprint, which is narrower than its column (the panel floats a fixed inset inside
    /// the column). Centring in the panel region while the fit clears the wider column
    /// leaves an equal margin on each side of the page, so the page sits centred between
    /// the screen edge and the panel with equal gaps (P1 review). Falls back to
    /// `reservedTrailing` when zero.
    var reservedCentreTrailing: CGFloat = 0
    /// Toggles the chrome; reused as the drawing's "Show/Hide controls" action.
    let onSingleTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Renders the low-resolution full-page placeholder once, off the main actor,
    /// and sets it on `placeholderView` (P2b). `prepared`, `naturalSize` and
    /// `options` are `Sendable`; the render is area-capped so its one allocation
    /// stays small, and the view is touched only back on the main actor.
    @MainActor
    static func renderPlaceholder(
        prepared: MetafileRenderer.Prepared,
        naturalSize: CGSize,
        options: RenderOptions,
        into placeholderView: UIImageView
    ) {
        Task { @MainActor [weak placeholderView] in
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let scale = ViewerFit.placeholderScale(forLongSide: max(naturalSize.width, naturalSize.height))
                return MetafileRenderer.makeImage(prepared, scale: scale, background: .white, options: options)?.0
            }.value
            guard let image, let placeholderView else { return }
            placeholderView.image = UIImage(cgImage: image)
        }
    }

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
            displayScale: displayScale,
            options: options
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
        tiled.setPaint(tilePaint)
        tiled.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        context.coordinator.tiledView = tiled

        // P2b: the zoom view is a container holding the tiled view, so a
        // low-resolution full-page placeholder can sit BENEATH the tiles. A
        // placeholder added as the tiled view's own subview would draw ABOVE its
        // CATiledLayer tiles (a subview is always above its superview's drawn
        // content); a sibling inside the zoomed container sits behind them and
        // shows through only where a tile has not drawn yet. Each sharp tile is
        // opaque (white page + ink), so it covers the placeholder as it lands and
        // the final pixels are unchanged. A cheap document gets an empty,
        // transparent container of identical geometry, so nothing changes for it.
        let zoomView = UIView(frame: CGRect(origin: .zero, size: naturalSize))
        if ViewerFit.isExpensiveToReplay(playbackOps: prepared.estimatedPlaybackOps) {
            let placeholderView = UIImageView(frame: zoomView.bounds)
            placeholderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            placeholderView.contentMode = .scaleToFill
            placeholderView.isAccessibilityElement = false
            zoomView.addSubview(placeholderView)
            context.coordinator.placeholderView = placeholderView
            Self.renderPlaceholder(prepared: prepared, naturalSize: naturalSize, options: options, into: placeholderView)
        }
        tiled.frame = zoomView.bounds
        zoomView.addSubview(tiled)
        context.coordinator.zoomView = zoomView
        context.coordinator.scrollView = scrollView
        scrollView.addSubview(zoomView)
        scrollView.contentSize = naturalSize
        controller.scrollView = scrollView

        // The find-highlight overlay rides the tiles (its subview), so it zooms/pans with
        // them (F3b). Transparent to touches.
        let findOverlay = IOSFindHighlightView(frame: tiled.bounds)
        findOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        findOverlay.controller = controller
        findOverlay.setHighlights(findHighlights)
        tiled.addSubview(findOverlay)
        context.coordinator.findOverlay = findOverlay

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
            tiled.setPaint(tilePaint)       // live page background + dark-mode treatment
            tiled.setOptions(options)       // live antialiasing / fonts / EMF+ arbitration (S1b)
            // Follow the display across a scale change (e.g. moving between
            // displays) — re-render the tiles at the new resolution.
            tiled.updateContentsScale(displayScale)
        }
        context.coordinator.findOverlay?.setHighlights(findHighlights)   // live find highlights (F3b)
        // Re-fit when the chrome toggles (§5): hiding the bars uses `.zero` insets
        // (full screen), showing them fits inside. `safeAreaInsetsDidChange` covers
        // most toggles; this makes the refit reliable even when the insets don't
        // move. Other zoom-scale configuration happens from `layoutSubviews`.
        context.coordinator.refitIfChromeChanged(scrollView, chromeHidden: chromeHidden)
        // The inspector opening/closing changes the clear region but NOT the scroll view's
        // bounds or safe area (the canvas fills the full width), so neither layout callback
        // fires — refit here so the page re-centres into the new clear region (P1).
        context.coordinator.refitIfReservedTrailingChanged(scrollView, reservedTrailing: reservedTrailing)
    }

    /// Stop the CATiledLayer drawing into a view about to be freed, and break the
    /// delegate/callback references.
    static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
        scrollView.delegate = nil
        (scrollView as? ZoomScrollView)?.onLayoutSize = nil
        (scrollView as? ZoomScrollView)?.onSafeAreaChange = nil
        coordinator.findOverlay?.controller = nil
        coordinator.findOverlay?.removeFromSuperview()
        coordinator.findOverlay = nil
        coordinator.placeholderView?.image = nil
        coordinator.placeholderView?.removeFromSuperview()
        coordinator.placeholderView = nil
        if let tiled = coordinator.tiledView {
            tiled.controller = nil
            tiled.onToggleChrome = nil
            tiled.layer.contents = nil
            tiled.removeFromSuperview()
        }
        coordinator.tiledView = nil
        coordinator.zoomView?.removeFromSuperview()
        coordinator.zoomView = nil
        coordinator.scrollView = nil
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableMetafileView
        fileprivate weak var tiledView: TiledMetafileView?
        fileprivate weak var findOverlay: IOSFindHighlightView?
        /// The zoom view: a container holding the placeholder (if any) beneath the
        /// tiled view, so both ride the scroll view's zoom transform together (P2b).
        fileprivate weak var zoomView: UIView?
        /// The scroll view, so the configuration no longer reads it through the
        /// tiled view's superview (now the container, not the scroll view) (P2b).
        fileprivate weak var scrollView: UIScrollView?
        /// The P2b full-page placeholder beneath the tiles (expensive documents only).
        fileprivate weak var placeholderView: UIImageView?

        private var hasSetInitialZoom = false
        private var lastViewportSize: CGSize = .zero
        private var lastInsets: ViewerFit.Insets = .zero
        private var lastChromeHidden: Bool?
        private var lastReservedTrailing: CGFloat = 0
        private var appliedFitScale: CGFloat = 1

        init(_ parent: ZoomableMetafileView) { self.parent = parent }

        // MARK: Zoom configuration

        /// The safe-area insets to fit inside: the scroll view's own insets (which
        /// track the bars) while the chrome is shown, and `.zero` when it is hidden
        /// so the drawing fills the screen (§5).
        /// Safe-area insets plus a trailing `reserve` for the inspector. When the chrome is
        /// hidden the bars' safe area is dropped for a full-screen fit, but the inspector
        /// strip (if any) is still kept clear (P1).
        private func insets(_ scrollView: UIScrollView, reserve: CGFloat) -> ViewerFit.Insets {
            guard !parent.chromeHidden else { return ViewerFit.Insets(trailing: reserve) }
            let i = scrollView.safeAreaInsets
            return ViewerFit.Insets(top: i.top, leading: i.left, bottom: i.bottom, trailing: i.right + reserve)
        }

        /// The FIT insets reserve the inspector COLUMN (`reservedTrailing`).
        private func effectiveInsets(_ scrollView: UIScrollView) -> ViewerFit.Insets {
            insets(scrollView, reserve: parent.reservedTrailing)
        }

        /// The CENTRING insets reserve the inspector PANEL footprint
        /// (`reservedCentreTrailing`, falling back to the column), so the fitted page —
        /// sized to clear the whole column — sits centred up to the panel's edge with an
        /// equal margin on each side (P1 review).
        private func centreInsets(_ scrollView: UIScrollView) -> ViewerFit.Insets {
            let reserve = parent.reservedCentreTrailing > 0 ? parent.reservedCentreTrailing : parent.reservedTrailing
            return insets(scrollView, reserve: reserve)
        }

        func configureZoomScales(for viewport: CGSize) {
            guard viewport.width > 0, viewport.height > 0,
                  let scrollView
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

        /// Re-fits when the reserved inspector width changed (the inspector opened or
        /// closed), so the page re-centres into the clear region beside it (P1). The
        /// scroll view's bounds don't change, so the layout callbacks don't fire.
        func refitIfReservedTrailingChanged(_ scrollView: UIScrollView, reservedTrailing: CGFloat) {
            guard hasSetInitialZoom, lastReservedTrailing != reservedTrailing else { return }
            lastReservedTrailing = reservedTrailing
            configureZoomScales(for: scrollView.bounds.size)
        }

        /// Centres the drawing inside the visible region, keeping it clear of the
        /// bars while they show (ViewerFit computes the safe-area + slack inset).
        private func centreContent(_ scrollView: UIScrollView) {
            let natural = parent.naturalSize
            let insets = centreInsets(scrollView)
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

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { zoomView }

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
            guard let zoomView, let scrollView else { return }
            let fit = parent.controller.fitScale
            let atFit = abs(scrollView.zoomScale - fit) < 0.01
            if atFit {
                // Fit → 2×, centred on the tap.
                let target = min(max(2, fit), scrollView.maximumZoomScale)
                let point = gesture.location(in: zoomView)
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
    /// The CATiledLayer tile side (pt), chosen once from the document's estimated
    /// replay cost: 512 for a cheap document, 1024 for an expensive one so a fit
    /// view needs a handful of full-stream replays instead of a dozen-plus (P2b).
    private let tileSide: CGFloat
    /// One decoded-DIB cache for this document (P2 performance): the tiled layer
    /// replays the record stream once per tile on concurrent threads, so without
    /// it every tile re-decodes each DIB from scratch. Thread-safe and shared. A
    /// smaller iOS budget than the macOS 64 MiB default (M4): iOS Quick Look / the
    /// app run under a tighter jetsam limit, and DIB entries are footprint-sized so
    /// 32 MiB still holds a document's DIBs across the zoom levels a viewer walks.
    private let imageCache = DIBImageCache(memoryBudget: 32 * 1024 * 1024)
    /// The tile paint (page + dark-mode treatment), read on the tiled-layer's
    /// background thread, set on the main thread — behind a lock (S1a-4b).
    private let paintLock = OSAllocatedUnfairLock<TilePaint>(initialState: .plain)
    /// The render-time Rendering options, read on the tiled-layer's background
    /// thread, set on the main thread — behind a lock (S1b).
    private let optionsLock: OSAllocatedUnfairLock<RenderOptions>

    /// Zoom commands for the adjustable trait and the Zoom custom actions.
    weak var controller: MetafileZoomController?

    /// Updates how tiles are painted and redraws them when it changes.
    func setPaint(_ paint: TilePaint) {
        let changed = paintLock.withLock { current -> Bool in
            guard current != paint else { return false }
            current = paint
            return true
        }
        // CATiledLayer caches rasterised tiles; invalidate the layer directly so
        // the visible tiles re-rasterise with the new paint (S1a-4b live update).
        if changed {
            setNeedsDisplay()
            tiledLayer.setNeedsDisplay()
        }
    }

    /// Updates the render-time options and re-rasterises the visible tiles when they
    /// change (S1b live update), the same way `setPaint` flushes the tile cache.
    func setOptions(_ options: RenderOptions) {
        let changed = optionsLock.withLock { current -> Bool in
            guard current != options else { return false }
            current = options
            return true
        }
        if changed {
            setNeedsDisplay()
            tiledLayer.setNeedsDisplay()
        }
    }
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

    init(prepared: MetafileRenderer.Prepared, naturalSize: CGSize, displayScale: CGFloat, options: RenderOptions) {
        self.prepared = prepared
        self.naturalSize = naturalSize
        self.tileSide = ViewerFit.tileSide(forPlaybackOps: prepared.estimatedPlaybackOps)
        self.optionsLock = OSAllocatedUnfairLock<RenderOptions>(initialState: options)
        super.init(frame: CGRect(origin: .zero, size: naturalSize))

        let tiled = tiledLayer
        // Four magnified levels keep 800% (2³) crisp with headroom; eight reduced
        // levels cover the fit scale of a large picture in a small viewport.
        tiled.levelsOfDetail = 8
        tiled.levelsOfDetailBias = 4
        tiled.tileSize = CGSize(width: tileSide, height: tileSide)
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

        // Free the decoded-DIB cache under memory pressure (M4): the next tile
        // simply re-decodes. The notification is posted on the main thread.
        NotificationCenter.default.addObserver(
            self, selector: #selector(purgeDecodedImageCache),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    /// Drops the decoded-DIB cache on a memory warning (M4), so the tiled layer's
    /// bitmap decodes are released before the app/extension is jetsam-killed.
    @objc private func purgeDecodedImageCache() {
        imageCache.purge()
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
        let paint = paintLock.withLock { $0 }
        let options = optionsLock.withLock { $0 }
        let natural = naturalSize
        let prepared = self.prepared
        // Page, then the drawing, then the dark-mode treatment (S1a-4b). UIKit's
        // draw context is y-down; the renderer targets a y-up space, so the ink
        // replay flips around the full height first (scoped by TilePainter's
        // save/restore, so the page fill and treatment stay in tile space).
        let imageCache = self.imageCache
        TilePainter.paint(paint, into: context, rect: rect) { ctx in
            ctx.translateBy(x: 0, y: natural.height)
            ctx.scaleBy(x: 1, y: -1)
            _ = MetafileRenderer.render(prepared, into: ctx, target: CGRect(origin: .zero, size: natural), options: options, imageCache: imageCache)
        }
    }
}
