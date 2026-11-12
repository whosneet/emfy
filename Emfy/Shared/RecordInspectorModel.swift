import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import Observation

// MARK: - Record inspector (F5b)
//
// The viewer's Records segment: the per-record list (from the F5a `Prepared`
// bridge), a type-name filter, the step-through replay index, and the DC state
// after the selected record. The pure logic — filtering, the drawing-record
// jump, the summary cache key, the EMF+ step-through gating and the DC-panel
// formatting — lives in `RecordInspectorLogic` / `RecordStateFormat` so it is
// tested without a view. The `@Observable` model only holds state and sequences
// those calls; the owning view drives the `MetafilePartialPlayer`.

/// Pure record-list logic: filtering and the previous/next drawing-record jump.
enum RecordInspectorLogic {

    /// The indices of `refs` whose type name contains `query` (case- and
    /// diacritic-insensitive). An empty or whitespace-only query matches every
    /// row, so the list is unfiltered. The match is on the type name only — the
    /// one-line summaries are built lazily and are not searched.
    static func filteredIndices(_ refs: [RecordRef], query: String) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Array(refs.indices) }
        return refs.indices.filter { index in
            refs[index].typeName.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// The next drawing-record index strictly after (`forward`) or before
    /// (`!forward`) `index`, or `nil` when there is none in that direction.
    /// `drawingIndices` is the set of record indices that draw (from the
    /// renderer's `PlaybackObservation`), sorted ascending by the caller.
    static func adjacentDrawingIndex(after index: Int, drawingIndices: [Int], forward: Bool) -> Int? {
        if forward {
            return drawingIndices.first { $0 > index }
        } else {
            return drawingIndices.last { $0 < index }
        }
    }

    /// The summary cache key for a file: its loaded content fingerprint. Summaries
    /// are pure over the record bytes, so they are cached per file content and
    /// survive filter/selection changes, and are invalidated only when the drawing
    /// itself changes.
    static func summaryCacheKey(contentID: Int) -> Int { contentID }

    /// The note shown when a file cannot be stepped (an EMF+ drawing file, or a
    /// WMF program with no EMF step-through), so the scrubber is disabled.
    static let emfPlusStepNote = "Step-through isn't available for EMF+ drawings; showing the full drawing."
}

// MARK: - DC-panel formatting

/// A labelled DC-panel value, with an optional colour swatch (sRGB 0…1) for the
/// colour rows.
struct RecordStateRow: Equatable {
    let label: String
    let value: String
    /// sRGB components for a colour swatch, or `nil` for a non-colour row.
    let swatch: RecordStateSwatch?

    init(_ label: String, _ value: String, swatch: RecordStateSwatch? = nil) {
        self.label = label
        self.value = value
        self.swatch = swatch
    }
}

/// A swatch colour, kept platform-free (sRGB 0…1) so the pure formatter has no
/// SwiftUI/AppKit dependency.
struct RecordStateSwatch: Equatable {
    let red, green, blue: Double
    init(_ color: ColorRef) {
        red = Double(color.red) / 255
        green = Double(color.green) / 255
        blue = Double(color.blue) / 255
    }
}

/// A titled group of DC-panel rows.
struct RecordStateGroup: Equatable, Identifiable {
    let title: String
    let rows: [RecordStateRow]
    var id: String { title }
}

/// Pure formatting of a `PlaybackState` into the DC panel's grouped rows.
enum RecordStateFormat {

    static func hex(_ color: ColorRef) -> String {
        String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
    }

    static func groups(for state: PlaybackState) -> [RecordStateGroup] {
        [
            RecordStateGroup(title: "Objects", rows: objectRows(state)),
            RecordStateGroup(title: "Colours", rows: colourRows(state)),
            RecordStateGroup(title: "Mapping", rows: mappingRows(state)),
            RecordStateGroup(title: "State", rows: stateRows(state)),
        ]
    }

    private static func objectRows(_ state: PlaybackState) -> [RecordStateRow] {
        var rows: [RecordStateRow] = []
        rows.append(RecordStateRow("Pen", penValue(state.pen), swatch: penSwatch(state.pen)))
        rows.append(RecordStateRow("Brush", brushValue(state.brush), swatch: brushSwatch(state.brush)))
        rows.append(RecordStateRow("Font", fontValue(state.font)))
        rows.append(RecordStateRow("Objects", String(state.objectCount)))
        return rows
    }

