import AppKit
import CoreGraphics
import EMFRender
import SwiftUI

/// Drives the Mac viewer's live zoom state across the AppKit bridge and exposes the
/// imperative commands the toolbar and keyboard shortcuts invoke. One per open
/// document; `MacViewerPane` observes it for the toolbar percentage and the
/// inspector's Zoom row (the macOS counterpart of iOS's `MetafileZoomController`).
@MainActor
@Observable
final class MacMetafileZoomController {
    /// Current magnification, where 1.0 == 100% (one natural point per device pixel
    /// before the backing scale).
    var zoom: CGFloat = 1
    /// The scale that fits the picture in the current visible content rect.
    var fitScale: CGFloat = 1

    /// The scroll view is AppKit-owned; the controller only sends it commands.
    @ObservationIgnored weak var scrollView: NSScrollView?
    @ObservationIgnored private var announceTask: Task<Void, Never>?

    func fit() { apply(fitScale) }
    func actualSize() { apply(1) }
    func zoomIn() { apply(ZoomMath.stepIn(from: currentMagnification)) }
    func zoomOut() { apply(ZoomMath.stepOut(from: currentMagnification)) }

    /// The scroll view's live magnification, or the mirrored value before it is set.
    private var currentMagnification: CGFloat { scrollView?.magnification ?? zoom }

    /// Applies a target magnification, clamped into the scroll view's range and
    /// anchored at the visible centre. `setMagnification(_:centeredAt:)` is called
    /// directly: neither the `animator()` proxy nor an implicit-animation context
    /// applies this method variant (both silently no-op it), so an animated wrapper
    /// would leave the zoom unchanged.
    private func apply(_ target: CGFloat) {
        guard let scrollView else { return }
        let clamped = ZoomMath.clamped(target, min: scrollView.minMagnification, max: scrollView.maxMagnification)
        let centre = ZoomMath.visibleCentre(of: scrollView.contentView.bounds)
        scrollView.setMagnification(clamped, centeredAt: centre)
        zoom = clamped
        announceZoom(clamped)
    }

    /// Announces the zoom to VoiceOver, debounced so a burst posts once, and only
    /// when VoiceOver is running. The one place both programmatic zooms and the
    /// coordinator's live magnification route through, so they never double-announce.
    func announceZoom(_ scale: CGFloat) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        let percent = Int((scale * 100).rounded())
        announceTask?.cancel()
        announceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "Zoom \(percent) percent",
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    }
}

/// An `NSScrollView` wrapping a `CATiledLayer`-backed view that re-rasterises the
/// vector metafile per tile at the on-screen resolution. Because it is vector the
/// drawing stays crisp at any magnification, and because `CATiledLayer` only draws
/// the visible tiles on its own background queue, memory stays bounded to the
/// screen — never a full-canvas bitmap at 800% of a large file (v3-plan §9.2
/// "Mac viewer with pinch zoom and anchor-preserving zoom"; the macOS mirror of
/// iOS's `ZoomableMetafileView`). Pinch and ⌘-scroll magnify, anchored at the
/// cursor; the toolbar and keyboard drive the controller.
struct MacMetafileScrollView: NSViewRepresentable {
    let prepared: MetafileRenderer.Prepared
    /// The C2-clamped display size — never the raw header bounds, so a hostile
    /// `rclBounds` can't become billion-point geometry (MetafileLoader.displaySize).
    let naturalSize: CGSize
    let drawingLabel: String
    let controller: MacMetafileZoomController
    /// The default zoom a fresh open lands on (S1a-4). Applied once, so it never
    /// overrides a zoom kept across an identical-content reload (C4a M4).
    var defaultZoom: EmfySettings.DefaultZoom = .fit
    /// Whether the paper carries its drop shadow (S1a-4). Toggles live.
    var pageShadow: Bool = true

