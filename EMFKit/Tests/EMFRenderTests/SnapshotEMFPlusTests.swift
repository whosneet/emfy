import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// Phase-3 EMF+ gate: the two committed, hand-authored EMF+ corpus files render
/// to their accepted baselines and prove the EMF+ playback path that no
/// LibreOffice-shell file can reach.
///
/// - `handmade-emfplus-shapes.emf` (EMF+-only, Dual flag CLEAR) exercises the
///   phase-3 core: object-table path/brush/pen, FillPath/DrawPath, direct and
///   object-brush fills, a linear gradient, a world translate, an intersect
///   clip, and an open i16 polyline.
/// - `handmade-emfplus-dual.emf` (Dual flag SET, divergent GDI fallback) proves
///   the GetDC arbitration ([MS-EMFPLUS] §1.3.1): the EMF+ half plus only the
///   GDI records inside a GetDC window render; a GDI-only rectangle outside any
///   window (which a v1-style GDI player would draw) MUST NOT appear.
///
/// Both files are byte-for-byte the deterministic generator output (`provenance`)
/// and their baselines are committed only after the main session's visual pass on
/// the artifact PNGs.
@Suite("EMF+ corpus")
struct SnapshotEMFPlusTests {

    private static let shapesName = "handmade-emfplus-shapes"
    private static let dualName = "handmade-emfplus-dual"
    private static let imageName = "handmade-emfplus-image"

    // MARK: - Pixel predicates (device coords == bitmap coords)

