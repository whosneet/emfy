import CoreGraphics
import EMFParse
import EMFRender
import Foundation

/// Lifts a metafile (EMF, EMZ, WMF, WMZ) into an editable `Scene`.
///
/// It never reinterprets records: it drives EMFRender's ONE DC interpreter via
/// `MetafileRenderer.observe`, turning each resolved drawing operation into an
/// element and partitioning every source record into exactly one bucket
/// (structural, state, a drawing element, or a passthrough element). Records it
/// cannot lift faithfully — EMF+ drawing, comments, SETPIXEL/PATBLT, glyph-index
/// text, unimplemented/malformed records — become passthrough elements, so
/// editing never silently drops content (docs/v3-plan §11).
public enum SceneImporter {

    public enum ImportError: Error, Sendable, Equatable {
        /// Not a parseable metafile (unknown format, or a header-less file).
        case unreadable
        /// The input exceeded the reader's size ceiling (§8).
        case tooLarge
    }

    /// Per-element bound: a single lifted shape with more points than this is
    /// kept but its geometry is capped by the parser's own point bounds; this is
    /// a belt-and-braces cap on the element count a hostile file can create.
    public static let maxElements = RenderObserver.maxDraws

    public static func `import`(data: Data) throws -> Scene {
        let opened: OpenedMetafile
        do {
            opened = try OpenedMetafile.open(data)
        } catch {
            // `open` is a typed throw of `MetafileOpenError`.
            if case .inputTooLarge = error { throw ImportError.tooLarge }
            throw ImportError.unreadable
        }

        guard let prepared = MetafileRenderer.prepare(opened) else {
            throw ImportError.unreadable
        }
        let observation = MetafileRenderer.observe(prepared)

        let format: SceneSource.Format
        switch opened.format {
        case .emf: format = .emf
        case .wmf: format = .wmf
        case .placeableWMF: format = .placeableWMF
        case .gzip, .unknown: throw ImportError.unreadable
        }
        let source = SceneSource(
            data: opened.data,
            format: format,
            wasCompressed: opened.wasDecompressed,
            renderPath: observation.renderPath,
            unitCount: observation.unitCount
        )

        let built = buildElements(from: observation)
        let layer = Layer(id: 0, name: "Imported", elements: built.elements)
        return Scene(
            pageBoundsDevice: prepared.deviceBounds,
            layers: [layer],
            partition: built.partition,
            source: source
        )
    }

    // MARK: - Element construction and partition

    private struct Built {
        var elements: [Element]
        var partition: ScenePartition
    }

    private static func buildElements(from observation: PlaybackObservation) -> Built {
        let unitCount = observation.unitCount
        var structural = Set<Int>()
        var state = Set<Int>()
        var drawing = Set<Int>()
        var passthrough = Set<Int>()

        // (element, draw-moment key) — the draw key is the element's LAST source
        // record (a shape's own record; a path bracket's closer), i.e. its z-order
        // position in playback.
        var pending: [(element: Element, drawKey: Int)] = []

        if observation.renderPath == .emfPlus {
            // EMF+ drove output: v1 keeps the whole GDI shell as one passthrough
            // blob (replayed verbatim). Only the header/eof are structural.
            var indices: [Int] = []
            for i in 0 ..< unitCount {
                if observation.unitRoles[i] == .structural {
                    structural.insert(i)
                } else {
                    indices.append(i)
                    passthrough.insert(i)
                }
            }
            if !indices.isEmpty {
                pending.append((
                    passthroughElement(indices: indices.sorted(), reason: .emfPlus, geometry: ScenePath(), transform: .identity),
                    indices.min() ?? 0
                ))
            }
            return finish(pending: pending, structural: structural, state: state, drawing: drawing, passthrough: passthrough, unitCount: unitCount)
        }

        // GDI / WMF: each op becomes an element; the rest are classified by role.
        for op in observation.ops {
            let element = makeElement(op)
            if op.kind == .passthrough {
                passthrough.formUnion(op.recordIndices)
            } else {
                drawing.formUnion(op.recordIndices)
            }
            pending.append((element, op.recordIndices.max() ?? 0))
        }

        for i in 0 ..< unitCount where !drawing.contains(i) && !passthrough.contains(i) {
            if observation.pathConstructionIndices.contains(i) {
                state.insert(i)
                continue
            }
            let type = i < observation.unitTypes.count ? observation.unitTypes[i] : 0
            switch observation.unitRoles[i] {
            case .structural:
                structural.insert(i)
            case .state:
                state.insert(i)
            case .comment:
                passthrough.insert(i)
                pending.append((passthroughElement(indices: [i], reason: .comment, geometry: ScenePath(), transform: .identity), i))
            case .unknown:
                passthrough.insert(i)
                pending.append((passthroughElement(indices: [i], reason: .unknownRecord(type: type), geometry: ScenePath(), transform: .identity), i))
            case .drawing:
                // A drawing record that produced no op (e.g. a dual file's GDI
                // fallback that did not execute, or a no-path path closer): keep
                // it verbatim so nothing is dropped.
                passthrough.insert(i)
                pending.append((passthroughElement(indices: [i], reason: .rasterOp, geometry: ScenePath(), transform: .identity), i))
            }
        }

        return finish(pending: pending, structural: structural, state: state, drawing: drawing, passthrough: passthrough, unitCount: unitCount)
    }

