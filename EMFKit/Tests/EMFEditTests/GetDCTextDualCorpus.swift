import CoreGraphics
import EMFParse
import EMFRender
import EMFWrite
import Foundation
@testable import EMFEdit

/// Deterministic generator for `corpus/handmade-getdc-text-dual.emf` — the first
/// committed fixture that exercises an edited GetDC-window GDI text run drawn
/// under a FRACTIONAL world transform (slice E1b2e item 1, until now proven only
/// on confidential corpus-local files).
///
/// Two stages, both pure functions of the literals below (our own writer and
/// exporter over fixed inputs, so the committed bytes are reproducible):
///
///  1. `sourceGDIData()` — a GDI-only EMF authored with the public EMFWrite
///     builders (`EMFDocumentBuilder`): a fractional `EMR_SETWORLDTRANSFORM`
///     ([MS-EMF] §2.3.12.2), two TA_BASELINE `EMR_EXTTEXTOUTW` runs (§2.3.5.8)
///     with explicit Dx advances — one Latin at natural spacing, one condensed —
///     and two filled shapes (a rectangle and an ellipse).
///
///  2. `fixtureData()` — that GDI EMF imported into a `Scene`, the rectangle's
///     opacity set to 0.5, then exported as EMF. The edit needs alpha, which GDI
///     cannot express, so the E1b2b GDI→dual collapse (`overlayGDIAsDual`) writes
///     a DUAL EMF+ file: every unedited record — including the world-transform
///     preamble and both text runs — replays verbatim inside an `EmfPlusGetDC`
///     window ([MS-EMFPLUS] §2.3.3.2), and the rectangle becomes an EMF+
///     Save/Restore block. That dual output is the committed fixture. Re-imported,
///     each text run is a GetDC-window GDI element, so editing it drives
///     `SceneSynthesis.emfTextBlockWorld` (the SetWorldTransform + logical-units
///     re-emit) — the path this fixture pins down.
///
/// `GetDCTextDualProvenanceTests` regenerates `fixtureData()` and asserts the
/// on-disk file is byte-identical, so the fixture never drifts from its origin.
enum GetDCTextDualCorpus {

    // MARK: - Committed fixture name

    static let fixtureName = "handmade-getdc-text-dual"

    // MARK: - Page metrics

    /// 400×300 device px; `rclBounds` is inclusive-inclusive ([MS-EMF] §2.2.9).
    private static let page = RectL(left: 0, top: 0, right: 399, bottom: 299)
    /// `rclFrame` in 0.01 mm at 96 DPI: 400 px → 400·2540/96, 300 px → 300·2540/96.
    private static let frame = RectL(left: 0, top: 0, right: 10583, bottom: 7937)
    private static let device = SizeL(cx: 400, cy: 300)
    private static let millimeters = SizeL(cx: 106, cy: 79)

    // MARK: - Content constants

    /// A fractional world transform ([MS-EMF] §2.2.28 XForm): a near-unity scale
    /// plus a fractional offset, so every drawn device coordinate is fractional —
    /// the condition under which an integer EXTTEXTOUTW re-emission quantises the
    /// baseline and the world-transform re-emit does not.
    private static let world = XForm(m11: 1.0020, m12: 0, m21: 0, m22: 1.0048, dx: 12.3, dy: 7.7)

    /// TA_LEFT | TA_BASELINE ([MS-WMF] §2.1.2.3): the reference sits on the baseline.
    private static let baselineAlign: UInt32 = 24
    /// LOGFONT character height, logical units, SIGNED negative = em height (§2.2.13).
    private static let fontHeight: Int32 = -24
    /// A macOS-resident face, so the GDI lift resolves it without substitution; the
    /// run's bytes replay verbatim regardless, so the choice does not affect the
    /// committed fixture — only the relative identity-oracle render.
    private static let fontFace = "Helvetica"

    struct TextRun {
        let string: String
        let reference: PointL
        let color: ColorRef
        /// One advance per UTF-16 code unit, LOGICAL units ([MS-EMF] §2.2.5).
        let dx: [UInt32]
    }

    /// Run 1 at natural spacing, run 2 condensed (10 logical units/char vs 16).
    private static let runs: [TextRun] = [
        TextRun(string: "Metafile", reference: PointL(x: 30, y: 90),
                color: ColorRef(red: 20, green: 20, blue: 20),
                dx: Array(repeating: 16, count: "Metafile".utf16.count)),
        TextRun(string: "Condensed", reference: PointL(x: 30, y: 160),
                color: ColorRef(red: 150, green: 30, blue: 30),
                dx: Array(repeating: 10, count: "Condensed".utf16.count)),
    ]

