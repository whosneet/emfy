import Foundation
import Testing
import EMFParse
import EMFWrite

/// The from-scratch builder (E0a entry (b), the E1 scene-export surface): a
/// handful of appended records become a complete, parseable EMF whose header
/// accounting is computed, and the re-emit path reproduces it byte-for-byte.
@Suite("Document builder (create from scratch)")
struct BuilderTests {

    private func makeScene() throws -> Data {
        let builder = EMFDocumentBuilder(
            bounds: RectL(left: 0, top: 0, right: 100, bottom: 100),
            frame: RectL(left: 0, top: 0, right: 2000, bottom: 2000),
            device: SizeL(cx: 100, cy: 100),
            millimeters: SizeL(cx: 20, cy: 20),
            description: "Emfy builder test"
        )
        try builder.append(.setMapMode(.text))
        let pen = try builder.allocateObjectHandle()   // 1
        try builder.append(.createPen(CreatePenPayload(
            ihPen: pen, style: 0, width: PointL(x: 1, y: 0),
            color: ColorRef(red: 0, green: 0, blue: 0))))
        try builder.append(.selectObject(.table(index: pen)))
        try builder.append(.moveToEx(point: PointL(x: 10, y: 10)))
        try builder.append(.lineTo(point: PointL(x: 90, y: 90)))
        try builder.append(.deleteObject(.table(index: pen)))
        return try builder.finish()
    }

    @Test func builtFileParsesWithCorrectHeader() throws {
        let data = try makeScene()
        let file = try EMFFile.parse(data)

        #expect(file.diagnostics.isEmpty)
        #expect(file.header.bounds == RectL(left: 0, top: 0, right: 100, bottom: 100))
        #expect(file.header.frame == RectL(left: 0, top: 0, right: 2000, bottom: 2000))
        #expect(file.header.device == SizeL(cx: 100, cy: 100))
        #expect(file.header.millimeters == SizeL(cx: 20, cy: 20))
        #expect(file.header.description == "Emfy builder test")
        #expect(file.header.variant == .extension2)

        // Header (1) + 6 appended + EOF (1).
        #expect(file.records.count == 8)
        #expect(Int(file.header.records) == 8)
        // Pen used index 1, so the handle table size is 2.
        #expect(file.header.handles == 2)
        // Bytes is the real file length.
        #expect(file.header.bytes == UInt32(data.count))
        // Trailer is EMR_EOF.
        #expect(file.records.last?.type == 14)
    }

    @Test func builtRecordsDecodeToWhatWasAppended() throws {
        let data = try makeScene()
        let file = try EMFFile.parse(data)
        let payloads = file.records.dropFirst().dropLast().map { file.payload(of: $0) }

        #expect(payloads.count == 6)
        if case .setMapMode(.text) = payloads[0] {} else { Issue.record("record 0: \(payloads[0])") }
        if case .createPen(let p) = payloads[1] { #expect(p.ihPen == 1) } else { Issue.record("record 1") }
        if case .selectObject(.table(1)) = payloads[2] {} else { Issue.record("record 2") }
        if case .moveToEx(PointL(x: 10, y: 10)) = payloads[3] {} else { Issue.record("record 3") }
        if case .lineTo(PointL(x: 90, y: 90)) = payloads[4] {} else { Issue.record("record 4") }
        if case .deleteObject(.table(1)) = payloads[5] {} else { Issue.record("record 5") }
    }

    /// A builder-made file is already in canonical form, so re-emitting it is a
    /// byte-for-byte identity — the writer's two entry points agree.
    @Test func reEmitOfBuiltFileIsByteIdentical() throws {
        let data = try makeScene()
        let file = try EMFFile.parse(data)
        let reEmitted = try EMFDocumentWriter.reEmit(file, source: data)
        #expect([UInt8](reEmitted) == [UInt8](data))
    }

    @Test func emptyDocumentIsValid() throws {
        let builder = EMFDocumentBuilder(
            bounds: RectL(left: 0, top: 0, right: 10, bottom: 10),
            frame: RectL(left: 0, top: 0, right: 100, bottom: 100),
            device: SizeL(cx: 10, cy: 10),
            millimeters: SizeL(cx: 1, cy: 1)
        )
        let data = try builder.finish()
        let file = try EMFFile.parse(data)
        #expect(file.records.count == 2)         // header + EOF
        #expect(file.header.handles == 1)        // reserved slot only
        #expect(file.header.description == nil)
        #expect(file.header.bytes == UInt32(data.count))
    }
}