    /// The paper's drop shadow, built fresh each time it's applied (an `NSShadow`
    /// shouldn't be shared across views). `nil` when the setting is off.
    static func makePaperShadow() -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        return shadow
    }

    /// The viewer backdrop: ~0.90 grey in light mode so the white page and its edge
    /// read clearly (macOS 27's underPageBackgroundColor is near-white there), and
    /// dark in dark mode. Painted on both the scroll view and its clip view.
    static let backdropColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.14, alpha: 1)
            : NSColor(white: 0.90, alpha: 1)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ZoomMetafileScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Self.backdropColor
        scrollView.allowsMagnification = true
        // Placeholder range until the first layout computes the fit scale; both are
        // valid (min ≤ max, both > 0) so an early magnify never asserts.
        scrollView.minMagnification = 0.01
        scrollView.maxMagnification = ZoomMath.maxZoom

        // A centring clip view holds a small picture in the middle of the viewport.
        // The clip view IS the viewport, so the backdrop is painted here too, not
        // only on the scroll view: a non-drawing clip view is layer-backed by the
        // SwiftUI host, and in light mode its near-white backing shows through and
        // hides the scroll view's own backdrop (the page then floats on pure white
        // 255,255,255 rather than ~0.90 grey — dark mode happened to match). Painting
        // the viewport grey fixes it in both modes (C3b scope 8).
        let clipView = CenteringClipView()
        clipView.drawsBackground = true
        clipView.backgroundColor = Self.backdropColor
        scrollView.contentView = clipView

        // The tiled view draws into a CATiledLayer, which overwrites any shadow set on
        // its own layer; carry the paper shadow on a plain, opaque-white container
        // instead, so AppKit renders it and the page edge reads in both modes.
        let paper = NSView(frame: CGRect(origin: .zero, size: naturalSize))
        paper.wantsLayer = true
        paper.layer?.backgroundColor = NSColor.white.cgColor
        paper.shadow = pageShadow ? Self.makePaperShadow() : nil

        let tiled = TiledMetafileView(prepared: prepared, naturalSize: naturalSize)
        tiled.frame = paper.bounds
        tiled.autoresizingMask = [.width, .height]
        tiled.setAccessibilityLabelText(drawingLabel)
        tiled.controller = controller
        paper.addSubview(tiled)
        scrollView.documentView = paper

        context.coordinator.scrollView = scrollView
        context.coordinator.tiledView = tiled
        controller.scrollView = scrollView

        // The real bounds are known in `layout()`, not here — configure the fit and
        // the magnification range there, and again on every resize.
        scrollView.onLayout = { [weak coordinator = context.coordinator] viewport in
            coordinator?.configureZoomScales(for: viewport)
        }
        // ⌘-scroll magnifies, anchored at the cursor (plain scroll still scrolls).
        scrollView.onCommandScroll = { [weak coordinator = context.coordinator] event in
            coordinator?.handleCommandScroll(event) ?? false
        }
        context.coordinator.startObserving(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let tiled = context.coordinator.tiledView {
            tiled.controller = controller
            tiled.setAccessibilityLabelText(drawingLabel)
        }
        // Live-toggle the paper shadow (the document view is the paper).
        scrollView.documentView?.shadow = pageShadow ? Self.makePaperShadow() : nil
    }

    /// Stop the `CATiledLayer` drawing into a view about to be freed, and break the
    /// notification/callback references (§5 "No CATiledLayer draw into a freed view").
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
        (scrollView as? ZoomMetafileScrollView)?.onLayout = nil
        (scrollView as? ZoomMetafileScrollView)?.onCommandScroll = nil
        if let tiled = coordinator.tiledView {
            tiled.controller = nil
            tiled.layer?.contents = nil
            tiled.removeFromSuperview()
        }
        coordinator.tiledView = nil
        coordinator.scrollView = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: MacMetafileScrollView
        fileprivate weak var scrollView: NSScrollView?
        fileprivate weak var tiledView: TiledMetafileView?

        private var hasSetInitialZoom = false
        private var lastViewportSize: CGSize = .zero
        private var lastInsets: ViewerFit.Insets = .zero
        private var appliedFitScale: CGFloat = 1

        /// A small margin so the fitted page isn't flush with the window edges.
        private static let fitMargin: CGFloat = 24

        init(_ parent: MacMetafileScrollView) { self.parent = parent }

        /// The toolbar/safe-area the scroll view extends under (it uses
        /// `.ignoresSafeArea()` so content can scroll under the toolbar). Fit and
        /// centring must use the UNOBSCURED rect, not the full clip frame.
        private func effectiveInsets(_ scrollView: NSScrollView) -> ViewerFit.Insets {
            let s = scrollView.safeAreaInsets
            return ViewerFit.Insets(top: s.top, leading: s.left, bottom: s.bottom, trailing: s.right)
        }

        // MARK: Observation

        func startObserving(_ scrollView: NSScrollView) {
            let center = NotificationCenter.default
            // The clip view's bounds change during a pinch/⌘-scroll magnify and a
            // scroll, so this tracks the live magnification into the controller.
            center.addObserver(
                self, selector: #selector(clipViewBoundsChanged),
                name: NSView.boundsDidChangeNotification, object: scrollView.contentView
            )
            // The final value and the VoiceOver announce after a pinch settles.
            center.addObserver(
                self, selector: #selector(didEndLiveMagnify),
                name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView
            )
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func clipViewBoundsChanged() {
            guard let scrollView else { return }
            updateZoomState(scrollView.magnification)
        }

        @objc private func didEndLiveMagnify() {
            guard let scrollView else { return }
            updateZoomState(scrollView.magnification)
            parent.controller.announceZoom(scrollView.magnification)
        }

        // MARK: Zoom configuration

        func configureZoomScales(for viewport: CGSize) {
            guard viewport.width > 0, viewport.height > 0, let scrollView else { return }
            let natural = parent.naturalSize
            let insets = effectiveInsets(scrollView)
            // Fit inside the UNOBSCURED rect (clip frame minus the toolbar/safe-area
            // the scroll view extends under); a small margin keeps breathing room.
            let fit = ViewerFit.fitScale(
                content: natural, viewport: viewport, insets: insets,
                margin: Self.fitMargin, minScale: 0.01, maxScale: 1
            )
            // Read whether the picture was fitted BEFORE touching min/max — assigning
            // minMagnification clamps the live magnification, which would corrupt the
            // comparison (same ordering as iOS).
            let wasFitted = !hasSetInitialZoom || ZoomMath.wasFitted(current: scrollView.magnification, fit: appliedFitScale)
            let geometryChanged = viewport != lastViewportSize || insets != lastInsets

            scrollView.minMagnification = ZoomMath.minMagnification(fit: fit)
            scrollView.maxMagnification = ZoomMath.maxMagnification(fit: fit)
            parent.controller.fitScale = fit

            if !hasSetInitialZoom {
                hasSetInitialZoom = true
                let initial = ViewerZoomPolicy.initialScale(
                    for: parent.defaultZoom, fit: fit,
                    minScale: scrollView.minMagnification, maxScale: scrollView.maxMagnification
                )
                setMagnification(initial, on: scrollView)
                // Give the drawing keyboard focus once it's laid out, so arrow/Page
                // scrolling works without a click first (A4). Deferred to the next
                // runloop so it runs after SwiftUI's split-view focus setup, which
                // otherwise reclaims first responder for the sidebar.
                DispatchQueue.main.async { [weak scrollView] in
                    guard let scrollView, scrollView.window?.firstResponder !== scrollView else { return }
                    scrollView.window?.makeFirstResponder(scrollView)
                }
            } else if geometryChanged {
                // Refit on resize ONLY while fitted; otherwise just clamp the live
                // zoom back into the new range (§3 "Refit on window resize ONLY
                // while fitted").
                if wasFitted {
                    setMagnification(fit, on: scrollView)
                } else {
                    let clamped = ZoomMath.clamped(scrollView.magnification, min: scrollView.minMagnification, max: scrollView.maxMagnification)
                    setMagnification(clamped, on: scrollView)
                }
            }

            appliedFitScale = fit
            lastViewportSize = viewport
            lastInsets = insets
            updateZoomState(scrollView.magnification)
        }

        /// Sets the magnification without animation (layout-driven), anchored at the
        /// visible centre.
        private func setMagnification(_ value: CGFloat, on scrollView: NSScrollView) {
            let centre = ZoomMath.visibleCentre(of: scrollView.contentView.bounds)
            scrollView.setMagnification(value, centeredAt: centre)
        }

        // MARK: ⌘-scroll

        func handleCommandScroll(_ event: NSEvent) -> Bool {
            guard let scrollView else { return false }
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
            guard delta != 0 else { return true }
            let newMag = ZoomMath.scrollZoomMagnification(
                current: scrollView.magnification, scrollDelta: delta,
                precise: event.hasPreciseScrollingDeltas,
                min: scrollView.minMagnification, max: scrollView.maxMagnification
            )
            // Anchor at the cursor, in the clip view's coordinate space.
            let point = scrollView.contentView.convert(event.locationInWindow, from: nil)
            scrollView.setMagnification(newMag, centeredAt: point)
            updateZoomState(newMag)
            parent.controller.announceZoom(newMag)
            return true
        }

        // MARK: Zoom state

        /// Mirrors the live zoom into the controller (toolbar / inspector) and the
        /// drawing's accessibility value. The clip-bounds notification fires on a
        /// plain scroll too, where the magnification is unchanged, so only write when
        /// the value actually moves — Observation doesn't dedupe equal writes, and an
        /// unchanged write would invalidate the zoom-percent leaf each pan frame (P9).
        private func updateZoomState(_ scale: CGFloat) {
            if parent.controller.zoom != scale {
                parent.controller.zoom = scale
            }
            tiledView?.setAccessibilityValueText("\(Int((scale * 100).rounded())) percent")
        }
    }
}

