import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// W4 gate: WMF playback snapshots through the shared renderer, compared against
/// committed baselines recorded FROM our renderer with the hand-rolled
/// comparator (primer §2). Three families:
///   - the GDI-record path on the stripped p2/p3 WMF-only variants (the main
///     session eyeballed and accepted these W4a renders against LibreOffice),
///   - the GDI-record path on the p4 image/text variants (candidate baselines,
///     accepted only after the main session reviews the side-by-side evidence),
///   - the embedded-EMF path on the 7 original LibreOffice exports (the embedded
///     reassembly + EMF playback pinned end to end).
@Suite("WMF gate snapshots")
struct SnapshotWMFTests {

    private static func render(_ file: String) throws -> CGImage {
        let data = try Data(contentsOf: TestPaths.corpusFile(file))
        let opened = try OpenedMetafile.open(data)
        let (image, _) = try #require(
            MetafileRenderer.makeImage(opened),
            "makeImage returned nil for \(file)"
        )
        return image
    }

    private static func verify(_ file: String, baseline: String) throws {
        let image = try Self.render(file)
        // Gate: the file renders something, never a silent blank canvas (§8).
        let raster = try #require(RasterizedImage(image))
        #expect(
            raster.containsDarkPixel(in: (0, 0, raster.width, raster.height)),
            "\(file): rendered a blank canvas"
        )
        let failure = SnapshotComparator.verify(image, baselineNamed: baseline)
        #expect(failure == nil, Comment(rawValue: failure ?? ""))
    }

    // MARK: - GDI-record path, stripped p2/p3 WMF-only variants (accepted)

    @Test("WMF GDI record path renders the p2/p3 gate variants", arguments: [
        "gate-wmf-gdi-p2-house", "gate-wmf-gdi-p2-star", "gate-wmf-gdi-p2-triangles",
        "gate-wmf-gdi-p3-curves", "gate-wmf-gdi-p3-shapes",
    ])
    func gdiVectorVariants(name: String) throws {
        try Self.verify("\(name).wmf", baseline: name)
    }

    // MARK: - GDI-record path, p4 image + text variants (candidate baselines)

    @Test("WMF GDI record path renders META_STRETCHDIB + META_POLYPOLYGON (image)")
    func gdiP4Image() throws {
        try Self.verify("gate-wmf-gdi-p4-image.wmf", baseline: "gate-wmf-gdi-p4-image")
    }

    @Test("WMF GDI record path renders META_CREATEFONTINDIRECT + META_TEXTOUT (text)")
    func gdiP4Text() throws {
        try Self.verify("gate-wmf-gdi-p4-text.wmf", baseline: "gate-wmf-gdi-p4-text")
    }

    // MARK: - Embedded-EMF path, the 7 original LibreOffice exports

    @Test("WMF embedded-EMF path renders the original gate exports", arguments: [
        "gate-wmf-p2-house", "gate-wmf-p2-star", "gate-wmf-p2-triangles",
        "gate-wmf-p3-curves", "gate-wmf-p3-shapes",
        "gate-wmf-p4-image", "gate-wmf-p4-text",
    ])
    func embeddedEMF(name: String) throws {
        try Self.verify("\(name).wmf", baseline: name)
    }
}
