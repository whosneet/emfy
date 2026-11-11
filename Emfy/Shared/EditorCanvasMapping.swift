import CoreGraphics
import EMFEdit

/// The single, tested mapping between the editor overlay's VIEW space (points in
/// the canvas/paper view the scene is drawn into) and the scene's DEVICE space
/// (the source's y-down device coordinates — see `Scene`). Hit testing, the
/// marquee, the selection overlay and the transform gestures all run through it, so
/// one helper owns the conversion in both directions, plus the view-length→
/// device-length conversion the stroke hit tolerance and the constant-size handles
/// need (design call E2b-3).
///
/// `deviceToView` mirrors `SceneRenderer.deviceToTarget(pageBounds:target:)`
/// EXACTLY — the same per-side fit and the same single y-flip — so a point tested
/// against the scene lines up pixel-for-pixel with what `SceneRenderer` drew on the
/// canvas. The y-flip is folded into the mapping, so a caller never flips twice.
struct EditorCanvasMapping: Equatable {
    /// The scene page in device space (`Scene.pageBoundsDevice`).
    let pageBoundsDevice: CGRect
    /// The view-space rectangle the page is drawn into (the paper/overlay bounds).
    let target: CGRect
    /// Whether the mapping flips y. The Mac overlay is y-up (matching
    /// `SceneRenderer`'s y-up target), so it flips (the default). The iOS overlay is
    /// y-down, exactly like EMF device space, so it maps straight through with no
    /// flip (`flipY = false`). The iOS tiled view applies its own UIKit flip when it
    /// draws, which is independent of this pointer mapping.
    let flipY: Bool

    init(pageBoundsDevice: CGRect, target: CGRect, flipY: Bool = true) {
        self.pageBoundsDevice = pageBoundsDevice
        self.target = target
        self.flipY = flipY
    }

    /// device → view. With `flipY` it is identical to
    /// `SceneRenderer.deviceToTarget(pageBounds:target:)`; without, a pure scale/offset
    /// (both spaces y-down).
    var deviceToView: CGAffineTransform {
        let deviceWidth = max(pageBoundsDevice.width, 1)
        let deviceHeight = max(pageBoundsDevice.height, 1)
        let sx = target.width / deviceWidth
        let sy = target.height / deviceHeight
        if flipY {
            return CGAffineTransform(
                a: sx, b: 0, c: 0, d: -sy,
                tx: target.minX - sx * pageBoundsDevice.minX,
                ty: target.maxY + sy * pageBoundsDevice.minY
            )
        }
        return CGAffineTransform(
            a: sx, b: 0, c: 0, d: sy,
            tx: target.minX - sx * pageBoundsDevice.minX,
            ty: target.minY - sy * pageBoundsDevice.minY
        )
    }

    /// view → device (the inverse; the un-inverted transform if it is singular,
    /// which never happens for a non-degenerate page and target).
    var viewToDevice: CGAffineTransform { deviceToView.inverted() }

    func devicePoint(fromView point: CGPoint) -> CGPoint { point.applying(viewToDevice) }
    func viewPoint(fromDevice point: CGPoint) -> CGPoint { point.applying(deviceToView) }
    func deviceRect(fromView rect: CGRect) -> CGRect { rect.applying(viewToDevice) }
    func viewRect(fromDevice rect: CGRect) -> CGRect { rect.applying(deviceToView) }

    /// A view-space length (points) expressed in device units, via the mapping's
    /// average scale — the "4 view-points" stroke hit tolerance and the handle hit
    /// targets convert through here, so they stay a constant size on screen at any
    /// zoom.
    func deviceLength(fromViewLength length: CGFloat) -> CGFloat {
        length * Self.averageScale(viewToDevice)
    }

    /// The reverse: a device length in view points.
    func viewLength(fromDeviceLength length: CGFloat) -> CGFloat {
        length * Self.averageScale(deviceToView)
    }

    /// Conjugates a VIEW-space transform (a resize/rotation computed in the
    /// overlay's own, un-flipped view space) into the DEVICE-space affine a
    /// `SceneCommand.applyTransform` expects: `viewToDevice ∘ viewTransform ∘
    /// deviceToView`. Keeping the gesture maths in view space means handle semantics
    /// (top/left/…) are purely visual; this folds in the y-flip once.
    func deviceTransform(fromView viewTransform: CGAffineTransform) -> CGAffineTransform {
        deviceToView.concatenating(viewTransform).concatenating(viewToDevice)
    }

    static func averageScale(_ t: CGAffineTransform) -> CGFloat {
        let sx = (t.a * t.a + t.b * t.b).squareRoot()
        let sy = (t.c * t.c + t.d * t.d).squareRoot()
        return (sx + sy) / 2
    }
}
