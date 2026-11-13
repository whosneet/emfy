import CoreGraphics
import EMFWrite
import Foundation

// MARK: - Generation plan → new Scene (X2d)
//
// Maps a validated `GenerationPlan` onto the EXISTING `SceneFactory` creation calls the E3
// shape/text tools use. A blank document for the declared page is built and imported to an
// empty scene, then each plan op becomes one (or, for an arrow, two) new editable elements
// inserted top-most. The result is an ordinary editable scene that saves, exports, undoes
// and renders like any other — so "generate a drawing" produces an editable EMF, not a blob.
//
// Call the validator FIRST: this builder assumes the plan is applicable (finite, in-page,
// positive sizes, valid colours) but still clamps defensively (§8) so a bad number never traps.

/// Why building a scene from a generation plan failed.
public enum GenerationBuildError: Error, Sendable, Equatable {
    /// The internally-built blank document failed to re-import (should never happen).
    case blankImportFailed
}

extension GenerationPlan {

    /// How many shapes and text labels the plan draws, for the preview summary
    /// ("12 shapes, 3 text labels"). Every op is one shape, except `text` (a label).
    public var summaryCounts: (shapes: Int, labels: Int) {
        var shapes = 0, labels = 0
        for op in operations { if op.isText { labels += 1 } else { shapes += 1 } }
        return (shapes, labels)
    }