    private static func colourRows(_ state: PlaybackState) -> [RecordStateRow] {
        [
            RecordStateRow("Text", hex(state.textColor), swatch: RecordStateSwatch(state.textColor)),
            RecordStateRow("Background", hex(state.backgroundColor), swatch: RecordStateSwatch(state.backgroundColor)),
            RecordStateRow("Text align", textAlignName(state.textAlign)),
            RecordStateRow("Background mode", backgroundModeName(state.backgroundMode)),
        ]
    }

    private static func mappingRows(_ state: PlaybackState) -> [RecordStateRow] {
        [
            RecordStateRow("Map mode", mapModeName(state.mapMode)),
            RecordStateRow("Window", "\(point(state.windowOrigin)) ext \(size(state.windowExtent))"),
            RecordStateRow("Viewport", "\(point(state.viewportOrigin)) ext \(size(state.viewportExtent))"),
            RecordStateRow("World", matrix(state.worldTransform)),
        ]
    }

    private static func stateRows(_ state: PlaybackState) -> [RecordStateRow] {
        [
            RecordStateRow("Position", point(state.currentPosition)),
            RecordStateRow("Fill rule", polyFillName(state.polyFillMode)),
            RecordStateRow("Clip", clipValue(state.clip)),
            RecordStateRow("Saved DCs", String(state.saveDepth)),
        ]
    }

    // MARK: Objects

    private static func penValue(_ pen: PlaybackState.Pen) -> String {
        switch pen {
        case .none: return "None"
        case .stroke(let color, let cosmetic, let width, let dash):
            let widthText = cosmetic ? "cosmetic" : num(width)
            return "\(hex(color)) · \(widthText) · \(dash)"
        }
    }

    private static func penSwatch(_ pen: PlaybackState.Pen) -> RecordStateSwatch? {
        if case .stroke(let color, _, _, _) = pen { return RecordStateSwatch(color) }
        return nil
    }

    private static func brushValue(_ brush: PlaybackState.Brush) -> String {
        switch brush {
        case .none: return "None"
        case .solid(let color): return hex(color)
        }
    }

    private static func brushSwatch(_ brush: PlaybackState.Brush) -> RecordStateSwatch? {
        if case .solid(let color) = brush { return RecordStateSwatch(color) }
        return nil
    }

    private static func fontValue(_ font: PlaybackState.Font?) -> String {
        guard let font else { return "None" }
        var traits: [String] = []
        if font.bold { traits.append("Bold") }
        if font.italic { traits.append("Italic") }
        if font.underline { traits.append("Underline") }
        if font.strikeOut { traits.append("Strikethrough") }
        let traitText = traits.isEmpty ? "" : " · \(traits.joined(separator: " "))"
        return "\(font.family) · h=\(font.logicalHeight)\(traitText)"
    }

    private static func clipValue(_ clip: PlaybackState.Clip) -> String {
        switch clip {
        case .none: return "None"
        case .region(let count): return "\(count) region\(count == 1 ? "" : "s")"
        }
    }

    // MARK: Field formatters

    private static func point(_ p: PointL) -> String { "(\(p.x),\(p.y))" }
    private static func size(_ s: SizeL) -> String { "\(s.cx)×\(s.cy)" }

    private static func matrix(_ x: PlaybackState.Transform) -> String {
        "[\(num(x.a)) \(num(x.b)) \(num(x.c)) \(num(x.d))] +(\(num(x.tx)),\(num(x.ty)))"
    }

    /// A compact number: integers without a decimal point, otherwise ≤ 3 trimmed
    /// fractional digits. Non-finite values are shown literally.
    static func num(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : (value > 0 ? "∞" : "-∞") }
        if value == value.rounded() { return String(Int(value)) }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: Enum names

    static func mapModeName(_ mode: MapMode) -> String {
        switch mode {
        case .text: return "MM_TEXT"
        case .loMetric: return "MM_LOMETRIC"
        case .hiMetric: return "MM_HIMETRIC"
        case .loEnglish: return "MM_LOENGLISH"
        case .hiEnglish: return "MM_HIENGLISH"
        case .twips: return "MM_TWIPS"
        case .isotropic: return "MM_ISOTROPIC"
        case .anisotropic: return "MM_ANISOTROPIC"
        case .unknown(let raw): return String(format: "0x%08X", raw)
        }
    }

    static func backgroundModeName(_ mode: BackgroundMode) -> String {
        switch mode {
        case .transparent: return "TRANSPARENT"
        case .opaque: return "OPAQUE"
        case .unknown(let raw): return String(format: "0x%08X", raw)
        }
    }

    static func polyFillName(_ mode: PolygonFillMode) -> String {
        switch mode {
        case .alternate: return "ALTERNATE"
        case .winding: return "WINDING"
        case .unknown(let raw): return String(format: "0x%08X", raw)
        }
    }