    private static func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.r > 200 && p.g < 70 && p.b < 70
    }
    private static func isGreen(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.g > 130 && p.r < 90 && p.b < 90
    }
    private static func isBlue(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.b > 200 && p.r < 70 && p.g < 70
    }
    private static func isMagenta(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.r > 200 && p.b > 200 && p.g < 90
    }
    private static func isOrange(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.r > 200 && p.g > 90 && p.g < 200 && p.b < 80
    }
    private static func isWhite(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.r > 230 && p.g > 230 && p.b > 230
    }

    // MARK: - Provenance

    /// Each committed corpus file is byte-for-byte the generator output, so it
    /// can never drift from its documented origin. Under `EMFY_RECORD=1` this
    /// instead (re-)writes both files into the source `corpus/` and fails
    /// deliberately, so a recording run can never pass as green.
    @Test("EMF+ corpus provenance: all committed files equal the generator byte-for-byte")
    func provenance() throws {
        try verifyProvenance(Self.shapesName, data: EMFPlusCorpus.shapesData)
        try verifyProvenance(Self.dualName, data: EMFPlusCorpus.dualData)
        try verifyProvenance(Self.imageName, data: EMFPlusCorpus.imageData)
    }

    private func verifyProvenance(_ name: String, data: Data) throws {
        let url = TestPaths.corpusFile("\(name).emf")
        if isRecordingBaselines {
            try data.write(to: url)
            Issue.record("EMFY_RECORD: wrote \(url.path) — re-run without EMFY_RECORD to verify")
            return
        }
        let committed = try #require(
            try? Data(contentsOf: url),
            "corpus file not readable at \(url.path) — materialise it with EMFY_RECORD=1 swift test --filter provenance"
        )
        #expect(committed == data,
                "committed \(name).emf differs from the generator (\(committed.count) vs \(data.count) bytes)")
    }

    // MARK: - Parse sanity

    @Test("shapes parses as EMF+-only (Dual clear) with EMF+ drawing records")
    func shapesParse() throws {
        let file = try parseCorpusFile("\(Self.shapesName).emf")
        let plus = file.emfPlusStream()
        let hasDrawing = plus.records.contains(where: \.isDrawing)
        #expect(hasDrawing, "no EMF+ drawing records found")
        #expect(plus.header?.isDual == false, "EmfPlusHeader Dual flag should be clear")
    }

    @Test("dual parses as dual-mode (Dual set) with EMF+ drawing records")
    func dualParse() throws {
        let file = try parseCorpusFile("\(Self.dualName).emf")
        let plus = file.emfPlusStream()
        let hasDrawing = plus.records.contains(where: \.isDrawing)
        #expect(hasDrawing, "no EMF+ drawing records found")
        #expect(plus.header?.isDual == true, "EmfPlusHeader Dual flag should be set")
    }

    @Test("image parses as EMF+-only with an image object and DrawImage/DrawImagePoints")
    func imageParse() throws {
        let file = try parseCorpusFile("\(Self.imageName).emf")
        let plus = file.emfPlusStream()
        #expect(plus.header?.isDual == false, "EmfPlusHeader Dual flag should be clear")
        // The object table holds one decoded 8×8 32bpp-ARGB pixel bitmap.
        let images = plus.objectDefinitions().definitions.compactMap { definition -> EMFPlusImage? in
            if case .image(let image) = definition.decodedValue() { return image }
            return nil
        }
        let image = try #require(images.first, "no EMF+ image object decoded")
        guard case .bitmap(let header, let data) = image.content else {
            Issue.record("image content is not a bitmap"); return
        }
        #expect(header.width == 8 && header.height == 8 && header.stride == 32)
        #expect(header.pixelFormat == 0x0026_200A && header.bitmapDataType == 0)
        #expect(data.count == 256, "expected 8×8×4 pixel bytes, got \(data.count)")
        // Both image-drawing record types are present.
        #expect(plus.records.contains { $0.type == 0x401A }, "no DrawImage record")
        #expect(plus.records.contains { $0.type == 0x401B }, "no DrawImagePoints record")
    }

    // MARK: - Render coverage (ink probes)

    /// The shapes file renders its whole phase-3 repertoire with a clean render
    /// log (everything honoured), and each element lands where expected.
    @Test("shapes render: triangle, gradient, translated fill, and clipped fill")
    func shapesRender() throws {
        let (pixels, log) = try render(Self.shapesName, width: 360, height: 240)
        #expect(log.isClean, "unexpected render log for shapes: \(log.entries)")

        // Triangle (green solid FillPath) — probe its centroid.
        #expect(Self.isGreen(pixels[70, 60]), "triangle interior not filled green, got \(pixels[70, 60])")
        // Direct-colour red FillRects.
        #expect(Self.isRed(pixels[162, 45]), "direct red rect missing, got \(pixels[162, 45])")
        // Linear-gradient ellipse: redder on the left, bluer on the right.
        let left = pixels[250, 50], right = pixels[310, 50]
        #expect(Int(left.r) > Int(left.b) + 40, "gradient left is not redder, got \(left)")
        #expect(Int(right.b) > Int(right.r) + 40, "gradient right is not bluer, got \(right)")
        // Translated magenta fill present at +200; nothing at the untranslated spot.
        #expect(Self.isMagenta(pixels[240, 165]), "translated magenta fill missing, got \(pixels[240, 165])")
        #expect(Self.isWhite(pixels[40, 165]), "untranslated (phantom) position should be blank, got \(pixels[40, 165])")
        // Clipped orange fill: inside the clip only.
        #expect(Self.isOrange(pixels[255, 212]), "clipped fill missing inside the clip, got \(pixels[255, 212])")
        #expect(Self.isWhite(pixels[100, 212]), "fill leaked left of the clip, got \(pixels[100, 212])")
        #expect(Self.isWhite(pixels[330, 212]), "fill leaked right of the clip, got \(pixels[330, 212])")
        // The open polyline drew dark ink along its path.
        #expect(pixels.containsDarkPixel(in: (x: 245, y: 90, width: 25, height: 16)),
                "DrawLines polyline drew no ink")
    }

    /// The dual file renders its EMF+ content plus the GetDC-windowed GDI
    /// rectangle, and NOTHING outside a GetDC window — the arbitration proof.
    @Test("dual render: EMF+ red + windowed GDI green; skipped GDI leaves rects C and D blank")
    func dualRender() throws {
        let (pixels, log) = try render(Self.dualName, width: 360, height: 240)
        #expect(log.isClean, "unexpected render log for dual: \(log.entries)")

        #expect(Self.isRed(pixels[60, 60]), "EMF+ red rect A missing, got \(pixels[60, 60])")
        #expect(Self.isGreen(pixels[180, 60]), "GetDC-windowed GDI green rect B missing, got \(pixels[180, 60])")
        #expect(Self.isWhite(pixels[270, 60]), "rect C (window closed) should be blank, got \(pixels[270, 60])")
        #expect(Self.isWhite(pixels[105, 180]), "GDI-only rect D (outside any window) should be blank, got \(pixels[105, 180])")
    }

    /// The image file renders its 8×8 four-quadrant bitmap twice — scaled into a
    /// 120×120 dest rect (DrawImage) and mapped into a sheared parallelogram
    /// (DrawImagePoints) — with a clean render log. Probes sit at each quadrant's
    /// centre; the red/green/blue quadrants carry the strong signal (the white
    /// quadrant is indistinguishable from the blank canvas, so the snapshot
    /// verifies it), and blank probes bound each image spatially.
    @Test("image render: DrawImage scaling and DrawImagePoints shear place every quadrant")
    func imageRender() throws {
        let (pixels, log) = try render(Self.imageName, width: 360, height: 240)
        #expect(log.isClean, "unexpected render log for image: \(log.entries)")

        // DrawImage: 8×8 → dest (40,30,120,120); quadrant split at (100, 90).
        #expect(Self.isRed(pixels[70, 60]), "DrawImage red quadrant, got \(pixels[70, 60])")
        #expect(Self.isGreen(pixels[130, 60]), "DrawImage green quadrant, got \(pixels[130, 60])")
        #expect(Self.isBlue(pixels[70, 120]), "DrawImage blue quadrant, got \(pixels[70, 120])")
        #expect(Self.isWhite(pixels[130, 120]), "DrawImage white quadrant, got \(pixels[130, 120])")
        // The scaled image is spatially bounded (blank above-left of its origin).
        #expect(Self.isWhite(pixels[20, 20]), "canvas above-left of the image not blank, got \(pixels[20, 20])")

        // DrawImagePoints: parallelogram UL(220,40) UR(320,60) LL(240,150);
        // quadrant centres computed from the affine src→parallelogram map.
        #expect(Self.isRed(pixels[250, 72]), "DrawImagePoints red quadrant, got \(pixels[250, 72])")
        #expect(Self.isGreen(pixels[300, 82]), "DrawImagePoints green quadrant, got \(pixels[300, 82])")
        #expect(Self.isBlue(pixels[260, 127]), "DrawImagePoints blue quadrant, got \(pixels[260, 127])")
        // Blank to the left of the sheared parallelogram.
        #expect(Self.isWhite(pixels[210, 100]), "canvas left of the parallelogram not blank, got \(pixels[210, 100])")
    }

    // MARK: - Snapshots

    @Test("shapes snapshot: EMF+-only geometry against the accepted baseline")
    func shapesSnapshot() throws {
        try snapshot(Self.shapesName)
    }

    @Test("dual snapshot: EMF+ + windowed GDI against the accepted baseline")
    func dualSnapshot() throws {
        try snapshot(Self.dualName)
    }

    @Test("image snapshot: DrawImage + DrawImagePoints against the accepted baseline")
    func imageSnapshot() throws {
        try snapshot(Self.imageName)
    }

    // MARK: - Helpers

    private func render(_ name: String, width: Int, height: Int) throws -> (RasterizedImage, EMFRenderLog) {
        let file = try parseCorpusFile("\(name).emf")
        let (image, log) = try #require(
            EMFRenderer.makeImage(file, scale: 1),
            "makeImage returned nil for \(name)"
        )
        #expect(image.width == width)
        #expect(image.height == height)
        return (try #require(RasterizedImage(image), "could not rasterize \(name)"), log)
    }

    private func snapshot(_ name: String) throws {
        let file = try parseCorpusFile("\(name).emf")
        let (image, _) = try #require(
            EMFRenderer.makeImage(file, scale: 1),
            "makeImage returned nil for \(name)"
        )
        print("[emf+] render artifact: \(Self.writeArtifactPNG(image, name: name))")
        let failure = SnapshotComparator.verify(image, baselineNamed: name)
        #expect(failure == nil, Comment(rawValue: failure ?? ""))
    }

    /// Writes the rendered PNG into the shared artifacts folder for visual
    /// acceptance and returns its path (never masks a test result).
    private static func writeArtifactPNG(_ image: CGImage, name: String) -> String {
        let directory = TestPaths.artifactsDirectory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("render.png")
        return SnapshotComparator.writePNG(image, to: url) ? url.path : "(failed to write \(url.path))"
    }
}
