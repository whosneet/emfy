import CoreGraphics
import EMFEdit
import EMFParse
import EMFRender
import Foundation
import Testing

// E2c unit tests for the Format inspector: the pure value derivation (displayed and
// mixed states), the apply-to-many and delete commands through `DocumentSession`,
// slider coalescing, font-size unit conversion, text sanitisation, and a save →
// re-import round trip proving a recolour, opacity, text and font survive (EMF and
// EMZ). All built from hand scenes or committed corpus files — no window.

// MARK: - Fixtures

private func makeScene(_ elements: [Element], page: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)) -> Scene {
    let layer = Layer(id: 0, name: "L", elements: elements)
    let partition = ScenePartition(structural: [], state: [], drawing: [], passthrough: [], unitCount: 0)
    let source = SceneSource(data: Data(), format: .emf, wasCompressed: false, renderPath: .gdi, unitCount: 0)
    return Scene(pageBoundsDevice: page, layers: [layer], partition: partition, source: source)
}

private func rect(id: Int, fill: SceneColor?, opacity: Double = 1, stroke: SceneStroke? = nil) -> Element {
    let segs: [ScenePath.Segment] = [
        .move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 10, y: 0)),
        .line(CGPoint(x: 10, y: 10)), .line(CGPoint(x: 0, y: 10)), .close,
    ]
    var style = SceneStyle()
    if let fill { style.fill = SceneFill(color: fill, evenOdd: false) }
    style.stroke = stroke
    style.opacity = opacity
    return Element(
        id: id, kind: .rect, geometryDevice: ScenePath(segments: segs),
        transform: .identity, style: style, provenance: Provenance(sourceRecordIndices: [id])
    )
}

private func textElement(id: Int, string: String, height: Int32, transform: CGAffineTransform = .identity, bold: Bool = false, italic: Bool = false) -> Element {
    var lifted = SceneText(LiftedTextStub.make(string: string, height: height, bold: bold, italic: italic))
    lifted.string = string
    return Element(
        id: id, kind: .text, geometryDevice: ScenePath(segments: [.move(.zero), .line(CGPoint(x: 50, y: 0))]),
        transform: transform, style: SceneStyle(), text: lifted,
        provenance: Provenance(sourceRecordIndices: [id])
    )
}

/// A minimal `LiftedText` substitute so a text `Element` can be hand-built without the
/// renderer's lifting pipeline. Only the fields the inspector reads are set.
private enum LiftedTextStub {
    static func make(string: String, height: Int32, bold: Bool, italic: Bool) -> LiftedText {
        LiftedText(
            string: string, fontFamily: "Helvetica", requestedFamily: "Helvetica",
            logicalHeight: height, bold: bold, italic: italic, underline: false, strikeOut: false,
            escapementTenths: 0, color: ColorRef(red: 0, green: 0, blue: 0),
            referenceLogical: PointL(x: 0, y: 0), alignRawValue: 0, advancesLogical: []
        )
    }
}

private let red = SceneColor(red: 1, green: 0, blue: 0)
private let blue = SceneColor(red: 0, green: 0, blue: 1)

// MARK: - Model derivation

@Suite struct FormatInspectorModelTests {

    @Test func emptySelectionIsEmpty() {
        let model = FormatInspectorModel(selected: [])
        #expect(model.isEmpty)
    }

    @Test func uniformSolidFillShowsColour() {
        let model = FormatInspectorModel(selected: [rect(id: 1, fill: red), rect(id: 2, fill: red)])
        #expect(model.fill == .color(red))
    }

    @Test func differingFillsAreMixed() {
        let model = FormatInspectorModel(selected: [rect(id: 1, fill: red), rect(id: 2, fill: blue)])
        #expect(model.fill == .mixed)
    }

    @Test func noFillIsNone() {
        let model = FormatInspectorModel(selected: [rect(id: 1, fill: nil)])
        #expect(model.fill == .none)
    }

    @Test func aSingleGradientFillIsReadOnlyGradient() {
        var element = rect(id: 1, fill: red)
        element.style.fill = SceneFill(
            color: red, evenOdd: false,
            gradient: SceneGradient(stops: [.init(location: 0, color: red), .init(location: 1, color: blue)], startDevice: .zero, endDevice: CGPoint(x: 10, y: 0), tilesWrap: false)
        )
        #expect(FormatInspectorModel(selected: [element]).fill == .gradient)
    }

