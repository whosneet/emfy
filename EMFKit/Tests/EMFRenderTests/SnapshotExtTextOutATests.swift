// Snapshot baselines are macOS-only (CoreText text rasterisation is platform-
// specific); gated like the phase gates.
#if os(macOS)
import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// R1 render coverage for EMR_EXTTEXTOUTA (83) — the highest-volume skipped
/// record (26,931 across the corpus). It routes through the same CoreText path
/// as EMR_EXTTEXTOUTW after the ANSI string is decoded at parse time, so the
/// snapshot pins legible ANSI text including a high Windows-1252 byte.
@Suite("EXTTEXTOUTA render snapshot")
struct SnapshotExtTextOutATests {

    @Test("ANSI text (with a CP1252 accented byte) renders legibly")
    func ansiText() throws {
        var f = RenderFixture()
        f.bounds = (0, 0, 239, 79)
        f.setTextColor(r: 0, g: 0, b: 0)
        f.extCreateFontIndirectW(index: 1, height: -36, faceName: "Helvetica")
        f.selectObject(1)
        // "Café ANSI" — the é is a single Windows-1252 byte 0xE9.
        f.extTextOutA(reference: (x: 12, y: 20),
                      ansiBytes: [0x43, 0x61, 0x66, 0xE9, 0x20, 0x41, 0x4E, 0x53, 0x49]) // "Café ANSI"
        let file = try f.parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file, scale: 1), "makeImage returned nil")
        #expect(image.width == 240)
        #expect(image.height == 80)
        // Coverage pin: only EOF is skipped — the ANSI text record is honoured.
        #expect(log.entries == [.unimplementedRecord(type: 14, count: 1)],
                "unexpected render log: \(log.entries)")

        let failure = SnapshotComparator.verify(image, baselineNamed: "r1-exttextouta")
        #expect(failure == nil, Comment(rawValue: failure ?? ""))
    }
}
#endif