    static func textAlignName(_ align: TextAlign) -> String {
        var parts: [String] = []
        switch align.horizontal {
        case .left: parts.append("Left")
        case .right: parts.append("Right")
        case .center: parts.append("Centre")
        }
        switch align.vertical {
        case .top: parts.append("Top")
        case .bottom: parts.append("Bottom")
        case .baseline: parts.append("Baseline")
        }
        if align.updatesCurrentPosition { parts.append("UpdateCP") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Observable model

/// The viewer's Records segment state (F5b). Holds the record list, the filter,
/// the step-through index and the DC state; the owning view drives the
/// `MetafilePartialPlayer` and feeds the resulting image and state back here.
@MainActor
@Observable
final class RecordInspectorModel {
    /// The record list rows for the current drawing.
    private(set) var refs: [RecordRef] = []
    /// The type-name filter query, bound to the filter field.
    var filterText = ""
    /// The step-through "through record" index (0 ..< refs.count).
    private(set) var selectedIndex = 0
    /// Whether per-record stepping is available (false for an EMF+ drawing file
    /// or a WMF program), so the scrubber is disabled and the full drawing shows.
    private(set) var supportsPartial = false
    /// Whether this drawing is an EMF with an EMF step-through at all (WMF programs
    /// expose only the list).
    private(set) var isEMF = false
    /// Drawing-record indices (sorted), for the ⌥←/⌥→ jump.
    private(set) var drawingIndices: [Int] = []
    /// The DC state after the selected record, or nil before the first step / for a
    /// non-steppable file.
    private(set) var state: PlaybackState?

    /// The content id the current `refs` were built for, so re-handing the same
    /// drawing is a no-op that preserves the selection and filter.
    @ObservationIgnored private var contentID: Int?
    /// Per-content summary cache, filled lazily off the main actor.
    @ObservationIgnored private var summaryCache: [Int: [Int: String]] = [:]

    var recordCount: Int { refs.count }

    /// True once a drawing has been loaded into the model.
    var hasRecords: Bool { !refs.isEmpty }

    /// The indices of the rows the filter shows, in file order.
    var filteredIndices: [Int] {
        RecordInspectorLogic.filteredIndices(refs, query: filterText)
    }

    /// Loads a drawing's record list. A re-load of the same content id keeps the
    /// current selection and filter (the viewer re-derives on unrelated changes).
    func setContent(refs: [RecordRef], drawingIndices: [Int], supportsPartial: Bool, isEMF: Bool, contentID: Int) {
        if self.contentID == contentID, self.refs.count == refs.count { return }
        self.contentID = contentID
        self.refs = refs
        self.drawingIndices = drawingIndices.sorted()
        self.supportsPartial = supportsPartial
        self.isEMF = isEMF
        self.state = nil
        // Start on the last record, so first showing the segment renders the full
        // drawing (the live canvas the user already sees).
        self.selectedIndex = max(0, refs.count - 1)
    }

    /// Caches/returns the one-line summary for a row, building it via `build` (a
    /// pure `Prepared.recordSummary(at:)` call) only once per content.
    func summary(at index: Int, build: (Int) -> String?) -> String {
        guard let contentID else { return build(index) ?? "" }
        if let cached = summaryCache[contentID]?[index] { return cached }
        let value = build(index) ?? ""
        summaryCache[contentID, default: [:]][index] = value
        return value
    }

    /// The DC state after the selected record, fed back by the view after a step.
    func setState(_ state: PlaybackState?) { self.state = state }

    // MARK: Navigation

    func select(_ index: Int) {
        selectedIndex = min(max(0, index), max(0, refs.count - 1))
    }

    func step(by delta: Int) { select(selectedIndex + delta) }
    func home() { select(0) }
    func end() { select(max(0, refs.count - 1)) }

    /// ⌥←/⌥→: jump to the previous/next drawing record, if any.
    func jumpDrawing(forward: Bool) {
        if let target = RecordInspectorLogic.adjacentDrawingIndex(
            after: selectedIndex, drawingIndices: drawingIndices, forward: forward
        ) {
            select(target)
        }
    }

    /// The "n / total" readout for the controls.
    var positionText: String { "\(selectedIndex + 1) / \(max(1, refs.count))" }

    /// Whether the step-through controls are active (an EMF that supports partial
    /// playback with more than one record).
    var canStep: Bool { supportsPartial && refs.count > 1 }

    /// The DC-panel groups for the current state, or empty before the first step.
    var stateGroups: [RecordStateGroup] {
        guard let state else { return [] }
        return RecordStateFormat.groups(for: state)
    }
}
