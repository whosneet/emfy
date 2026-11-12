import CoreGraphics
import Foundation

/// Pure align / distribute maths for the Arrange menu, the canvas context menus and the
/// inspector's Arrange section (E3e design call 1). It works entirely on device-space
/// bounding boxes (`Element.selectionBoundsDevice`) and returns a per-element device-space
/// translation, so the canvas can emit ONE `.translate` per element inside a single
/// grouped undo. No view, scene or platform dependency, so it unit-tests on rects alone.
///
/// Orientation note: `EditorCanvasMapping` is built so device `minY` is visually the TOP
/// on BOTH platforms (the Mac mapping folds in a y-flip, the iOS one maps straight
/// through). So "top" here is the minimum device y and "bottom" the maximum — no
/// per-platform flip is needed.
enum EditorArrange {

    /// The six alignment edges (design call 1).
    enum Alignment: CaseIterable, Hashable {
        case left, centreHorizontal, right, top, centreVertical, bottom
    }

    /// The two distribution axes (design call 1).
    enum Distribution: CaseIterable, Hashable { case horizontal, vertical }

    /// One element's id and its device-space bounding box.
    struct Box: Equatable {
        var id: Int
        var rect: CGRect
        init(id: Int, rect: CGRect) { self.id = id; self.rect = rect }
    }

    /// A per-element device translation (0,0 means "already aligned").
    struct Delta: Equatable {
        var id: Int
        var dx: Double
        var dy: Double
    }

    /// The union of the device boxes (the reference for a 2+-element align), or `.null`
    /// when none are usable.
    static func union(of boxes: [Box]) -> CGRect {
        var box = CGRect.null
        for item in boxes {
            let r = item.rect.standardized
            guard r.width.isFinite, r.height.isFinite, !r.isNull else { continue }
            box = box.isNull ? r : box.union(r)
        }
        return box
    }

    /// Per-element device translations that align the boxes to `reference` along
    /// `alignment`. An already-aligned element yields a zero delta (included but
    /// harmless). Degenerate boxes (null/non-finite) are skipped.
    static func alignDeltas(_ boxes: [Box], to reference: CGRect, _ alignment: Alignment) -> [Delta] {
        guard !reference.isNull else { return [] }
        let ref = reference.standardized
        return boxes.compactMap { box in
            let r = box.rect.standardized
            guard r.width.isFinite, r.height.isFinite, !r.isNull else { return nil }
            switch alignment {
            case .left:             return Delta(id: box.id, dx: Double(ref.minX - r.minX), dy: 0)
            case .centreHorizontal: return Delta(id: box.id, dx: Double(ref.midX - r.midX), dy: 0)
            case .right:            return Delta(id: box.id, dx: Double(ref.maxX - r.maxX), dy: 0)
            case .top:              return Delta(id: box.id, dx: 0, dy: Double(ref.minY - r.minY))
            case .centreVertical:   return Delta(id: box.id, dx: 0, dy: Double(ref.midY - r.midY))
            case .bottom:           return Delta(id: box.id, dx: 0, dy: Double(ref.maxY - r.maxY))
            }
        }
    }

    /// Per-element device translations that distribute 3+ boxes so the GAPS between
    /// consecutive bounds are equal along `axis` (design call 1). The two extreme boxes
    /// stay put. Fewer than 3 usable boxes → no change.
    static func distributeDeltas(_ boxes: [Box], _ axis: Distribution) -> [Delta] {
        let valid = boxes.filter {
            let r = $0.rect.standardized
            return r.width.isFinite && r.height.isFinite && !r.isNull
        }
        guard valid.count >= 3 else { return [] }

        switch axis {
        case .horizontal:
            let sorted = valid.sorted { $0.rect.standardized.midX < $1.rect.standardized.midX }
            let spanMin = Double(sorted.first!.rect.standardized.minX)
            let spanMax = Double(sorted.last!.rect.standardized.maxX)
            let sumW = sorted.reduce(0.0) { $0 + Double($1.rect.standardized.width) }
            let gap = (spanMax - spanMin - sumW) / Double(sorted.count - 1)
            var cursor = spanMin
            return sorted.map { box in
                let r = box.rect.standardized
                defer { cursor += Double(r.width) + gap }
                return Delta(id: box.id, dx: cursor - Double(r.minX), dy: 0)
            }
        case .vertical:
            let sorted = valid.sorted { $0.rect.standardized.midY < $1.rect.standardized.midY }
            let spanMin = Double(sorted.first!.rect.standardized.minY)
            let spanMax = Double(sorted.last!.rect.standardized.maxY)
            let sumH = sorted.reduce(0.0) { $0 + Double($1.rect.standardized.height) }
            let gap = (spanMax - spanMin - sumH) / Double(sorted.count - 1)
            var cursor = spanMin
            return sorted.map { box in
                let r = box.rect.standardized
                defer { cursor += Double(r.height) + gap }
                return Delta(id: box.id, dx: 0, dy: cursor - Double(r.minY))
            }
        }
    }
}