    /// Builds a brand-new editable `Scene` from the plan. The validator must have passed;
    /// an unresolvable colour falls back to black, and a degenerate element is skipped so a
    /// borderline plan still produces its best scene rather than trapping.
    public func makeScene() throws -> Scene {
        let data = try SceneFactory.blankDocument(pageSizeMillimetres: page.preset.sizeMillimetres)
        guard var scene = try? SceneImporter.import(data: data) else {
            throw GenerationBuildError.blankImportFailed
        }
        let bounds = scene.pageBoundsDevice
        let dup = Double(scene.deviceUnitsPerPoint)
        // Per-axis plan-space → device scale.
        let sx: Double, sy: Double
        switch page.coordinateSpace {
        case .fraction: sx = Double(bounds.width); sy = Double(bounds.height)
        case .points: sx = dup; sy = dup
        }
        let lengthScale = page.coordinateSpace == .fraction ? min(sx, sy) : dup

        func dev(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: Double(bounds.minX) + x * sx, y: Double(bounds.minY) + y * sy)
        }
        func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
            CGRect(origin: dev(x, y), size: CGSize(width: w * sx, height: h * sy)).standardized
        }
        func strokeWidthDevice(_ sw: Double?) -> Double {
            let pts = (sw ?? 1.5)
            return max(0.1, (pts.isFinite ? pts : 1.5) * dup)
        }

        func insert(_ element: Element) { scene.insert(element, at: scene.elements.count) }
        func nextID() -> Int { SceneFactory.nextElementID(in: scene) }

        for op in operations {
            switch op {
            case let .rectangle(x, y, w, h, fill, stroke, sw):
                insert(SceneFactory.makeShape(kind: .rect, rectDevice: box(x, y, w, h),
                                              style: shapeStyle(fill, stroke, sw, strokeWidthDevice), id: nextID()))

            case let .roundedRectangle(x, y, w, h, radius, fill, stroke, sw):
                let r = max(0, (radius.isFinite ? radius : 0)) * lengthScale
                insert(SceneFactory.makeShape(kind: .roundRect, rectDevice: box(x, y, w, h),
                                              style: shapeStyle(fill, stroke, sw, strokeWidthDevice), id: nextID(),
                                              cornerRadiusDevice: r))

            case let .ellipse(x, y, w, h, fill, stroke, sw):
                insert(SceneFactory.makeShape(kind: .ellipse, rectDevice: box(x, y, w, h),
                                              style: shapeStyle(fill, stroke, sw, strokeWidthDevice), id: nextID()))

            case let .line(from, to, stroke, sw):
                let a = dev(from.x, from.y), b = dev(to.x, to.y)
                insert(SceneFactory.makeShape(kind: .line, rectDevice: CGRect(origin: a, size: CGSize(width: b.x - a.x, height: b.y - a.y)),
                                              style: lineStyle(stroke, sw, strokeWidthDevice), id: nextID()))

            case let .arrow(from, to, stroke, sw):
                let a = dev(from.x, from.y), b = dev(to.x, to.y)
                let style = lineStyle(stroke, sw, strokeWidthDevice)
                insert(SceneFactory.makeShape(kind: .line, rectDevice: CGRect(origin: a, size: CGSize(width: b.x - a.x, height: b.y - a.y)),
                                              style: style, id: nextID()))
                if let head = arrowheadElement(from: a, to: b, color: style.stroke?.color ?? .black,
                                               strokeWidthDevice: strokeWidthDevice(sw), id: nextID()) {
                    insert(head)
                }

            case let .polyline(points, stroke, sw):
                let pts = points.map { dev($0.x, $0.y) }
                if let element = openElement(points: pts, style: lineStyle(stroke, sw, strokeWidthDevice), id: nextID()) {
                    insert(element)
                }

            case let .polygon(points, fill, stroke, sw):
                let pts = points.map { dev($0.x, $0.y) }
                if let element = closedElement(points: pts, style: shapeStyle(fill, stroke, sw, strokeWidthDevice), id: nextID()) {
                    insert(element)
                }

            case let .text(x, y, _, _, string, color, fontSize, family):
                let pt = (fontSize.isFinite && fontSize > 0) ? fontSize : 16
                // Baseline just below the declared top, so the run reads inside its box.
                let origin = dev(x, y)
                let baseline = CGPoint(x: origin.x, y: origin.y + pt * dup * 0.8)
                insert(SceneFactory.makeText(string: string, originDevice: baseline,
                                             family: family?.isEmpty == false ? family! : "Helvetica",
                                             pointSize: pt, color: color?.color ?? .black,
                                             id: nextID(), deviceUnitsPerPoint: scene.deviceUnitsPerPoint))
            }
        }
        return scene
    }

    // MARK: Styles

    private func shapeStyle(_ fill: GenColor?, _ stroke: GenColor?, _ sw: Double?, _ widthDevice: (Double?) -> Double) -> SceneStyle {
        var style = SceneStyle()
        if let fillColor = fill?.color { style.fill = SceneFill(color: fillColor, evenOdd: false) }
        if let strokeColor = stroke?.color {
            style.stroke = SceneStroke(color: strokeColor, isCosmetic: false, width: widthDevice(sw),
                                       dash: .solid, cap: .round, join: .round, miterLimit: 10)
        }
        // A shape with neither fill nor stroke is invisible; give it a thin black outline.
        if style.fill == nil && style.stroke == nil {
            style.stroke = SceneStroke(color: .black, isCosmetic: false, width: widthDevice(sw),
                                       dash: .solid, cap: .round, join: .round, miterLimit: 10)
        }
        return style
    }

    private func lineStyle(_ stroke: GenColor?, _ sw: Double?, _ widthDevice: (Double?) -> Double) -> SceneStyle {
        SceneStyle(fill: nil, stroke: SceneStroke(color: stroke?.color ?? .black, isCosmetic: false,
                                                  width: widthDevice(sw), dash: .solid, cap: .round, join: .round, miterLimit: 10))
    }

    // MARK: Elements built directly (polyline/polygon/arrowhead)

    private func openElement(points: [CGPoint], style: SceneStyle, id: Int) -> Element? {
        guard let first = points.first, points.count >= 2 else { return nil }
        var segments: [ScenePath.Segment] = [.move(first)]
        for p in points.dropFirst() { segments.append(.line(p)) }
        return Element(id: id, kind: .polyline, geometryDevice: ScenePath(segments: segments), transform: .identity,
                       style: style, provenance: Provenance(sourceRecordIndices: [], edited: true), locked: false)
    }

    private func closedElement(points: [CGPoint], style: SceneStyle, id: Int) -> Element? {
        guard let first = points.first, points.count >= 3 else { return nil }
        var segments: [ScenePath.Segment] = [.move(first)]
        for p in points.dropFirst() { segments.append(.line(p)) }
        segments.append(.close)
        return Element(id: id, kind: .polygon, geometryDevice: ScenePath(segments: segments), transform: .identity,
                       style: style, provenance: Provenance(sourceRecordIndices: [], edited: true), locked: false)
    }

    /// A filled-triangle arrowhead at the `to` end of a shaft, built from the existing
    /// polygon primitive. `nil` for a zero-length shaft.
    private func arrowheadElement(from a: CGPoint, to b: CGPoint, color: SceneColor, strokeWidthDevice: Double, id: Int) -> Element? {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let length = (dx * dx + dy * dy).squareRoot()
        guard length.isFinite, length > 0.5 else { return nil }
        let ux = dx / length, uy = dy / length           // unit direction
        let px = -uy, py = ux                             // unit perpendicular
        let headLength = min(max(8, strokeWidthDevice * 4), length * 0.5)
        let headHalf = headLength * 0.6
        let baseX = Double(b.x) - ux * headLength, baseY = Double(b.y) - uy * headLength
        let tip = b
        let left = CGPoint(x: baseX + px * headHalf, y: baseY + py * headHalf)
        let right = CGPoint(x: baseX - px * headHalf, y: baseY - py * headHalf)
        let style = SceneStyle(fill: SceneFill(color: color, evenOdd: false), stroke: nil)
        return closedElement(points: [tip, left, right], style: style, id: id)
    }
}

private extension SceneColor {
    static let black = SceneColor(red: 0, green: 0, blue: 0)
}