    /// Sorts elements into playback (z) order and assigns monotonic ids.
    private static func finish(
        pending: [(element: Element, drawKey: Int)],
        structural: Set<Int>, state: Set<Int>, drawing: Set<Int>, passthrough: Set<Int>,
        unitCount: Int
    ) -> Built {
        let ordered = pending
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.drawKey != rhs.element.drawKey
                    ? lhs.element.drawKey < rhs.element.drawKey
                    : lhs.offset < rhs.offset       // stable
            }
            .map(\.element.element)
        var elements: [Element] = []
        elements.reserveCapacity(ordered.count)
        for (id, element) in ordered.enumerated() {
            var copy = element
            copy.id = id
            elements.append(copy)
        }
        return Built(
            elements: elements,
            partition: ScenePartition(structural: structural, state: state, drawing: drawing, passthrough: passthrough, unitCount: unitCount)
        )
    }

    private static func makeElement(_ op: ResolvedDrawOp) -> Element {
        let geometry = ScenePath(op.deviceGeometry)
        let clip = op.clipDeviceGeometry.map(ScenePath.init)
        let provenance = Provenance(sourceRecordIndices: op.recordIndices)

        switch op.kind {
        case .text:
            return Element(
                id: 0, kind: .text, geometryDevice: geometry, transform: op.deviceTransform,
                style: style(for: op), text: op.text.map(SceneText.init),
                clipDevice: clip, provenance: provenance
            )
        case .image:
            return Element(
                id: 0, kind: .image, geometryDevice: geometry, transform: op.deviceTransform,
                style: style(for: op),
                image: op.image.map { SceneImage($0, deviceTransform: op.deviceTransform) },
                clipDevice: clip, provenance: provenance
            )
        case .passthrough:
            return Element(
                id: 0, kind: .passthrough, geometryDevice: geometry, transform: op.deviceTransform,
                clipDevice: clip, provenance: provenance, locked: true, passthroughReason: .rasterOp
            )
        default:
            return Element(
                id: 0, kind: elementKind(for: op.kind), geometryDevice: geometry, transform: op.deviceTransform,
                style: style(for: op), clipDevice: clip, provenance: provenance
            )
        }
    }

    private static func style(for op: ResolvedDrawOp) -> SceneStyle {
        SceneStyle(
            fill: op.fillColor.map { SceneFill(color: SceneColor($0), evenOdd: op.fillIsEvenOdd) },
            stroke: op.stroke.map(SceneStroke.init),
            opacity: 1
        )
    }

    private static func elementKind(for kind: ResolvedDrawOp.Kind) -> ElementKind {
        switch kind {
        case .rectangle: return .rect
        case .ellipse: return .ellipse
        case .roundRect: return .roundRect
        case .polygon, .polyPolygon: return .polygon
        case .polyline, .polyPolyline: return .polyline
        case .line: return .line
        case .arc, .pie, .chord: return .arc
        case .bezier: return .bezier
        case .path: return .path
        case .text: return .text
        case .image: return .image
        case .passthrough: return .passthrough
        }
    }

    private static func passthroughElement(indices: [Int], reason: PassthroughReason, geometry: ScenePath, transform: CGAffineTransform) -> Element {
        Element(
            id: 0, kind: .passthrough, geometryDevice: geometry, transform: transform,
            provenance: Provenance(sourceRecordIndices: indices),
            locked: true, passthroughReason: reason
        )
    }
}
