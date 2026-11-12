import CoreGraphics
import EMFParse
import EMFRender
import EMFWrite
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

        // Emfy layer markers (private EMR_COMMENT, EMF GDI only). A well-formed
        // begin/end sequence rebuilds the saved layers; its comment records are
        // consumed into the layer structure (classified as state, not passthrough
        // elements). A malformed/foreign set is ignored — the markers stay ordinary
        // comments and the scene imports as one layer, exactly as before (design §1).
        let markers = format == .emf ? scanLayerMarkers(opened.data) : []
        let specs = markers.isEmpty ? nil : layerSpecs(from: markers)
        let excluded = specs != nil ? Set(markers.map(\.index)) : []

        let built = buildElements(from: observation, excludedCommentIndices: excluded)

        let layers: [Layer]
        let storedMarkerIndices: Set<Int>
        if let specs {
            layers = assignLayers(specs: specs, elements: built.elements)
            storedMarkerIndices = excluded
        } else {
            layers = [Layer(id: 0, name: Scene.defaultLayerName, elements: built.elements)]
            storedMarkerIndices = []
        }
        return Scene(
            pageBoundsDevice: prepared.deviceBounds,
            layers: layers,
            partition: built.partition,
            source: source,
            layerMarkerIndices: storedMarkerIndices
        )
    }

    // MARK: - Layer markers (E3d)

    /// Every Emfy layer-marker EMR_COMMENT in `data`, as (record index, marker) in
    /// file order. The record index is into the EMF record stream, which for a GDI
    /// EMF is 1:1 with the observation's unit indices (so it matches element
    /// provenance). Fully bounds-checked (§8): a record whose bytes fall outside the
    /// buffer is skipped, not trapped.
    private static func scanLayerMarkers(_ data: Data) -> [(index: Int, marker: EMFLayerMarker.Marker)] {
        guard let file = try? EMFFile.parse(data) else { return [] }
        let bytes = [UInt8](data)
        var out: [(index: Int, marker: EMFLayerMarker.Marker)] = []
        for (i, record) in file.records.enumerated() where record.type == 70 {
            let start = record.offset
            let size = Int(record.size)
            guard start >= 0, size >= 12, size <= bytes.count, start <= bytes.count - size else { continue }
            if let marker = EMFLayerMarker.decode(recordBytes: Array(bytes[start ..< start + size])) {
                out.append((i, marker))
            }
        }
        return out
    }

    /// One layer recovered from a begin/end marker pair: its attributes and the
    /// record-index range (exclusive) its elements fall within.
    private struct LayerSpec {
        var name: String
        var hidden: Bool
        var locked: Bool
        var lo: Int   // begin marker record index
        var hi: Int   // end marker record index
    }

    /// Validates the markers form a flat, strictly alternating begin/end sequence
    /// within the layer cap, and returns one spec per layer — else nil (the import
    /// falls back to one layer, design §1). §8: a lone end, two begins in a row, or
    /// more than `maxLayers` layers are all rejected cleanly.
    private static func layerSpecs(from markers: [(index: Int, marker: EMFLayerMarker.Marker)]) -> [LayerSpec]? {
        var specs: [LayerSpec] = []
        var i = 0
        while i < markers.count {
            guard markers[i].marker.kind == .begin else { return nil }
            guard i + 1 < markers.count, markers[i + 1].marker.kind == .end else { return nil }
            let begin = markers[i].marker
            specs.append(LayerSpec(name: begin.name, hidden: begin.hidden, locked: begin.locked,
                                   lo: markers[i].index, hi: markers[i + 1].index))
            i += 2
        }
        guard !specs.isEmpty, specs.count <= EMFLayerMarker.maxLayers else { return nil }
        return specs
    }

    /// Distributes `elements` (in z-order) into the layers `specs` describe, by the
    /// record-index range each element's draw record falls within. Any element
    /// outside every range (none for a clean Emfy file) goes to a trailing
    /// default-named layer so nothing is ever dropped.
    private static func assignLayers(specs: [LayerSpec], elements: [Element]) -> [Layer] {
        var layers = specs.enumerated().map { index, spec in
            Layer(id: index, name: spec.name, elements: [], hidden: spec.hidden, locked: spec.locked)
        }
        var fallback: [Element] = []
        for element in elements {
            let key = element.provenance.sourceRecordIndices.max() ?? -1
            if let li = specs.firstIndex(where: { key > $0.lo && key < $0.hi }) {
                layers[li].elements.append(element)
            } else {
                fallback.append(element)
            }
        }
        if !fallback.isEmpty {
            layers.append(Layer(id: layers.count, name: Scene.defaultLayerName, elements: fallback))
        }
        return layers
    }

    // MARK: - Element construction and partition

    private struct Built {
        var elements: [Element]
        var partition: ScenePartition
    }

    private static func buildElements(from observation: PlaybackObservation, excludedCommentIndices: Set<Int> = []) -> Built {
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
            return buildEMFPlusElements(from: observation)
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
                if excludedCommentIndices.contains(i) {
                    // An Emfy layer marker: consumed into the layer structure, never
                    // an element, so it is not re-emitted as passthrough content.
                    state.insert(i)
                } else {
                    passthrough.insert(i)
                    pending.append((passthroughElement(indices: [i], reason: .comment, geometry: ScenePath(), transform: .identity), i))
                }
            case .unknown:
                passthrough.insert(i)
                pending.append((passthroughElement(indices: [i], reason: .unknownRecord(type: type), geometry: ScenePath(), transform: .identity), i))
            case .drawing:
                // A drawing record that produced no op (e.g. a dual file's GDI
                // fallback that did not execute, or a no-path path closer): keep
                // it verbatim so nothing is dropped.
                passthrough.insert(i)
                pending.append((passthroughElement(indices: [i], reason: .rasterOp, geometry: ScenePath(), transform: .identity), i))
            case .fallback:
                // Only EMF+ files produce the fallback role (handled separately);
                // never reached on the GDI/WMF path, but kept exhaustive-safe.
                state.insert(i)
            }
        }

        return finish(pending: pending, structural: structural, state: state, drawing: drawing, passthrough: passthrough, unitCount: unitCount)
    }

    // MARK: - EMF+ element construction (slice E1a2)

    /// Lifts an EMF+ file: each EMF+ drawing record (and each GDI draw inside a
    /// GetDC window) becomes one element, in playback (z) order. The GDI fallback
    /// of a dual file goes to the `fallback` bucket — kept out of the element list
    /// (the E1b exporter regenerates it). EMF+ object/control/clip comments are
    /// state. Every source record lands in exactly one partition bucket.
    private static func buildEMFPlusElements(from observation: PlaybackObservation) -> Built {
        let unitCount = observation.unitCount
        var structural = Set<Int>()
        var state = Set<Int>()
        var drawing = Set<Int>()
        var passthrough = Set<Int>()
        var fallback = Set<Int>()

        var pending: [(element: Element, drawKey: Int)] = []
        // Comment indices owning an editable element vs a passthrough element.
        var drawComments = Set<Int>()
        var passthroughComments = Set<Int>()

        for (order, entry) in observation.plusEntries.enumerated() {
            switch entry {
            case .gdi(let op):
                // A GDI draw inside a GetDC window → an ordinary GDI element.
                if op.kind == .passthrough { passthrough.formUnion(op.recordIndices) }
                else { drawing.formUnion(op.recordIndices) }
                pending.append((makeElement(op), order))
            case .plus(let op):
                let element = makePlusElement(op)
                if element.kind == .passthrough { passthroughComments.insert(op.commentRecordIndex) }
                else { drawComments.insert(op.commentRecordIndex) }
                pending.append((element, order))
            }
        }

        for i in 0 ..< unitCount where !drawing.contains(i) && !passthrough.contains(i) {
            switch observation.unitRoles[i] {
            case .structural:
                structural.insert(i)
            case .fallback:
                fallback.insert(i)
            case .comment:
                // EMF+ data comment: drawing/passthrough if it SOURCED an element,
                // else state (object definitions, control, clip, transforms).
                if drawComments.contains(i) { drawing.insert(i) }
                else if passthroughComments.contains(i) { passthrough.insert(i) }
                else { state.insert(i) }
            case .state, .drawing, .unknown:
                // A GDI record played in a GetDC window that produced no op — GetDC
                // GDI state — or any other non-fallback GDI role: state.
                state.insert(i)
            }
        }

        return finish(pending: pending, structural: structural, state: state, drawing: drawing, passthrough: passthrough, fallback: fallback, unitCount: unitCount)
    }

    private static func makePlusElement(_ op: PlusDrawOp) -> Element {
        let geometry = ScenePath(op.deviceGeometry)
        let clip = op.clipDeviceGeometry.map(ScenePath.init)
        let provenance = Provenance(sourceRecordIndices: [op.commentRecordIndex])

        switch op.kind {
        case .text:
            // Unify the reference-point convention with GDI text (documented on
            // `SceneText.referenceLogical`): store the reference in the run's
            // PRE-transform (world) space, so the drawn device point is
            // `referenceLogical.applying(transform)` and a device-space edit that
            // post-composes into `transform` moves/scales/rotates it. The lift
            // gave the DEVICE layout-rect origin; invert world→device to recover
            // the world point (keep device when the transform is non-invertible).
            var text = op.text.map(SceneText.init)
            if var resolved = text, let inverse = invertible(op.worldToDevice) {
                resolved.referenceLogical = resolved.referenceLogical.applying(inverse)
                text = resolved
            }
            return Element(
                id: 0, kind: .text, geometryDevice: geometry, transform: op.worldToDevice,
                style: plusStyle(op), text: text,
                clipDevice: clip, provenance: provenance
            )
        case .image:
            return Element(
                id: 0, kind: .image, geometryDevice: geometry, transform: op.worldToDevice,
                image: op.image.map(SceneImage.init),
                clipDevice: clip, provenance: provenance
            )
        case .passthrough:
            return Element(
                id: 0, kind: .passthrough, geometryDevice: geometry, transform: op.worldToDevice,
                clipDevice: clip, provenance: provenance, locked: true,
                passthroughReason: plusPassthroughReason(op)
            )
        default:
            return Element(
                id: 0, kind: plusElementKind(op.kind), geometryDevice: geometry, transform: op.worldToDevice,
                style: plusStyle(op), clipDevice: clip, provenance: provenance
            )
        }
    }

    /// The inverse of `t` when it is invertible (non-degenerate determinant),
    /// else nil — `CGAffineTransform.inverted()` silently returns the original for
    /// a singular matrix, which would corrupt the recovered world point.
    private static func invertible(_ t: CGAffineTransform) -> CGAffineTransform? {
        let det = t.a * t.d - t.b * t.c
        guard det.isFinite, abs(det) > 1e-12 else { return nil }
        return t.inverted()
    }

    private static func plusStyle(_ op: PlusDrawOp) -> SceneStyle {
        SceneStyle(
            fill: op.fill.map { SceneFill($0, evenOdd: op.fillEvenOdd) },
            stroke: op.stroke.map(SceneStroke.init),
            opacity: 1
        )
    }

    private static func plusElementKind(_ kind: PlusDrawOp.Kind) -> ElementKind {
        switch kind {
        case .rectangle: return .rect
        case .ellipse: return .ellipse
        case .polygon: return .polygon
        case .polyline: return .polyline
        case .line: return .line
        case .pie, .arc: return .arc
        case .path: return .path
        case .bezier, .curve: return .bezier
        case .text: return .text
        case .image: return .image
        case .passthrough: return .passthrough
        }
    }

    private static func plusPassthroughReason(_ op: PlusDrawOp) -> PassthroughReason {
        switch op.passthroughReason {
        case .clear, .driverString, .unsupportedRecord, .none:
            return .emfPlusUnsupportedRecord(type: op.recordType)
        case .unsupportedBrush:
            return .emfPlusUnsupportedBrush
        case .undecodable:
            return .emfPlusUndecodable(type: op.recordType)
        }
    }

    /// Sorts elements into playback (z) order and assigns monotonic ids.
    private static func finish(
        pending: [(element: Element, drawKey: Int)],
        structural: Set<Int>, state: Set<Int>, drawing: Set<Int>, passthrough: Set<Int>,
        fallback: Set<Int> = [],
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
            partition: ScenePartition(structural: structural, state: state, drawing: drawing, passthrough: passthrough, fallback: fallback, unitCount: unitCount)
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
