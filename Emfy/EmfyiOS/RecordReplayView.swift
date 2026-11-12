import CoreGraphics
import SwiftUI
import UIKit

// MARK: - iOS record step-through replay canvas (F5c)
//
// The iPad/iPhone counterpart of `MacRecordReplayView`: a dedicated, self-contained
// zoomable view of the partial-playback raster shown in the viewer's canvas area
// while the Records segment is active. Its own `UIScrollView` gives fit, pinch-zoom
// and pan; it outlines the current record's device bounds and swaps in each new step
// image as the background render lands. Leaving the segment restores the live tiled
// viewer unchanged.

/// Displays the step-through raster with its own fit, pinch-zoom and pan, outlining
/// the current record's device bounds.
struct RecordReplayView: UIViewRepresentable {
    let image: CGImage?
    let pixelSize: CGSize
    let deviceBounds: CGRect
    let outlineDeviceRect: CGRect?
    /// Bumped by the driver on each applied step; a change refreshes the raster, and a
    /// change of `pixelSize` re-fits.
    let contentToken: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = ReplayScrollView()
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .clear
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.minimumZoomScale = 0.02
        scrollView.maximumZoomScale = 16
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast

        let canvas = ReplayCanvasUIView(frame: CGRect(origin: .zero, size: resolvedPixelSize))
        scrollView.addSubview(canvas)
        scrollView.contentSize = resolvedPixelSize
        context.coordinator.canvas = canvas
        context.coordinator.scrollView = scrollView
        scrollView.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.fitIfNeeded()
        }
        apply(to: canvas)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let canvas = context.coordinator.canvas else { return }
        let pixelChanged = canvas.bounds.size != resolvedPixelSize
        if pixelChanged {
            canvas.frame = CGRect(origin: .zero, size: resolvedPixelSize)
            scrollView.contentSize = resolvedPixelSize
            context.coordinator.needsFit = true
        }
        apply(to: canvas)
        if context.coordinator.appliedToken != contentToken {
            context.coordinator.appliedToken = contentToken
            if pixelChanged { context.coordinator.fitIfNeeded() }
        }
    }

    static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
        scrollView.delegate = nil
        (scrollView as? ReplayScrollView)?.onLayout = nil
        coordinator.canvas = nil
        coordinator.scrollView = nil
    }

    private var resolvedPixelSize: CGSize {
        CGSize(width: max(1, pixelSize.width), height: max(1, pixelSize.height))
    }

    private func apply(to canvas: ReplayCanvasUIView) {
        canvas.setContent(image: image, deviceBounds: deviceBounds, outlineDeviceRect: outlineDeviceRect)
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var canvas: ReplayCanvasUIView?
        weak var scrollView: UIScrollView?
        var appliedToken = -1
        var needsFit = true
        private var hasFitOnce = false

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }

        func scrollViewDidZoom(_ scrollView: UIScrollView) { centre(scrollView) }

        /// Fits the canvas into the viewport on first layout and whenever the content
        /// size changes; otherwise leaves the user's zoom/pan put.
        func fitIfNeeded() {
            guard let scrollView, let canvas else { return }
            let viewport = scrollView.bounds.size
            guard viewport.width > 0, viewport.height > 0 else { return }
            guard needsFit || !hasFitOnce else { return }
            let content = canvas.bounds.size
            guard content.width > 0, content.height > 0 else { return }
            let fit = min(viewport.width / content.width, viewport.height / content.height) * 0.96
            scrollView.minimumZoomScale = min(fit, 1)
            scrollView.maximumZoomScale = max(16, fit)
            scrollView.zoomScale = fit
            centre(scrollView)
            needsFit = false
            hasFitOnce = true
        }

        private func centre(_ scrollView: UIScrollView) {
            guard let canvas else { return }
            let scaled = CGSize(width: canvas.bounds.width * scrollView.zoomScale,
                                height: canvas.bounds.height * scrollView.zoomScale)
            let x = max(0, (scrollView.bounds.width - scaled.width) / 2)
            let y = max(0, (scrollView.bounds.height - scaled.height) / 2)
            scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }
    }
}

/// A `UIScrollView` that reports layout so the replay fit can follow the viewport.
private final class ReplayScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    private var lastSize: CGSize = .zero
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            lastSize = bounds.size
            onLayout?()
        }
    }
}

/// Draws the step raster filling its bounds (y-down UIKit space) and outlines the
/// current record's device rect, mapped device → pixel (top-origin, matching the
/// raster's top row).
final class ReplayCanvasUIView: UIView {
    private var image: CGImage?
    private var deviceBounds: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var outlineDeviceRect: CGRect?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        isOpaque = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setContent(image: CGImage?, deviceBounds: CGRect, outlineDeviceRect: CGRect?) {
        self.image = image
        self.deviceBounds = deviceBounds
        self.outlineDeviceRect = outlineDeviceRect
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        UIColor.white.setFill()
        context.fill(bounds)
        if let image {
            // UIKit's draw context is y-down and the raster is top-origin, so a direct
            // CGContext.draw would flip it; flip once around the full height.
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(image, in: bounds)
            context.restoreGState()
        }
        guard let outlineDeviceRect, let viewRect = mapToView(outlineDeviceRect) else { return }
        let scale = (superview as? UIScrollView)?.zoomScale ?? 1
        let path = UIBezierPath(rect: viewRect.insetBy(dx: -1, dy: -1))
        path.lineWidth = max(1, 2 / scale)
        UIColor.systemBlue.withAlphaComponent(0.9).setStroke()
        path.stroke()
        UIColor.systemBlue.withAlphaComponent(0.12).setFill()
        path.fill()
    }

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
