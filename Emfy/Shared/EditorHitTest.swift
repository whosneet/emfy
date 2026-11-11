import CoreGraphics
import EMFEdit

/// App-side hit testing over an editable `Scene`, in DEVICE space (design call
/// E2b-3). Pure and tested; EMFKit is untouched — `ScenePath.cgPath` is the only
/// geometry conversion the editor needs, and it is already public.
enum EditorHitTest {

    /// The id of the top-most editable element under `devicePoint`, or nil. Elements
    /// are walked top-first (reverse z-order); hidden, locked and passthrough
    /// elements, and elements on a hidden or locked layer, are skipped.
    ///
    /// - `strokeToleranceDevice`: the slop around a stroked or open path, in device
    ///   units — the caller passes `mapping.deviceLength(fromViewLength: 4)`, so a
    ///   thin line is still easy to hit at any zoom.
    static func topmost(in scene: Scene, atDevice devicePoint: CGPoint, strokeToleranceDevice: CGFloat) -> Int? {
        for layer in scene.layers.reversed() where !(layer.hidden || layer.locked) {
            for element in layer.elements.reversed() where isHittable(element) {
                if hits(element, devicePoint: devicePoint, strokeToleranceDevice: strokeToleranceDevice) {
                    return element.id
                }
            }
        }
        return nil
    }

    /// Every editable element whose device-space bounds intersect `deviceRect` (a
    /// marquee drag), as an id set. Same skip rules as `topmost`.
    static func marquee(in scene: Scene, deviceRect: CGRect) -> Set<Int> {
        var ids: Set<Int> = []
        let box = deviceRect.standardized
        for layer in scene.layers where !(layer.hidden || layer.locked) {
            for element in layer.elements where isHittable(element) {
                let bounds = element.boundsDevice
                if !bounds.isNull, bounds.standardized.intersects(box) { ids.insert(element.id) }
            }
        }
        return ids
    }

    /// Whether the editor can select `element`: not hidden, not locked, and not a
    /// passthrough (verbatim content the editor shows but cannot represent).
    static func isHittable(_ element: Element) -> Bool {
        !element.hidden && !element.locked && element.kind != .passthrough && element.passthroughReason == nil
    }

    /// Whether `devicePoint` hits `element`. Text and image elements hit on their
    /// device-space bounds (`boundsDevice`); a filled path hits on point-in-path
    /// with the fill's winding rule; a stroked or unfilled/open path hits within the
    /// stroke tolerance of its outline (`CGPath.copy(strokingWithWidth:)`).
    ///
    /// `geometryDevice` is already in device space (see `Scene`/`SceneRenderer`,
    /// which draws it through the device→target fit alone, without `element.transform`),
    /// so the point is tested against the path directly — matching the render.
    static func hits(_ element: Element, devicePoint: CGPoint, strokeToleranceDevice: CGFloat) -> Bool {
        switch element.kind {
        case .text, .image:
            let bounds = element.boundsDevice
            return !bounds.isNull && bounds.standardized.contains(devicePoint)
        default:
            let tolerance = max(strokeHalfWidthDevice(element), strokeToleranceDevice)
            // Cheap bounds pre-reject: a point outside the element's bounds grown by the
            // tolerance can hit neither its fill nor its stroke, so skip the expensive
            // point-in-path / stroke-outline work entirely (keeps hit testing fast on
            // dense scenes — WS-B was 16 ms without this).
            let bounds = element.boundsDevice
            if !bounds.isNull, !bounds.standardized.insetBy(dx: -tolerance, dy: -tolerance).contains(devicePoint) {
                return false
            }
            let path = element.geometryDevice.cgPath
            if path.isEmpty { return !bounds.isNull && bounds.standardized.contains(devicePoint) }
            if let fill = element.style.fill,
               path.contains(devicePoint, using: fill.evenOdd ? .evenOdd : .winding, transform: .identity) {
                return true
            }
            // Stroked, or an unfilled/open path: within tolerance of the outline.
            if element.style.fill == nil || element.style.stroke != nil {
                let outline = path.copy(strokingWithWidth: tolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
                if outline.contains(devicePoint, using: .winding, transform: .identity) { return true }
            }
            return false
        }
    }

    /// The stroke half-width in DEVICE units. A cosmetic pen is ~1 device pixel; a
    /// geometric pen's logical width scales by the element's logical→device
    /// `transform` (the same derivation `SceneRenderer.deviceStroke` uses).
    static func strokeHalfWidthDevice(_ element: Element) -> CGFloat {
        guard let stroke = element.style.stroke else { return 0 }
        if stroke.isCosmetic { return 0.5 }
        return CGFloat(stroke.width) * EditorCanvasMapping.averageScale(element.transform) / 2
    }
}