    @Test func strokeUniformAndMixed() {
        let s = SceneStroke(color: red, isCosmetic: false, width: 2, dash: .solid, cap: .round, join: .round, miterLimit: 10)
        let both = FormatInspectorModel(selected: [rect(id: 1, fill: red, stroke: s), rect(id: 2, fill: red, stroke: s)])
        #expect(both.stroke == .uniform(color: red, width: 2, cosmetic: false, dash: .solid))

        let mixed = FormatInspectorModel(selected: [rect(id: 1, fill: red, stroke: s), rect(id: 2, fill: red, stroke: nil)])
        #expect(mixed.stroke == .mixed)

        let none = FormatInspectorModel(selected: [rect(id: 1, fill: red)])
        #expect(none.stroke == .none)
    }

    @Test func opacityUniformAndMixed() {
        #expect(FormatInspectorModel(selected: [rect(id: 1, fill: red, opacity: 0.5), rect(id: 2, fill: red, opacity: 0.5)]).opacity == .uniform(0.5))
        #expect(FormatInspectorModel(selected: [rect(id: 1, fill: red, opacity: 0.5), rect(id: 2, fill: red, opacity: 1)]).opacity == .mixed)
    }

    @Test func textSectionOnlyForExactlyOneTextElement() {
        let text = textElement(id: 1, string: "Hi", height: -24, bold: true)
        let single = FormatInspectorModel(selected: [text])
        #expect(single.text?.content == "Hi")
        #expect(single.text?.bold == true)
        #expect(single.text?.pointSize == 24)   // identity transform ⇒ logical == device

        // A text element plus a shape is NOT a single-text selection.
        #expect(FormatInspectorModel(selected: [text, rect(id: 2, fill: red)]).text == nil)
        // A shape alone has no Text section.
        #expect(FormatInspectorModel(selected: [rect(id: 2, fill: red)]).text == nil)
    }
}

// MARK: - Font size conversion

@Suite struct FontSizeConversionTests {

    @Test func identityTransformKeepsLogicalAsPoints() {
        let text = textElement(id: 1, string: "A", height: -30).text!
        #expect(FontSizeConversion.displayPointSize(text, transform: .identity) == 30)
        #expect(FontSizeConversion.logicalSize(fromPoints: 30, transform: .identity) == 30)
    }

    @Test func aScaledTransformScalesTheDevicePoints() {
        // A run whose transform doubles the page: a 20-unit logical em draws 40 pt.
        let text = textElement(id: 1, string: "A", height: -20).text!
        let t = CGAffineTransform(scaleX: 2, y: 2)
        #expect(FontSizeConversion.displayPointSize(text, transform: t) == 40)
        // Choosing 40 pt on that run stores a 20-unit logical height.
        #expect(FontSizeConversion.logicalSize(fromPoints: 40, transform: t) == 20)
    }

    @Test func logicalSizeIsClampedPositive() {
        #expect(FontSizeConversion.logicalSize(fromPoints: 0, transform: .identity) == 1)
        #expect(FontSizeConversion.logicalSize(fromPoints: -8, transform: .identity) == 1)
    }

    @Test func fontCommandCarriesTheConvertedSize() {
        let command = FontSizeConversion.fontCommand(id: 1, family: "Times", points: 18, transform: .identity, bold: true, italic: false)
        guard case .setFont(let id, let family, let size, let bold, let italic) = command else {
            Issue.record("expected setFont"); return
        }
        #expect(id == 1 && family == "Times" && size == 18 && bold && !italic)
    }
}

// MARK: - Text sanitisation

@Suite struct TextSanitizerTests {

    @Test func stripsControlCharactersButKeepsTab() {
        let input = "a\u{0}b\nc\td\u{7F}e\u{1B}f"
        #expect(TextSanitizer.sanitize(input) == "ab" + "c\td" + "ef")
    }

    @Test func keepsOrdinaryTextIntact() {
        #expect(TextSanitizer.sanitize("Hello, world — café 123") == "Hello, world — café 123")
    }

    @Test func capsTheLength() {
        let long = String(repeating: "x", count: TextSanitizer.maxScalars + 500)
        #expect(TextSanitizer.sanitize(long).unicodeScalars.count == TextSanitizer.maxScalars)
    }
}

// MARK: - Apply-to-many, slider coalescing, delete (through the session)

@MainActor
@Suite struct FormatInspectorSessionTests {