/// An `NSScrollView` that reports its laid-out visible size, so the magnification
/// range and the initial fit are set once real bounds exist (and reset when they
/// change), intercepts ⌘-scroll to magnify anchored at the cursor, and takes
/// keyboard focus so arrow / Page / Home / End scroll a zoomed drawing (C4a A4).
private final class ZoomMetafileScrollView: NSScrollView {
    var onLayout: ((CGSize) -> Void)?
    var onCommandScroll: ((NSEvent) -> Bool)?

    // Take keyboard focus, with a focus ring, so arrow/Page/Home/End scroll (A4).
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { bounds.fill() }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { noteFocusRingChanged() }
        return became
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { noteFocusRingChanged() }
        return resigned
    }
    private func noteFocusRingChanged() { setKeyboardFocusRingNeedsDisplay(bounds) }

    override func layout() {
        super.layout()
        // Report every layout pass (not just size changes): the safe-area/toolbar
        // inset can change while the clip size stays the same (the toolbar appearing
        // after the first layout, or a full-screen toggle). The coordinator only
        // refits when the viewport OR the insets actually change, so this is cheap.
        // The clip frame is the visible viewport in points (the magnification scales
        // its bounds, not its frame).
        onLayout?(contentView.frame.size)
    }

    override func scrollWheel(with event: NSEvent) {
        if allowsMagnification,
           event.modifierFlags.contains(.command),
           onCommandScroll?(event) == true {
            return
        }
        super.scrollWheel(with: event)
    }

    /// Arrow / Page / Home / End scroll the zoomed drawing within the scrollable
    /// range (A4). The clip view is non-flipped (y up), so the document's top is at
    /// high y; "up" increases the origin's y.
    override func keyDown(with event: NSEvent) {
        guard handleScrollKey(event) else { super.keyDown(with: event); return }
    }

    private func handleScrollKey(_ event: NSEvent) -> Bool {
        let clip = contentView
        let visible = clip.bounds.size
        var origin = clip.bounds.origin
        let line: CGFloat = 48
        let pageH = max(visible.height - 48, visible.height * 0.5)
        let doc = documentView?.frame ?? .zero

        switch event.keyCode {
        case 126: origin.y += line                 // up arrow
        case 125: origin.y -= line                 // down arrow
        case 123: origin.x -= line                 // left arrow
        case 124: origin.x += line                 // right arrow
        case 116: origin.y += pageH                // page up
        case 121: origin.y -= pageH                // page down
        case 115: origin.y = doc.maxY              // home → top
        case 119: origin.y = doc.minY              // end → bottom
        default: return false
        }

        origin.x = min(max(origin.x, doc.minX), max(doc.minX, doc.maxX - visible.width))
        origin.y = min(max(origin.y, doc.minY), max(doc.minY, doc.maxY - visible.height))
        clip.scroll(to: origin)
        reflectScrolledClipView(clip)
        return true
    }
}

