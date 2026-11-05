import Foundation
import Testing
import EMFParse
import EMFWrite

/// Re-emitting a parsed hostile file must return a typed error or valid output —
/// never trap (primer §8, the write-side of the parse path's discipline).
@Suite("Hostile re-emit")
struct HostileReEmitTests {

    /// Wraps hand-built records in a minimal EMF (walker-valid framing; the
    /// payloads inside may be hostile).
    private func wrapFile(_ records: [[UInt8]]) -> Data {
        var f = LE()
        let bodyLen = records.reduce(0) { $0 + $1.count } + 20   // + EOF
        f.raw(LE.header108(records: UInt32(records.count + 2), bytes: UInt32(108 + bodyLen)))
        for r in records { f.raw(r) }
        f.raw(LE.eof())
        return Data(f.bytes)
    }

    @Test func lyingPointCountReEmitsViaPassthrough() throws {
        // nSize 28 but Count claims 1,000,000 points → decoder .malformed; the
        // writer must pass the original bytes through, never allocate on the lie.
        let poly = LE.record(4, { var b = LE()
            b.i32(0); b.i32(0); b.i32(100); b.i32(100)   // Bounds
            b.u32(1_000_000)                             // Count (impossible)
            return b.bytes }())
        let data = wrapFile([poly])
        let file = try EMFFile.parse(data)
        // Confirm it really decoded malformed.
        #expect({ if case .malformed = file.payload(of: file.records[1]) { return true }; return false }())

        let written = try EMFDocumentWriter.reEmit(file, source: data)   // must not trap
        let file2 = try EMFFile.parse(written)
        #expect(recordStreamEqual(file, file2))
    }

    @Test func absurdObjectIndexIsTypedError() throws {
        // CreatePen with ihPen = 0x00010000 → handle table would exceed UInt16.
        let pen = LE.record(38, { var b = LE()
            b.u32(0x0001_0000)                           // ihPen (65536)
            b.u32(0); b.i32(1); b.i32(0); b.raw([0, 0, 0, 0])
            return b.bytes }())
        let data = wrapFile([pen])
        let file = try EMFFile.parse(data)
        #expect(throws: EMFWriteError.self) {
            _ = try EMFDocumentWriter.reEmit(file, source: data)
        }
    }

    @Test func extremeBoundsReEmitCleanly() throws {
        let rect = LE.record(43, { var b = LE()
            b.i32(.min); b.i32(.min); b.i32(.max); b.i32(.max)
            return b.bytes }())
        let data = wrapFile([rect])
        let file = try EMFFile.parse(data)
        let written = try EMFDocumentWriter.reEmit(file, source: data)   // must not trap
        let file2 = try EMFFile.parse(written)
        #expect(recordStreamEqual(file, file2))
        #expect(headerPreserved(file, file2))
    }

    @Test func truncatedSourceIsTypedError() throws {
        // A source too short to contain the records the EMFFile claims.
        let rect = LE.record(43, { var b = LE()
            b.i32(0); b.i32(0); b.i32(5); b.i32(5); return b.bytes }())
        let data = wrapFile([rect])
        let file = try EMFFile.parse(data)
        #expect(throws: EMFWriteError.self) {
            _ = try EMFDocumentWriter.reEmit(file, source: Data(data.prefix(20)))
        }
    }
}