    /// One fillable rectangle EMF (device 10…90), lifting a single editable element.
    private func editableEMF() -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        u32(1); u32(88)
        i32(0); i32(0); i32(99); i32(99)
        i32(0); i32(0); i32(2117); i32(2117)
        u32(0x464D4520); u32(0x0001_0000); u32(88 + 24 + 20); u32(3)
        u16(1); u16(0); u32(0); u32(0); u32(0)
        i32(1920); i32(1080); i32(508); i32(286)
        u32(43); u32(24); i32(10); i32(10); i32(90); i32(90)
        u32(14); u32(20); u32(0); u32(16); u32(20)
        return d
    }

    private func session(_ bytes: Data, fileName: String = "drawing.emf") -> DocumentSession {
        DocumentSession(
            entryID: UUID(),
            resolve: { _ in bytes },
            writeBytes: { _, _, _ in },
            documentFileName: { fileName },
            autosave: AutosaveController(sleep: { _ in try? await Task.sleep(for: .seconds(86_400)) })
        )
    }

    @Test func applyToManySetsFillOnEverySelectedElement() {
        // Two shapes selected; one fill command recolours both.
        var scene = makeScene([rect(id: 1, fill: red), rect(id: 2, fill: blue)])
        let model = FormatInspectorModel(selected: scene.elements)
        #expect(model.fill == .mixed)
        try! scene.setFill(model.ids, SceneFill(color: red, evenOdd: false))
        #expect(FormatInspectorModel(selected: scene.elements).fill == .color(red))
    }

    @Test func tenSliderChangesInOneInteractionGiveOneUndoEntry() async {
        let session = session(editableEMF())
        await session.beginEditing()
        let original = session.history!.scene
        let key = SceneCoalescingKey("opacity-1")
        for step in 1...10 {
            session.apply(.setOpacity(ids: [0], 1 - Double(step) * 0.05), coalescing: key)
        }
        #expect(session.undoManager.canUndo)
        session.undoManager.undo()
        #expect(session.history!.scene == original)   // one undo reverses the whole drag
        #expect(!session.undoManager.canUndo)
    }

    @Test func deleteClearsSelectionAndUndoRestoresBoth() async {
        let session = session(editableEMF())
        await session.beginEditing()
        var restored: Set<Int>? = nil
        session.selectionRestore = { restored = $0 }
        let id = session.history!.scene.editableElements.first!.id

        session.deleteSelection([id])
        #expect(session.history!.scene.elements.first { $0.id == id } == nil)   // element gone
        #expect(restored == [])                                                 // selection cleared

        session.undoManager.undo()
        #expect(session.history!.scene.elements.first { $0.id == id } != nil)   // element back
        #expect(restored == [id])                                               // selection restored

        session.undoManager.redo()
        #expect(session.history!.scene.elements.first { $0.id == id } == nil)
        #expect(restored == [])
    }
}

// MARK: - Save → re-import round trip (EMF and EMZ)

@Suite struct FormatRoundTripTests {

    private func corpusText() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("corpus/gate-p4-text.emf")
        return try Data(contentsOf: url)
    }

    /// One fillable rectangle EMF (device 10…90), lifting a single editable shape.
    private func rectEMF() -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        u32(1); u32(88)
        i32(0); i32(0); i32(99); i32(99)
        i32(0); i32(0); i32(2117); i32(2117)
        u32(0x464D4520); u32(0x0001_0000); u32(88 + 24 + 20); u32(3)
        u16(1); u16(0); u32(0); u32(0); u32(0)
        i32(1920); i32(1080); i32(508); i32(286)
        u32(43); u32(24); i32(10); i32(10); i32(90); i32(90)
        u32(14); u32(20); u32(0); u32(16); u32(20)
        return d
    }

    /// A recolour + opacity on a shape survives a save and re-import (EMF and EMZ): the
    /// opacity drives the GDI → dual-EMF+ upgrade, so the sub-1 alpha is carried.
    @Test(arguments: [EMFEdit.ExportFormat.emf, EMFEdit.ExportFormat.emz])
    func shapeFillAndOpacitySurvive(_ format: EMFEdit.ExportFormat) throws {
        let scene = try SceneImporter.import(data: rectEMF())
        let id = try #require(scene.editableElements.first).id
        var edited = scene
        try edited.setFill([id], SceneFill(color: red, evenOdd: false))
        try edited.setOpacity([id], 0.5)

        let exported = try SceneExporter.export(edited, as: format)
        let reimported = try SceneImporter.import(data: exported.data)
        let reShape = try #require(reimported.editableElements.first)
        let colour = try #require(reShape.style.fill?.color)
        #expect(abs(colour.red - 1) < 0.05 && colour.green < 0.05 && colour.blue < 0.05)
        // Opacity survives through the dual EMF+ upgrade; on re-import the sub-1 alpha is
        // carried in the fill colour's alpha (EMF+ ARGB), so the effective alpha is 0.5.
        let effectiveAlpha = reShape.style.opacity * colour.alpha
        #expect(abs(effectiveAlpha - 0.5) < 0.05)
    }

    /// A text edit + font change survives a save and re-import (EMF and EMZ): the new
    /// string, the chosen family size (via the effective em) and Bold are kept.
    @Test(arguments: [EMFEdit.ExportFormat.emf, EMFEdit.ExportFormat.emz])
    func textAndFontSurvive(_ format: EMFEdit.ExportFormat) throws {
        let scene = try SceneImporter.import(data: corpusText())
        let textElement = try #require(scene.editableElements.first { $0.kind == .text })
        var edited = scene
        try edited.setText(textElement.id, "Emfy")
        try edited.setFill([textElement.id], SceneFill(color: red, evenOdd: false))
        // Choose a 48-point on-page size, converted to the run's logical height through
        // its transform (exactly what the inspector does) so the device size round-trips.
        let logical = FontSizeConversion.logicalSize(fromPoints: 48, transform: textElement.transform)
        try edited.setFont(textElement.id, family: "Helvetica", size: logical, bold: true, italic: false)

        let exported = try SceneExporter.export(edited, as: format)
        let reimported = try SceneImporter.import(data: exported.data)
        let reText = try #require(reimported.editableElements.first { $0.kind == .text })

        #expect(reText.text?.string == "Emfy")
        #expect(reText.text?.bold == true)
        let colour = reText.style.fill?.color ?? reText.text?.color
        #expect(colour.map { abs($0.red - 1) < 0.05 && $0.green < 0.05 && $0.blue < 0.05 } == true)
        // The chosen ~48-point on-page size survives the save and re-import.
        let displayPt = reText.text.map { FontSizeConversion.displayPointSize($0, transform: reText.transform) } ?? 0
        #expect(displayPt >= 40 && displayPt <= 56)
    }
}

