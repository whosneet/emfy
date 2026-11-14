import CoreGraphics
import EMFParse
import EMFRender
import Foundation

/// Why a record became a passthrough element rather than an editable one.
public enum PassthroughReason: Sendable, Equatable {
    /// EMF+ drawing content v1 could not lift into an editable element (kept as a
    /// whole-file blob before slice E1a2; retained for compatibility).
    case emfPlus
    /// An EMR_COMMENT (private or EMF+ wrapper) record.
    case comment
    /// A drawn record v1 does not model editably (SETPIXEL, PATBLT, glyph-index text).
    case rasterOp
    /// An unimplemented record type (logged-and-skipped by the renderer).
    case unknownRecord(type: UInt32)
    /// A malformed record the parser flagged.
    case malformed(type: UInt32)
    /// An EMF+ fill brush the scene cannot represent faithfully (hatch, path
    /// gradient, or texture) — replayed, flagged for E1b re-encode.
    case emfPlusUnsupportedBrush
    /// An EMF+ record the scene cannot lift editably (EmfPlusClear, a glyph-index
    /// DrawDriverString, an image effect) — replayed unchanged.
    case emfPlusUnsupportedRecord(type: UInt16)
    /// An EMF+ drawing record whose body was undecodable or whose referenced
    /// object was missing — replayed (draws its best partial output).
    case emfPlusUndecodable(type: UInt16)
}

/// The kind of a scene element.
public enum ElementKind: Sendable, Equatable, Hashable {
    case path, rect, ellipse, roundRect, polygon, polyline, line, arc, bezier
    case text, image, group
    /// Content kept verbatim: it renders and exports unchanged but is not
    /// editable in v1. Carries a `PassthroughReason`.
    case passthrough
}

/// Where an element came from in the source, and whether it has been edited.
/// The exporter (E1b) re-emits an UNEDITED element's original records verbatim
/// and synthesises only edited/new ones, so provenance must list every source
/// record the element was drawn from.
public struct Provenance: Sendable, Equatable {
    /// Source record indices (ascending). EMF: into `EMFFile.records`. WMF: into
    /// the translated program's payloads.
    public var sourceRecordIndices: [Int]
    public var edited: Bool

    public init(sourceRecordIndices: [Int], edited: Bool = false) {
        self.sourceRecordIndices = sourceRecordIndices
        self.edited = edited
    }
}

/// One editable (or passthrough) element in a scene. Value type, `Equatable`,
/// `Sendable`: the scene is a plain value so undo can be command diffs (E1c).
///
/// Geometry and clip are in the scene's DEVICE space; `transform` is the
/// logical→device transform in effect when the element was drawn (kept for
/// GDI re-emit and for mapping a resolved width back to logical units).
public struct Element: Sendable, Equatable, Identifiable {
    public var id: Int
    public var kind: ElementKind
    public var geometryDevice: ScenePath
    public var transform: CGAffineTransform
    public var style: SceneStyle
    public var text: SceneText?
    public var image: SceneImage?
    public var clipDevice: ScenePath?
    public var provenance: Provenance
    public var locked: Bool
    public var hidden: Bool
    public var passthroughReason: PassthroughReason?
    /// Cached device-space bounds (geometry box, intersected with the clip box).
    public var boundsDevice: CGRect

    public init(
        id: Int,
        kind: ElementKind,
        geometryDevice: ScenePath,
        transform: CGAffineTransform,
        style: SceneStyle = SceneStyle(),
        text: SceneText? = nil,
        image: SceneImage? = nil,
        clipDevice: ScenePath? = nil,
        provenance: Provenance,
        locked: Bool = false,
        hidden: Bool = false,
        passthroughReason: PassthroughReason? = nil
    ) {
        self.id = id
        self.kind = kind
        self.geometryDevice = geometryDevice
        self.transform = transform
        self.style = style
        self.text = text
        self.image = image
        self.clipDevice = clipDevice
        self.provenance = provenance
        self.locked = locked
        self.hidden = hidden
        self.passthroughReason = passthroughReason
        var box = geometryDevice.boundingBox
        if let clip = clipDevice, !clip.isEmpty {
            box = box.isNull ? clip.boundingBox : box.intersection(clip.boundingBox)
        }
        self.boundsDevice = box
    }
}

/// An ordered layer of elements (imported content goes into one layer).
public struct Layer: Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var elements: [Element]
    public var hidden: Bool
    public var locked: Bool

    public init(id: Int, name: String, elements: [Element], hidden: Bool = false, locked: Bool = false) {
        self.id = id
        self.name = name
        self.elements = elements
        self.hidden = hidden
        self.locked = locked
    }
}

/// The source a scene was imported from, retained for the lossless overlay: the
/// exporter re-parses it to re-emit unedited content verbatim, and the scene
/// renderer re-observes it to replay passthrough content (E1b).
public struct SceneSource: Sendable, Equatable {
    public enum Format: Sendable, Equatable {
        case emf, wmf, placeableWMF
    }
    /// The DECOMPRESSED metafile bytes (EMZ/WMZ are already inflated).
    public var data: Data
    public var format: Format
    /// True when the input was gzip-compressed (EMZ/WMZ) — E1b re-compresses.
    public var wasCompressed: Bool
    /// Which engine drew the content lifted into this scene.
    public var renderPath: RenderPathTaken
    /// Number of source playback units (the record partition's universe).
    public var unitCount: Int

