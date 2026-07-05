import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// Phase-3 gate: the committed path-bracket corpus files render to their
/// accepted baselines, AND their render logs contain EXACTLY the expected
/// entries — the phase-3 coverage pin. Every path bracket, clip, and geometry
/// record is fully honoured; the only log entries are the LibreOffice EMF+
/// comment shell (type 70) and the EMR_EOF terminator (type 14) on the exported
/// files, and EOF alone on the hand-authored file.
@Suite("Phase-3 gate snapshots")
struct SnapshotP3Tests {

    /// The LibreOffice-exported gate files: three EMF+ comment records (the
    /// vestigial dual-mode shell, no EMF+ drawing) plus EOF. NOTHING else may
    /// be skipped — the full-canvas INTERSECTCLIPRECT, every FILLPATH bracket,
    /// and every geometry record are honoured.
    private static let exportedLog: [EMFRenderLog.Entry] = [
        .unimplementedRecord(type: 70, count: 3),
        .unimplementedRecord(type: 14, count: 1),
    ]

    /// The hand-authored file has no EMF+ shell: EOF is the only skip. Its pen
    /// STROKING, dashed pen, and STROKEANDFILLPATH bracket are all honoured.
    private static let handmadeLog: [EMFRenderLog.Entry] = [
        .unimplementedRecord(type: 14, count: 1),
    ]

    private static func verify(
        _ name: String,
        width: Int,
        height: Int,
        expectedLog: [EMFRenderLog.Entry]
    ) throws {
        let file = try parseCorpusFile("\(name).emf")
        let (image, log) = try #require(
            EMFRenderer.makeImage(file, scale: 1),
            "makeImage returned nil for \(name)"
        )
        #expect(image.width == width)
        #expect(image.height == height)
        // The coverage pin: exactly the expected skips, nothing else.
        #expect(log.entries == expectedLog, "unexpected render log for \(name): \(log.entries)")

        let failure = SnapshotComparator.verify(image, baselineNamed: name)
        #expect(failure == nil, Comment(rawValue: failure ?? ""))
    }

    @Test("gate-p3-shapes: filled/hollow rects + ellipse + diagonal line via path brackets")
    func shapes() throws {
        try Self.verify("gate-p3-shapes", width: 373, height: 273, expectedLog: Self.exportedLog)
    }

    @Test("gate-p3-curves: bezier S-curve + rounded rect via path brackets")
    func curves() throws {
        try Self.verify("gate-p3-curves", width: 373, height: 273, expectedLog: Self.exportedLog)
    }

    @Test("handmade-strokes-paths: stroked polyline + dashed box + filled/stroked triangle + bezier")
    func handmade() throws {
        try Self.verify("handmade-strokes-paths", width: 400, height: 300, expectedLog: Self.handmadeLog)
    }
}