    /// The rectangle whose opacity the edit sets to 0.5 (so GDI→dual fires).
    private static let rectBox = RectL(left: 210, top: 40, right: 360, bottom: 120)
    private static let rectColor = ColorRef(red: 40, green: 160, blue: 80)
    /// A sibling shape left unedited (replays verbatim in a GetDC window).
    private static let ellipseBox = RectL(left: 210, top: 160, right: 360, bottom: 240)
    private static let ellipseColor = ColorRef(red: 60, green: 90, blue: 200)

    // MARK: - Stage 1: the GDI source

    /// The GDI-only source EMF (no EMF+). Object handles: font 1, rect brush 2,
    /// ellipse brush 3.
    static func sourceGDIData() throws -> Data {
        let builder = EMFDocumentBuilder(bounds: page, frame: frame, device: device, millimeters: millimeters)

        try builder.append(.setMapMode(.text))
        try builder.append(.setBkMode(.transparent))
        // The fractional world transform governs every following drawing record.
        try builder.append(.setWorldTransform(world))

        // Two filled shapes under a NULL pen (no outline), drawn first (background).
        let rectBrush = try builder.allocateObjectHandle()      // 1
        try builder.append(.selectObject(.stock(.nullPen)))
        try builder.append(.createBrushIndirect(CreateBrushPayload(ihBrush: rectBrush, style: 0, color: rectColor, hatch: 0)))
        try builder.append(.selectObject(.table(index: rectBrush)))
        try builder.append(.rectangle(box: rectBox))
        try builder.append(.selectObject(.stock(.whiteBrush)))
        try builder.append(.deleteObject(.table(index: rectBrush)))

        let ellipseBrush = try builder.allocateObjectHandle()   // 2
        try builder.append(.createBrushIndirect(CreateBrushPayload(ihBrush: ellipseBrush, style: 0, color: ellipseColor, hatch: 0)))
        try builder.append(.selectObject(.table(index: ellipseBrush)))
        try builder.append(.ellipse(box: ellipseBox))
        try builder.append(.selectObject(.stock(.whiteBrush)))
        try builder.append(.deleteObject(.table(index: ellipseBrush)))

        // Two TA_BASELINE text runs with explicit Dx, sharing one font object.
        let font = try builder.allocateObjectHandle()           // 3
        try builder.append(.setTextAlign(TextAlign(rawValue: baselineAlign)))
        try builder.append(.extCreateFontIndirectW(ExtCreateFontPayload(
            ihFonts: font, logFont: logFont(height: fontHeight, face: fontFace), hasExtendedData: false)))
        try builder.append(.selectObject(.table(index: font)))
        for run in runs {
            try builder.append(.setTextColor(run.color))
            try builder.append(.extTextOutW(ExtTextPayload(
                graphicsMode: 1, exScale: 1, eyScale: 1, reference: run.reference,
                rectangle: RectL(left: 0, top: 0, right: 0, bottom: 0), string: run.string,
                options: ExtTextOutOptions(rawValue: 0), dx: run.dx)))
        }
        try builder.append(.selectObject(.stock(.systemFont)))
        try builder.append(.deleteObject(.table(index: font)))

        return try builder.finish()
    }

    /// A 92-byte LogFont ([MS-EMF] §2.2.13) for the text runs: normal weight,
    /// upright, default charset, the named face.
    private static func logFont(height: Int32, face: String) -> LogFont {
        LogFont(height: height, width: 0, escapement: 0, orientation: 0, weight: 400,
                italic: 0, underline: 0, strikeOut: 0, charSet: 0,
                outPrecision: 0, clipPrecision: 0, quality: 0, pitchAndFamily: 0, faceName: face)
    }

    // MARK: - Stage 2: edit a sibling shape's opacity → dual output

    /// The committed fixture: import the GDI source, set the rectangle's opacity to
    /// 0.5 (the edit GDI cannot hold, so the export upgrades to a dual EMF+ file),
    /// and export.
    static func fixtureData() throws -> Data {
        let scene = try SceneImporter.import(data: try sourceGDIData())
        var edited = scene
        let rect = try editedRectID(scene)
        try edited.setOpacity([rect], 0.5)
        return try SceneExporter.export(edited, as: .emf).data
    }

    /// The id of the rectangle element (the first `.rect` in z-order), the element
    /// whose opacity the fixture edits.
    static func editedRectID(_ scene: Scene) throws -> Int {
        guard let rect = scene.editableElements.first(where: { $0.kind == .rect }) else {
            throw GeneratorError.noRectangle
        }
        return rect.id
    }

    enum GeneratorError: Error { case noRectangle }
}