/// An `NSClipView` that centres the document view when it is smaller than the
/// visible region, so a fitted or small picture sits in the middle of the window
/// rather than pinned to a corner — and, crucially, centres it in the UNOBSCURED
/// region below the toolbar, not the full clip (which extends under it). When the
/// page is larger than the region it is not re-centred, so it scrolls freely under
/// the toolbar (the scroll-edge effect).
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        // Safe-area insets are in points; convert to this clip view's bounds
        // coordinates, which the magnification scales (bounds = frame / magnification).
        // The scroll view ignores the safe area and extends under the toolbar and the
        // macOS-26 floating sidebar, so those insets mark the unobscured detail rect.
        let insets = enclosingScrollView?.safeAreaInsets ?? safeAreaInsets
        let sx = frame.width > 0 ? bounds.width / frame.width : 1
        let sy = frame.height > 0 ? bounds.height / frame.height : 1
        rect.origin = ViewerFit.centeredClipOrigin(
            proposed: rect.origin,
            content: documentView.frame.size,
            bounds: rect.size,
            insets: ViewerFit.Insets(
                top: insets.top * sy,
                leading: insets.left * sx,
                bottom: insets.bottom * sy,
                trailing: insets.right * sx
            )
        )
        return rect
    }
}

/// A `CATiledLayer`-backed `NSView` that draws the vector metafile for each tile at
/// the tile's current resolution. The page is whited per tile so the paper stays
/// white in dark mode; the renderer draws the ink over it. Tiles are rasterised on
/// `CATiledLayer`'s own background queue, off the main thread.
private final class TiledMetafileView: NSView {
    private let prepared: MetafileRenderer.Prepared
    private let naturalSize: CGSize

