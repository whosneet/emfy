import AppKit
import CoreGraphics
import SwiftUI

// MARK: - Mac record step-through replay canvas (F5c)
//
// A dedicated, self-contained zoomable view of the partial-playback raster, shown in
// the viewer's canvas area while the Records segment is active. It is NOT an overlay
// on the live tiled viewer — leaving the segment restores that view unchanged. It has
// its own fit / magnify / pan (an `NSScrollView`), draws the current record's device
// bounds as an outline, and swaps in each new step image as the background render
// lands.

/// Displays the step-through raster with its own fit, zoom and pan, outlining the
/// current record's device bounds.
struct MacRecordReplayView: NSViewRepresentable {
    let image: CGImage?
    let pixelSize: CGSize
    let deviceBounds: CGRect
    let outlineDeviceRect: CGRect?
    /// Bumped by the driver on each applied step; a change refreshes the raster, and a
    /// change of `pixelSize` re-fits.
    let contentToken: Int
    /// ←/→ step and ⌥←/⌥→ jump to the previous/next drawing record when the replay
    /// view has keyboard focus (F5c). `forward` is → ; `option` is the ⌥ modifier.
    let onArrowStep: (_ forward: Bool, _ option: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ReplayScrollView()
        scrollView.onArrowStep = onArrowStep
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = MacMetafileScrollView.backdropColor
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 16

        let canvas = ReplayCanvasView(frame: CGRect(origin: .zero, size: resolvedPixelSize))
        scrollView.documentView = canvas
        context.coordinator.canvas = canvas
        context.coordinator.scrollView = scrollView

        scrollView.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.fitIfNeeded()
        }
        apply(to: canvas)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        (scrollView as? ReplayScrollView)?.onArrowStep = onArrowStep
        guard let canvas = context.coordinator.canvas else { return }
        let pixelChanged = canvas.frame.size != resolvedPixelSize
        if pixelChanged {
            canvas.frame = CGRect(origin: .zero, size: resolvedPixelSize)
            context.coordinator.needsFit = true
        }
        apply(to: canvas)
        if context.coordinator.appliedToken != contentToken {
            context.coordinator.appliedToken = contentToken
            if pixelChanged { context.coordinator.fitIfNeeded() }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        (scrollView as? ReplayScrollView)?.onLayout = nil
        (scrollView as? ReplayScrollView)?.onArrowStep = nil
        coordinator.canvas = nil
        coordinator.scrollView = nil
    }

    private var resolvedPixelSize: CGSize {
        CGSize(width: max(1, pixelSize.width), height: max(1, pixelSize.height))
    }

    private func apply(to canvas: ReplayCanvasView) {
        canvas.image = image
        canvas.deviceBounds = deviceBounds
        canvas.outlineDeviceRect = outlineDeviceRect
        canvas.needsDisplay = true
    }

    @MainActor
    final class Coordinator {
        weak var canvas: ReplayCanvasView?
        weak var scrollView: NSScrollView?
        var appliedToken = -1
        var needsFit = true
        private var hasFitOnce = false

        /// Fits the canvas into the viewport on first layout and whenever the content
        /// size changes; otherwise leaves the user's zoom/pan put.
        func fitIfNeeded() {
            guard let scrollView, let canvas else { return }
            let viewport = scrollView.contentView.frame.size
            guard viewport.width > 0, viewport.height > 0 else { return }
            guard needsFit || !hasFitOnce else { return }
            let content = canvas.frame.size
            guard content.width > 0, content.height > 0 else { return }
            let fit = min(viewport.width / content.width, viewport.height / content.height) * 0.96
            let clamped = min(max(fit, scrollView.minMagnification), scrollView.maxMagnification)
            scrollView.magnification = clamped
            let centre = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
            scrollView.setMagnification(clamped, centeredAt: centre)
            needsFit = false
            hasFitOnce = true
        }
    }
}

/// An `NSScrollView` that reports layout so the replay fit can follow the viewport,
/// and takes keyboard focus so ←/→ step and ⌥←/⌥→ jump drawing records (F5c).
private final class ReplayScrollView: NSScrollView {
    var onLayout: (() -> Void)?
    var onArrowStep: ((_ forward: Bool, _ option: Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { bounds.fill() }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func keyDown(with event: NSEvent) {
        let option = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 123: onArrowStep?(false, option)   // left arrow
        case 124: onArrowStep?(true, option)    // right arrow
        default: super.keyDown(with: event)
        }
    }
}

/// A flipped `NSView` that draws the step raster filling its bounds and outlines the
/// current record's device rect, mapped device → pixel. Flipped (top-origin) so the
/// device-space y-down mapping and the raster's top row line up.
final class ReplayCanvasView: NSView {
    var image: CGImage?
    var deviceBounds: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var outlineDeviceRect: CGRect?

    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.white.setFill()
        bounds.fill()
        if let image {
            // Draw top-origin: the flipped view's y grows downward, so translate+flip
            // the one image blit back to a bottom-left blit filling `bounds`.
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(image, in: bounds)
            context.restoreGState()
        }
        guard let outlineDeviceRect, let viewRect = mapToView(outlineDeviceRect) else { return }
        let path = NSBezierPath(rect: viewRect.insetBy(dx: -1, dy: -1))
        path.lineWidth = max(1, 2 / currentScale)
        NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
        path.stroke()
        NSColor.systemBlue.withAlphaComponent(0.12).setFill()
        path.fill()
    }

    /// The scroll view's magnification, so the outline stroke stays ~2 pt on screen.
    private var currentScale: CGFloat { enclosingScrollView?.magnification ?? 1 }

    /// Maps a device-space rect into this canvas's point space (top-origin, size =
    /// pixel size). Returns nil when the device bounds are degenerate.
    private func mapToView(_ deviceRect: CGRect) -> CGRect? {
        guard deviceBounds.width > 0, deviceBounds.height > 0 else { return nil }
        let sx = bounds.width / deviceBounds.width
        let sy = bounds.height / deviceBounds.height
        return CGRect(
            x: (deviceRect.minX - deviceBounds.minX) * sx,
            y: (deviceRect.minY - deviceBounds.minY) * sy,
            width: deviceRect.width * sx,
            height: deviceRect.height * sy
        )
    }
}