// MARK: - Text-run selection bounds (E2c item 3)

@Suite struct TextSelectionBoundsTests {

    private func corpusTextScene() throws -> Scene {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("corpus/gate-p4-text.emf")
        return try SceneImporter.import(data: Data(contentsOf: url))
    }

    /// Selecting the single text run in gate-p4-text.emf must draw a TIGHT box around the
    /// glyphs, not a page-tall box. EMFEdit's `boundsDevice` for a GDI text run with no
    /// device geometry is the inherited page clip (effectively the whole page); the app's
    /// `selectionBoundsDevice` derives a tight box from the run's metrics instead, and the
    /// selection's union box (what the overlay draws) uses it.
    @Test func textRunSelectionBoxIsTightNotFullPage() throws {
        let scene = try corpusTextScene()
        let textElement = try #require(scene.editableElements.first { $0.kind == .text })
        let page = scene.pageBoundsDevice

        // The raw EMFEdit bounds (page clip) vs the app's tight selection bounds. For
        // gate-p4-text.emf the run has no device geometry, so `boundsDevice` is the whole
        // page (377×177) while `selectionBoundsDevice` is a tight ~239×78 glyph box.
        let raw = textElement.boundsDevice
        let tight = textElement.selectionBoundsDevice

        // The app-derived tight box is well under half the page height and smaller than
        // the raw (page-clip) box in both dimensions.
        #expect(tight.height < page.height * 0.5)
        #expect(tight.height < raw.height)
        #expect(tight.width <= raw.width)
        #expect(!tight.isNull && tight.width > 0 && tight.height > 0)

        // The selection's union box (handles drawn around it) is the tight box, not the
        // full page.
        var selection = EditorSelection()
        selection.replace(with: textElement.id)
        let box = try #require(selection.boundsDevice(in: scene))
        #expect(box.height < page.height * 0.5)
        #expect(abs(box.height - tight.height) < 0.5)
    }

    /// A non-text element is unaffected: its `selectionBoundsDevice` is exactly its
    /// `boundsDevice` (only text runs get the metric-derived box).
    @Test func nonTextSelectionBoundsAreUnchanged() throws {
        let scene = try corpusTextScene()
        if let shape = scene.editableElements.first(where: { $0.kind != .text }) {
            #expect(shape.selectionBoundsDevice == shape.boundsDevice)
        }
    }
}

// MARK: - P8: slider-apply throttle

@MainActor
@Suite struct SliderApplyThrottleTests {
    // The first submit fires immediately (so the control feels live).
    @Test func firstSubmitFiresImmediately() {
        let throttle = SliderApplyThrottle(hz: 60)
        var fired: [Int] = []
        throttle.submit { fired.append(1) }
        #expect(fired == [1])
    }

    // A rapid burst coalesces: only the first fires synchronously; the rest wait for the
    // trailing timer, and the LAST value is the one delivered (never dropped).
    @Test func burstCoalescesAndDeliversTheLastValue() async {
        let throttle = SliderApplyThrottle(hz: 60)
        var fired: [Int] = []
        for v in 1...20 { throttle.submit { fired.append(v) } }
        #expect(fired == [1])                       // only the first fired synchronously
        // Let the trailing fire land (≥ 1/60 s).
        try? await Task.sleep(nanoseconds: 60_000_000)
        #expect(fired.last == 20)                    // the final value was delivered
        #expect(fired.count < 20)                    // the middle values coalesced away
    }
}