    public init(data: Data, format: Format, wasCompressed: Bool, renderPath: RenderPathTaken, unitCount: Int) {
        self.data = data
        self.format = format
        self.wasCompressed = wasCompressed
        self.renderPath = renderPath
        self.unitCount = unitCount
    }
}

/// The record partition: every source playback unit belongs to exactly one
/// bucket. Exposed so the import gate can assert completeness and disjointness.
public struct ScenePartition: Sendable, Equatable {
    /// EMR_HEADER / EMR_EOF.
    public var structural: Set<Int>
    /// DC state, objects, transforms, clipping, path-bracket construction.
    public var state: Set<Int>
    /// Records owned by editable drawing elements.
    public var drawing: Set<Int>
    /// Records owned by passthrough elements.
    public var passthrough: Set<Int>
    /// GDI records in an EMF+ dual file that the EMF+ engine did NOT play (the GDI
    /// fallback). They become no element; the E1b exporter regenerates them from
    /// the edited scene. Always empty for a pure-GDI or WMF scene.
    public var fallback: Set<Int>
    public var unitCount: Int

    public init(structural: Set<Int>, state: Set<Int>, drawing: Set<Int>, passthrough: Set<Int>, fallback: Set<Int> = [], unitCount: Int) {
        self.structural = structural
        self.state = state
        self.drawing = drawing
        self.passthrough = passthrough
        self.fallback = fallback
        self.unitCount = unitCount
    }

    /// Every unit is in exactly one bucket.
    public var isComplete: Bool {
        let total = structural.count + state.count + drawing.count + passthrough.count + fallback.count
        guard total == unitCount else { return false }
        let union = structural.union(state).union(drawing).union(passthrough).union(fallback)
        return union.count == unitCount && union == Set(0 ..< unitCount)
    }
}

/// An imported, editable metafile: a device-space page, one or more z-ordered
/// layers of elements, the record partition, and the retained source.
public struct Scene: Sendable, Equatable {
    /// The device-space page rectangle in the source's own coordinates (EMF
    /// header bounds `(left, top, w, h)`, y-down; `(0,0,w,h)` for WMF). Element
    /// geometry lives in this space; the renderer maps it to a target with the
    /// same device→target fit EMFRender uses.
    public var pageBoundsDevice: CGRect
    /// Layers, back-to-front; element z-order is each layer's array order.
    public var layers: [Layer]
    public var partition: ScenePartition
    public var source: SceneSource
    /// Source record indices (into the EMF record stream) that held Emfy layer
    /// markers when this scene was imported (E3d). The exporter strips these on
    /// rewrite and injects fresh markers, so a re-save never duplicates them.
    /// Empty for a file without markers (every existing scene).
    public var layerMarkerIndices: Set<Int>

    public init(pageBoundsDevice: CGRect, layers: [Layer], partition: ScenePartition, source: SceneSource, layerMarkerIndices: Set<Int> = []) {
        self.pageBoundsDevice = pageBoundsDevice
        self.layers = layers
        self.partition = partition
        self.source = source
        self.layerMarkerIndices = layerMarkerIndices
    }

    /// Page size in DEVICE pixels (the source's natural size).
    public var pageSizeDevice: CGSize { pageBoundsDevice.size }

    /// All elements across layers, in z-order (back to front).
    public var elements: [Element] {
        layers.flatMap(\.elements)
    }

    /// Calls `body` for every element in z-order without allocating the combined
    /// `elements` array — for the per-frame hot paths (overlay draw, snap candidates)
    /// that only iterate (P4).
    public func forEachElement(_ body: (Element) -> Void) {
        for layer in layers {
            for element in layer.elements { body(element) }
        }
    }

    /// Editable (non-passthrough) elements.
    public var editableElements: [Element] {
        elements.filter { $0.kind != .passthrough }
    }

    /// Element counts grouped by kind, for the import gate report.
    public var kindCounts: [ElementKind: Int] {
        var counts: [ElementKind: Int] = [:]
        for element in elements { counts[element.kind, default: 0] += 1 }
        return counts
    }

    // MARK: - Layers (E3d)

    /// The name a single imported/blank layer carries when a file has no markers.
    public static let defaultLayerName = "Layer 1"

    /// The default active layer for new elements: the TOP layer (last in the
    /// back-to-front array, shown first in the panel). With one layer that is the
    /// only layer, so E3a–E3c's single-layer insert stays equivalent (design §3).
    public var defaultActiveLayerID: Int? { layers.last?.id }

    /// The order index of the layer with `id`, or nil.
    public func layerOrder(ofLayer id: Int) -> Int? {
        layers.firstIndex { $0.id == id }
    }

