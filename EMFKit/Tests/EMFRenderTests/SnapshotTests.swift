import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// Phase-2 gate: the three committed corpus files render recognisably and
/// match their accepted baselines, and their render logs contain EXACTLY the
/// expected entries — pinning full phase-2 coverage of every other record in
/// these files.
@Suite("Phase-2 gate snapshots")
struct SnapshotTests {

    /// Every gate file carries the same LibreOffice shell: two EMF+ comment
    /// records up front and one before EOF (type 70, unimplemented by design
    /// — EMF+ is v2 scope), one full-canvas EMR_INTERSECTCLIPRECT (clipping
    /// deferred to phase 3), and the EMR_EOF terminator (type 14). NOTHING
    /// else may be skipped or approximated.
    private static let expectedGateLog: [EMFRenderLog.Entry] = [
        .unimplementedRecord(type: 70, count: 3),
        .clipDeferred,
        .unimplementedRecord(type: 14, count: 1),
    ]

    private static func renderGateFile(_ name: String) throws -> (CGImage, EMFRenderLog) {
        let file = try parseCorpusFile("\(name).emf")
        return try #require(
            EMFRenderer.makeImage(file, scale: 1),
            "makeImage returned nil for \(name)"
        )
    }

    private static func verifyGateFile(_ name: String) throws {
        let (image, log) = try Self.renderGateFile(name)

        // Canvas = header bounds (0,0)-(372,272), inclusive-inclusive.
        #expect(image.width == 373)
        #expect(image.height == 273)

        // The coverage pin: exactly the expected skips, nothing else.
        #expect(
            log.entries == Self.expectedGateLog,
            "unexpected render log for \(name): \(log.entries)"
        )

        let failure = SnapshotComparator.verify(image, baselineNamed: name)
        #expect(failure == nil, Comment(rawValue: failure ?? ""))
    }

    @Test("gate-p2-star: ten-point star + zigzag")
    func star() throws {
        try Self.verifyGateFile("gate-p2-star")
    }

    @Test("gate-p2-house: house scene with roof, door, windows, sun")
    func house() throws {
        try Self.verifyGateFile("gate-p2-house")
    }

    @Test("gate-p2-triangles: three overlapping triangles + W polyline")
    func triangles() throws {
        try Self.verifyGateFile("gate-p2-triangles")
    }
}
