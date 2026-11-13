import EMFEdit
import EMFParse
import EMFWrite
import Foundation
import Testing

// X1b item 2: the clean-up & compatibility report. A hand-built EMF carrying one of each
// redundancy kind (an unused pen, a dangling delete, a repeated state set, an empty
// SaveDC/RestoreDC pair and an EMF+ comment) is reported with the right counts; the
// optimised copy re-parses, is smaller, and renders equivalent; the compatible copy has
// no EMF+ records and renders equivalent.

// MARK: - Byte-fixture builder

private enum EMFFixture {
    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
    static func lei32(_ v: Int32) -> [UInt8] { le32(UInt32(bitPattern: v)) }
    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    /// Assembles a record: type + size(8 + body) + body (body length must be 4-aligned).
    static func record(_ type: UInt32, _ body: [UInt8]) -> [UInt8] {
        let size = UInt32(8 + body.count)
        return le32(type) + le32(size) + body
    }

    static func header() -> [UInt8] {
        var h: [UInt8] = []
        h += le32(1)                                  // iType
        h += le32(88)                                 // nSize
        h += lei32(0) + lei32(0) + lei32(100) + lei32(100)   // rclBounds
        h += lei32(0) + lei32(0) + lei32(2645) + lei32(2645) // rclFrame (0.01mm)
        h += le32(0x464D4520)                         // dSignature " EMF"
        h += le32(0x00010000)                         // nVersion
        h += le32(0)                                  // nBytes (patched)
        h += le32(0)                                  // nRecords (patched)
        h += le16(8)                                  // nHandles
        h += le16(0)                                  // sReserved
        h += le32(0)                                  // nDescription
        h += le32(0)                                  // offDescription
        h += le32(0)                                  // nPalEntries
        h += le32(100) + le32(100)                    // szlDevice
        h += le32(26) + le32(26)                      // szlMillimeters
        return h
    }

    static func colorRef(r: UInt8, g: UInt8, b: UInt8) -> [UInt8] { [r, g, b, 0] }

    /// The fixture EMF. Record order (after the header):
    /// 1 CreateBrush, 2 SelectObject, 3 Rectangle, 4 SaveDC, 5 RestoreDC,
    /// 6 CreatePen(unused), 7 SetTextColor, 8 SetTextColor(redundant),
    /// 9 DeleteObject(dangling), 10 Comment EMF+, 11 EOF.
    static func build() -> Data {
        var records: [[UInt8]] = []
        records.append(header())
        records.append(record(39, le32(0) + le32(0) + colorRef(r: 255, g: 0, b: 0) + le32(0)))         // CreateBrushIndirect ih=0 solid red
        records.append(record(37, le32(0)))                                                            // SelectObject ih=0
        records.append(record(43, lei32(0) + lei32(0) + lei32(80) + lei32(80)))                        // Rectangle
        records.append(record(33, []))                                                                 // SaveDC
        records.append(record(34, lei32(-1)))                                                          // RestoreDC
        records.append(record(38, le32(3) + le32(0) + lei32(1) + lei32(0) + colorRef(r: 0, g: 0, b: 0))) // CreatePen ih=3 (unused)
        records.append(record(24, colorRef(r: 0, g: 0, b: 0)))                                         // SetTextColor black
        records.append(record(24, colorRef(r: 0, g: 0, b: 0)))                                         // SetTextColor black (redundant)
        records.append(record(40, le32(9)))                                                            // DeleteObject ih=9 (dangling)
        records.append(record(70, le32(8) + le32(0x2B464D45) + le32(0)))                               // Comment EMF+
        records.append(record(14, le32(0) + le32(0) + le32(20)))                                       // EOF

        var bytes = records.flatMap { $0 }
        patch(&bytes, at: 48, le32(UInt32(bytes.count)))      // nBytes
        patch(&bytes, at: 52, le32(UInt32(records.count)))    // nRecords
        return Data(bytes)
    }

    private static func patch(_ bytes: inout [UInt8], at offset: Int, _ value: [UInt8]) {
        for (i, b) in value.enumerated() { bytes[offset + i] = b }
    }
}

@Suite struct DrawingCleanupTests {

    private func count(_ report: DrawingCleanup, _ kind: DrawingCleanup.Kind) -> Int {
        report.items.first { $0.kind == kind }?.count ?? 0
    }

    // MARK: - Each redundancy kind is reported

    @Test
    func reportsEachRedundancyKind() {
        let report = DrawingCleanup(data: EMFFixture.build())
        #expect(count(report, .unusedObject) == 1)
        #expect(count(report, .unusedDelete) == 1)
        #expect(count(report, .redundantStateSet) == 1)
        #expect(count(report, .emptySaveRestore) == 2)   // the SaveDC and the RestoreDC
        #expect(count(report, .emfPlusComment) == 1)
        #expect(report.hasEMFPlus)
        #expect(!report.isDual)
    }

    @Test
    func optimisableSetExcludesEMFPlusComment() {
        let report = DrawingCleanup(data: EMFFixture.build())
        // The optimised copy removes the redundant GDI records (5 of them) but not the
        // EMF+ comment, which belongs to the compatible copy.
        #expect(report.optimisableIndices.count == 5)
        #expect(report.optimisableBytes > 0)
        #expect(report.emfPlusCommentIndices.count == 1)
        #expect(report.optimisedByteCount < report.originalByteCount)
    }

    // MARK: - A clean file reports nothing

    @Test
    func optimisedOutputReparsesIsSmallerAndRendersEquivalent() throws {
        let data = EMFFixture.build()
        let report = DrawingCleanup(data: data)
        let optimised = try #require(report.optimisedCopy(of: data))

        // Re-parses with fewer records and fewer bytes.
        let reparsed = try EMFFile.parse(optimised)
        #expect(optimised.count < data.count)
        #expect(reparsed.records.count == (try EMFFile.parse(data)).records.count - 5)

        // A second cleanup of the optimised copy finds no more GDI optimisations.
        #expect(!DrawingCleanup(data: optimised).hasOptimisations)

        // Renders equivalent to the original.
        let guardResult = try #require(DrawingCleanupGuard.compareRenders(original: data, candidate: optimised))
        #expect(guardResult.equivalent)
    }

    // MARK: - Compatible copy

    @Test
    func compatibleCopyHasNoEMFPlusAndRendersEquivalent() throws {
        let data = EMFFixture.build()
        let report = DrawingCleanup(data: data)
        let compatible = try #require(report.compatibleCopy(of: data))

        // No EMF+ comment remains.
        let after = DrawingCleanup(data: compatible)
        #expect(!after.hasEMFPlus)
        #expect(after.emfPlusCommentIndices.isEmpty)
        #expect(compatible.count < data.count)

        // The GDI drawing still renders equivalent.
        let guardResult = try #require(DrawingCleanupGuard.compareRenders(original: data, candidate: compatible))
        #expect(guardResult.equivalent)
    }

    // MARK: - Pruner keeps structural records

    @Test
    func prunerNeverDropsHeaderOrEOF() throws {
        let data = EMFFixture.build()
        let file = try EMFFile.parse(data)
        // Ask to drop everything, including the header and EOF.
        let all = Set(file.records.indices)
        let pruned = try EMFRecordPruner.rewrite(data: data, file: file, dropping: all)
        let reparsed = try EMFFile.parse(pruned)
        // Only the header and EOF survive.
        #expect(reparsed.records.count == 2)
        #expect(reparsed.records.first?.type == 1)
        #expect(reparsed.records.last?.type == 14)
    }
}
