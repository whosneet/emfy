import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// Phase-4 gate: the committed text and bitmap corpus files render to their
/// accepted baselines, AND their render logs contain EXACTLY the expected
/// entries — the phase-4 coverage pin. Every font, text run, and DIB is fully
/// honoured; the only skips are the LibreOffice EMF+ comment shell (type 70)
/// and the EMR_EOF terminator (type 14), plus — on the text file — the stock
/// OEM_FIXED_FONT the exporter selects to unbind each table font before
/// deleting it (a real, correct log entry, coalesced).
@Suite("Phase-4 gate snapshots")
struct SnapshotP4Tests {

    /// gate-p4-text: three fonts + three EXTTEXTOUTW runs. Arial and Times New
    /// Roman resolve directly on macOS, so there is NO fontSubstituted entry.
    /// LibreOffice selects OEM_FIXED_FONT (0x8000000A) twice as a cleanup step
    /// before DELETEOBJECT — resolved to the system font and logged (coalesced).
    private static let textLog: [EMFRenderLog.Entry] = [
        .unimplementedRecord(type: 70, count: 3),
        .stockFontUsed(rawValue: 0x8000_000A, count: 2),
        .unimplementedRecord(type: 14, count: 1),
    ]

    /// gate-p4-image: one STRETCHDIBITS (SRCCOPY 24-bit) + one POLYGON. All
    /// SETROP2 are R2_COPYPEN (silent). Only the EMF+ shell + EOF are skipped.
    private static let imageLog: [EMFRenderLog.Entry] = [
        .unimplementedRecord(type: 70, count: 3),
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
        #expect(log.entries == expectedLog, "unexpected render log for \(name): \(log.entries)")

        let failure = SnapshotComparator.verify(image, baselineNamed: name)
        #expect(failure == nil, Comment(rawValue: failure ?? ""))
    }

    @Test("gate-p4-text: three legible upright runs — dark 28pt, blue italic 22pt, dark-red bold 18pt")
    func text() throws {
        try Self.verify("gate-p4-text", width: 377, height: 177, expectedLog: Self.textLog)
    }

    @Test("gate-p4-image: crisp red/blue checkerboard at 240×240 + green square")
    func image() throws {
        try Self.verify("gate-p4-image", width: 373, height: 273, expectedLog: Self.imageLog)
    }
}
