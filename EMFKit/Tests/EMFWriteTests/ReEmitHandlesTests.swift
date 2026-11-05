import Foundation
import Testing
import EMFParse
import EMFWrite
import WMFParse

/// Re-emit RAISES an under-declared object-table size but never LOWERS an
/// over-declared one (EMF header `Handles`, WMF header `NumberOfObjects`). The
/// table size is a capacity, not an exact count: shrinking gains nothing, and if
/// the simulation ever missed an object-creating record it would under-declare
/// and a stricter reader could fault on an out-of-range index.
@Suite("Re-emit: object-table size is raised, never lowered")
struct ReEmitHandlesTests {

    static func patched(_ data: Data, u16At offset: Int, _ value: UInt16) -> Data {
        var bytes = [UInt8](data)
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        return Data(bytes)
    }

    // MARK: - EMF (header Handles at record offset 56)

    static let emfHandlesOffset = 56

    /// A from-scratch EMF that uses object handles 1 and 2 (so the computed table
    /// size is 3).
    static func twoHandleEMF() throws -> Data {
        let b = EMFDocumentBuilder(
            bounds: RectL(left: 0, top: 0, right: 10, bottom: 10),
            frame: RectL(left: 0, top: 0, right: 1000, bottom: 1000),
            device: SizeL(cx: 11, cy: 11), millimeters: SizeL(cx: 3, cy: 3))
        let h1 = try b.allocateObjectHandle()
        let h2 = try b.allocateObjectHandle()
        try b.append(.createBrushIndirect(CreateBrushPayload(ihBrush: h1, style: 0, color: ColorRef(red: 1, green: 2, blue: 3), hatch: 0)))
        try b.append(.createBrushIndirect(CreateBrushPayload(ihBrush: h2, style: 0, color: ColorRef(red: 4, green: 5, blue: 6), hatch: 0)))
        try b.append(.selectObject(.table(index: h1)))
        try b.append(.selectObject(.table(index: h2)))
        return try b.finish()
    }

    @Test func emfOverDeclaredHandlesKept() throws {
        // Declared 50, computed 3 → re-emit keeps 50 and is byte-identical.
        let source = Self.patched(try Self.twoHandleEMF(), u16At: Self.emfHandlesOffset, 50)
        let file = try EMFFile.parse(source)
        #expect(file.header.handles == 50)
        let written = try EMFDocumentWriter.reEmit(file, source: source)
        let file2 = try EMFFile.parse(written)
        #expect(file2.header.handles == 50, "over-declared Handles was lowered to \(file2.header.handles)")
        #expect([UInt8](written) == [UInt8](source), "re-emit changed a byte other than the kept Handles")
    }

    @Test func emfUnderDeclaredHandlesRaised() throws {
        // Declared 1, computed 3 → re-emit raises to 3.
        let source = Self.patched(try Self.twoHandleEMF(), u16At: Self.emfHandlesOffset, 1)
        let file = try EMFFile.parse(source)
        #expect(file.header.handles == 1)
        let written = try EMFDocumentWriter.reEmit(file, source: source)
        let file2 = try EMFFile.parse(written)
        #expect(file2.header.handles == 3, "under-declared Handles was not raised: \(file2.header.handles)")
    }

    @Test func dualEMFReEmitsByteIdentical() throws {
        // handmade-emfplus-dual.emf differed only in Handles under E0a; with the
        // no-lower rule it now re-emits byte-identical.
        let emf = try corpusData("handmade-emfplus-dual.emf")
        let file = try EMFFile.parse(emf)
        let written = try EMFDocumentWriter.reEmit(file, source: emf)
        #expect([UInt8](written) == [UInt8](emf), "handmade-emfplus-dual.emf should re-emit byte-identical")
    }

    // MARK: - WMF (header NumberOfObjects at placeable 22 + 10 = 32)

    static let wmfNumberOfObjectsOffset = 32

    /// A from-scratch placeable WMF holding two objects at once (computed
    /// NumberOfObjects = 2).
    static func twoObjectWMF() throws -> Data {
        let b = WMFDocumentBuilder(boundingBox: WMFRect16(left: 0, top: 0, right: 10, bottom: 10))
        _ = try b.append(.createBrushIndirect(style: 0, color: ColorRef(red: 1, green: 2, blue: 3), hatch: 0))
        _ = try b.append(.createPenIndirect(style: 0, width: 1, color: ColorRef(red: 0, green: 0, blue: 0)))
        return try b.finish()
    }

    @Test func wmfOverDeclaredObjectsKept() throws {
        // Declared 20, computed 2 → re-emit keeps 20 and is byte-identical.
        let source = Self.patched(try Self.twoObjectWMF(), u16At: Self.wmfNumberOfObjectsOffset, 20)
        let file = try WMFFile.parse(source)
        #expect(file.header.numberOfObjects == 20)
        let written = try WMFDocumentWriter.reEmit(file, source: source)
        let file2 = try WMFFile.parse(written)
        #expect(file2.header.numberOfObjects == 20, "over-declared NumberOfObjects was lowered to \(file2.header.numberOfObjects)")
        #expect([UInt8](written) == [UInt8](source), "re-emit changed a byte other than the kept NumberOfObjects")
    }

    @Test func wmfUnderDeclaredObjectsRaised() throws {
        // Declared 1, computed 2 → re-emit raises to 2.
        let source = Self.patched(try Self.twoObjectWMF(), u16At: Self.wmfNumberOfObjectsOffset, 1)
        let file = try WMFFile.parse(source)
        #expect(file.header.numberOfObjects == 1)
        let written = try WMFDocumentWriter.reEmit(file, source: source)
        let file2 = try WMFFile.parse(written)
        #expect(file2.header.numberOfObjects == 2, "under-declared NumberOfObjects was not raised: \(file2.header.numberOfObjects)")
    }
}