    /// The order index of the layer that contains element `id`, or nil.
    public func layerOrder(ofElement id: Int) -> Int? {
        layers.firstIndex { $0.elements.contains { $0.id == id } }
    }

    /// The smallest unused layer id, so a new layer never collides.
    public var nextLayerID: Int { (layers.map(\.id).max() ?? -1) + 1 }

    /// True when the layer structure carries information a save must persist as
    /// markers: more than one layer, any hidden/locked layer, or a single layer
    /// renamed from the default. A plain single default layer (every existing
    /// scene) is trivial and saves byte-for-byte as before.
    public var hasNonTrivialLayers: Bool {
        if layers.count != 1 { return true }
        let only = layers[0]
        return only.hidden || only.locked || only.name != Scene.defaultLayerName || !layerMarkerIndices.isEmpty
    }

    // MARK: - Physical resolution (E3a)

    /// Device units per typographic point (1/72 inch) for this page, so a new shape or
    /// stroke sized in points comes out at the right PHYSICAL size on ANY document —
    /// not a fixed screen DPI. Derived from the source's own device↔physical mapping,
    /// the same basis `pageBoundsDevice` lives in: for EMF, the header's rclBounds
    /// (device units) against rclFrame (0.01 mm) ([MS-EMF] §2.3.4.2 / §2.2.9); for a
    /// placeable WMF, the metafile's logical-units-per-inch ([MS-WMF] §2.3.2.3). A plain
    /// WMF carries no physical reference, so it falls back to 96 DPI.
    public var deviceUnitsPerPoint: CGFloat { (deviceUnitsPerInch ?? 96) / 72 }

    /// Device units per inch for the source page, or nil when the source carries no
    /// physical reference.
    public var deviceUnitsPerInch: CGFloat? {
        switch source.format {
        case .emf: return Scene.emfDeviceUnitsPerInch(source.data)
        case .placeableWMF: return Scene.placeableWMFUnitsPerInch(source.data)
        case .wmf: return nil
        }
    }

    /// The accepted range for a header-derived resolution (§8: header fields are
    /// untrusted — a hostile or garbage header can yield 1e9 or 0.001 DPI, which would
    /// make a new shape absurdly huge or invisibly tiny). Outside this range the caller
    /// falls back to 96 DPI. 10…10 000 units/inch spans every real device (72, 96, 300,
    /// 600, 1200, 2540 DPI) with margin.
    static let resolutionRange: ClosedRange<CGFloat> = 10 ... 10_000

    /// A header-derived units-per-inch clamped to `resolutionRange`, else nil.
    private static func acceptResolution(_ perInch: Double) -> CGFloat? {
        guard perInch.isFinite else { return nil }
        let value = CGFloat(perInch)
        return resolutionRange.contains(value) ? value : nil
    }

    /// Reads rclBounds (device units) and rclFrame (0.01 mm) from an EMR_HEADER and
    /// returns the average of the X and Y device-units-per-inch, or nil when the header
    /// is too short, the frame is degenerate, or the result is outside the sane range
    /// (§8: a bounds-checked little-endian read, never a trap). [MS-EMF] §2.3.4.2:
    /// rclBounds at offset 8, rclFrame at offset 24.
    static func emfDeviceUnitsPerInch(_ data: Data) -> CGFloat? {
        guard data.count >= 40 else { return nil }
        func i32(_ offset: Int) -> Int32 {
            let b = data.startIndex + offset
            return Int32(bitPattern:
                UInt32(data[b]) | (UInt32(data[b + 1]) << 8) | (UInt32(data[b + 2]) << 16) | (UInt32(data[b + 3]) << 24))
        }
        // Inclusive-inclusive bounds → +1; frame is in 0.01 mm → /100 for mm.
        let deviceW = Double(Int64(i32(16)) - Int64(i32(8)) + 1)
        let deviceH = Double(Int64(i32(20)) - Int64(i32(12)) + 1)
        let frameWmm = Double(Int64(i32(32)) - Int64(i32(24))) / 100
        let frameHmm = Double(Int64(i32(36)) - Int64(i32(28))) / 100
        guard deviceW > 0, deviceH > 0, frameWmm > 0, frameHmm > 0 else { return nil }
        let perInchX = deviceW / frameWmm * 25.4
        let perInchY = deviceH / frameHmm * 25.4
        return acceptResolution((perInchX + perInchY) / 2)
    }

    /// Reads the Inch field of a placeable WMF header ([MS-WMF] §2.3.2.3: Key(4),
    /// HWmf(2), BoundingBox(8), Inch(2) at offset 14) — the logical units per inch —
    /// clamped to the sane range (so a hostile Inch of 1 or 65535 falls back to 96 DPI),
    /// else nil. Bounds-checked little-endian read.
    static func placeableWMFUnitsPerInch(_ data: Data) -> CGFloat? {
        guard data.count >= 16 else { return nil }
        let b = data.startIndex + 14
        let inch = UInt16(data[b]) | (UInt16(data[b + 1]) << 8)
        return acceptResolution(Double(inch))
    }
}