    /// Zoom commands for the accessibility value and the Zoom custom actions.
    weak var controller: MacMetafileZoomController?

    init(prepared: MetafileRenderer.Prepared, naturalSize: CGSize) {
        self.prepared = prepared
        self.naturalSize = naturalSize
        super.init(frame: CGRect(origin: .zero, size: naturalSize))
        wantsLayer = true
        configureAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer {
        let tiled = CATiledLayer()
        // Bias 4 keeps 800% (= 8× × 2× backing = 16×) crisp. The reduced levels are
        // derived from the page size so a huge page draws a small coarse tile at fit
        // instead of a 1/8-resolution giant — the dominant cost of a hostile page.
        // (The paper shadow lives on the plain container; a CATiledLayer overwrites
        // its own shadow properties.)
        tiled.levelsOfDetail = ZoomMath.tiledLevelsOfDetail(forLongSide: max(naturalSize.width, naturalSize.height))
        tiled.levelsOfDetailBias = 4
        tiled.tileSize = CGSize(width: 512, height: 512)
        tiled.contentsScale = window?.backingScaleFactor ?? 2
        return tiled
    }

    /// y-up, to match the renderer's target (its CGImage/PDF paths render into a
    /// bottom-left-origin context; the Mac draw context is already y-up here, so no
    /// flip is needed, unlike UIKit's y-down context on iOS).
    override var isFlipped: Bool { false }

    /// Re-render the tiles when the window moves between a Retina and a non-Retina
    /// display (or on first attach), so the base tiles match the backing scale (§3).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        if let tiled = layer as? CATiledLayer, tiled.contentsScale != scale {
            tiled.contentsScale = scale
            setNeedsDisplay(bounds)
        }
    }

    // `CATiledLayer` draws tiles on its own background thread, so this must be
    // `nonisolated` (a `@MainActor` draw trips Swift 6's executor check — the
    // tiled-layer thread isn't the main actor). It touches only immutable,
    // `Sendable` state: `prepared`, `naturalSize`, and the thread's current graphics
    // context. The view is scaled by the scroll view's magnification, so the render
    // target is always the constant `naturalSize`.
    nonisolated override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // White only this tile — the metafile assumes a white page.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(dirtyRect)
        // The tile clip (set by CATiledLayer) limits what is actually rasterised;
        // the render call plays the whole picture into the view's y-up space.
        _ = MetafileRenderer.render(
            prepared,
            into: context,
            target: CGRect(origin: .zero, size: naturalSize)
        )
    }

    // MARK: - Accessibility (image element + adjustable zoom + custom actions)

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityValue("100 percent")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Zoom In") { [weak self] in self?.controller?.zoomIn(); return true },
            NSAccessibilityCustomAction(name: "Zoom Out") { [weak self] in self?.controller?.zoomOut(); return true },
            NSAccessibilityCustomAction(name: "Fit") { [weak self] in self?.controller?.fit(); return true },
            NSAccessibilityCustomAction(name: "Actual Size") { [weak self] in self?.controller?.actualSize(); return true },
        ])
    }

    func setAccessibilityLabelText(_ label: String) {
        setAccessibilityLabel(label)
    }

    func setAccessibilityValueText(_ value: String) {
        setAccessibilityValue(value)
    }

    // VoiceOver's increment/decrement gestures (and the swipe on an adjustable
    // element) route to the zoom controller; the element keeps its image role and
    // its Zoom In/Out/Fit/Actual Size custom actions (A13 — comment corrected, no
    // behaviour change).
    override func accessibilityPerformIncrement() -> Bool {
        controller?.zoomIn()
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        controller?.zoomOut()
        return true
    }
}
