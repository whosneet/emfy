import Foundation
import Testing
import EMFParse
import EMFWrite

/// The EMF+ write path returns typed errors (never traps) on hostile or lossy
/// inputs — the write-side of the parse path's §8 discipline.
@Suite("EMF+ hostile write")
struct EMFPlusHostileWriteTests {

    /// Allocating past the 64-slot EMF+ object table is a typed error.
    @Test func objectTableOverflowThrows() throws {
        let b = EMFPlusDualDocumentBuilder(
            bounds: RectL(left: 0, top: 0, right: 9, bottom: 9),
            frame: RectL(left: 0, top: 0, right: 264, bottom: 264),
            device: SizeL(cx: 10, cy: 10), millimeters: SizeL(cx: 3, cy: 3))
        let brush = EMFPlusBrush(version: 1, brushType: .solid, data: .solid(EMFPlusARGB(blue: 0, green: 0, red: 0, alpha: 255)))
        for _ in 0 ..< 64 { _ = try b.addObject(.brush(brush)) }   // ids 0…63 fill the table
        #expect(throws: EMFWriteError.self) { _ = try b.addObject(.brush(brush)) }
    }

    /// A malformed decoded object has no payload form — a typed error.
    @Test func malformedObjectEncodeThrows() {
        #expect(throws: EMFWriteError.self) {
            _ = try EMFPlusObjectEncoder.encode(.malformed(type: .brush, reason: .truncated(field: "x")))
        }
    }

    /// A path gradient that only decoded partially (`undecodedTail`) is reported
    /// not faithfully encodable and throws rather than guess the lost bytes.
    @Test func partialPathGradientNotEncodable() throws {
        var p = LE()
        p.u32(1); p.u32(3)                              // Version, BrushType path-gradient
        p.u32(0x0000_0001)                              // flags: BrushDataPath
        p.i32(1)                                        // WrapMode
        p.u32(0xFF00_0000)                              // CenterColor
        p.f32(5); p.f32(5)                              // CenterPoint
        p.u32(0)                                        // SurroundingColorCount
        p.i32(100)                                      // boundary path size (lies)
        p.raw([1, 2, 3, 4])                             // only 4 trailing bytes → partial decode
        let value = EMFPlusObjectDefinition(objectID: 0, objectType: .brush, data: Data(p.bytes)).decodedValue()
        #expect(!EMFPlusObjectEncoder.isFaithfullyEncodable(value))
        #expect(throws: EMFWriteError.self) { _ = try EMFPlusObjectEncoder.encode(value) }
    }

    /// A compressed (i16) path whose point is not an integer in the Int16 range is
    /// reported not faithfully encodable and throws — a from-scratch mistake a
    /// decoder never produces.
    @Test func nonIntegralCompressedPathThrows() {
        let path = EMFPlusPath(
            version: 1, pointCount: 1, flags: 0x4000 /* compressed */,
            points: [EMFPlusPointF(x: 1.5, y: 70000)], pointTypes: [0x00])
        #expect(!EMFPlusObjectEncoder.isFaithfullyEncodable(.path(path)))
        #expect(throws: EMFWriteError.self) { _ = try EMFPlusObjectEncoder.encode(.path(path)) }
    }

    /// A huge drawString encodes without trapping — the length field clamps and
    /// the data is produced.
    @Test func hugeStringEncodesWithoutTrap() {
        let text = String(repeating: "A", count: 100_000)
        let framed = EMFPlusRecordPayload
            .drawString(fontID: 0, brush: .color(EMFPlusARGB(blue: 0, green: 0, red: 0, alpha: 255)),
                        formatID: 0, layoutRect: EMFPlusRectF(x: 0, y: 0, width: 1, height: 1), text: text)
            .framed()
        // 12-byte header + brushId(4) + formatId(4) + length(4) + rect(16) + 2×100000.
        #expect(framed.count == 40 + 200_000)
    }

    /// Repackaging a file whose EMF+ stream is truncated must not trap — it returns
    /// valid EMF bytes (worst case, an empty or partial EMF+ stream), never crashes.
    @Test func repackageTruncatedEMFPlusDoesNotTrap() throws {
        // An EMR_COMMENT_EMFPLUS whose EMF+ record claims a Size past the comment.
        var comment = LE()
        comment.u32(70)                                 // Type EMR_COMMENT
        comment.u32(16 + 12)                            // Size
        comment.u32(4 + 12)                             // DataSize = id + one EMF+ record header
        comment.u32(0x2B46_4D45)                        // "EMF+"
        comment.u16(0x4001); comment.u16(0x0001)        // EmfPlusHeader, Dual
        comment.u32(0x7FFF_FFF0)                        // Size: absurd (truncated stream)
        comment.u32(0x10)                               // DataSize
        var fixture = LE()
        let total = 108 + comment.count + 20
        fixture.raw(LE.header108(records: 3, bytes: UInt32(total)))
        fixture.raw(comment.bytes)
        fixture.raw(LE.eof())
        let file = try EMFFile.parse(Data(fixture.bytes))
        let out = try EMFDocumentWriter.reEmit(file, source: Data(fixture.bytes), repackageEMFPlus: true)   // must not trap
        _ = try EMFFile.parse(out)   // and must re-parse
    }
}
