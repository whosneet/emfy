import CoreGraphics
import EMFParse
import EMFWrite
import Foundation
import WMFParse

/// The output format `SceneExporter` writes.
public enum ExportFormat: Sendable, Equatable {
    /// Enhanced Metafile (EMF+ with a GDI fallback once E1b2 lands; GDI-only here).
    case emf
    /// Gzip-compressed EMF (.emz).
    case emz
    /// Windows Metafile (placeable).
    case wmf
    /// Gzip-compressed WMF (.wmz).
    case wmz

    /// EMF or EMZ.
    public var isEMFFamily: Bool { self == .emf || self == .emz }
    /// Whether the result is gzip-wrapped.
    public var isCompressed: Bool { self == .emz || self == .wmz }
}

/// A fidelity loss the export could not avoid — the honest record of what a GDI
/// or WMF container cannot hold (docs/v3-plan §11.1). E1b2 writes alpha and
/// gradients as EMF+ instead.
public enum ExportWarning: Sendable, Equatable {
    /// Sub-1 opacity was dropped (GDI has no alpha). `elementID` names the element.
    case opacityDropped(elementID: Int)
    /// A gradient fill was approximated by its representative solid colour.
    case gradientFlattened(elementID: Int)
    /// A text run carried characters outside Latin-1, lossy in a WMF 8-bit string.
    case textNotLatin1(elementID: Int)
    /// An image could not be re-encoded (no retained/supported DIB) and was dropped.
    case imageDropped(elementID: Int)
    /// The element's exact kind could not be re-emitted (a rotated rect, or a
    /// kind whose parameters the scene does not retain — ROUNDRECT, ARC/PIE/CHORD,
    /// or a curve in WMF), so it was written as a path bracket / flattened polygon.
    case kindFallback(elementID: Int, kind: ElementKind)
    /// A WMF whose drawing comes from an embedded EMF was edited: the edit lands
    /// in the re-embedded EMF, but the plain WMF records are unchanged, so a
    /// WMF-only reader shows the ORIGINAL drawing.
    case embeddedEMFOnly
}

/// The bytes a `SceneExporter` produced, plus any fidelity warnings.
public struct ExportResult: Sendable, Equatable {
    public let data: Data
    public let warnings: [ExportWarning]

    public init(data: Data, warnings: [ExportWarning]) {
        self.data = data
        self.warnings = warnings
    }
}

/// Why an export failed (always typed — never a trap, §8).
public enum SceneExportError: Error, Sendable, Equatable {
    /// The format cannot represent this scene in E1b1: a cross-container export
    /// (EMF scene → WMF, or WMF scene → EMF), or editing an EMF+ file (both land
    /// in E1b2). Carries a short reason.
    case unsupported(reason: String)
    /// The retained source bytes no longer parse (should not happen for an
    /// imported scene; defensive).
    case unreadableSource
    /// The EMF serialiser refused the synthesised document.
    case emfWriteFailed(EMFWriteError)
    /// The WMF serialiser refused the synthesised document (e.g. a device
    /// coordinate overflowed the 16-bit field).
    case wmfWriteFailed(WMFWriteError)
}

/// Writes an edited `Scene` back to a metafile (E1b1: GDI- and WMF-sourced
/// scenes). An UNCHANGED scene re-emits its source verbatim (byte-identical to
/// E0). An edited GDI EMF (and an edited plain WMF) is written as a lossless
/// OVERLAY — every unedited record is kept, only edited/new elements are
/// synthesised in place: in the EMF's device space for EMF, in the WMF's own
/// logical space for WMF (its scene provenance maps through the translated
/// program's per-payload source index back to source WMF records). A WMF whose
/// scene came from an embedded EMF overlays that EMF and re-embeds it.
/// Cross-container conversion and editing EMF+ are E1b2 (a typed `unsupported`
/// error here).
public enum SceneExporter {

    /// Record types that carry an object-table handle in their first body field
    /// ([MS-EMF] §2.3.7/§2.3.8), used to place synthesised objects above the
    /// file's highest handle. Mirrors `EMFDocumentWriter.handleFieldTypes`.
    private static let handleFieldTypes: Set<UInt32> = [37, 38, 39, 40, 49, 82, 93, 94, 95, 99, 122]

    /// EMR_EOF type id ([MS-EMF] §2.1.1).
    private static let eofType: UInt32 = 14
    /// The 20-byte canonical EMR_EOF ([MS-EMF] §2.3.4.1): Type 14, Size 20,
    /// nPalEntries 0, offPalEntries 0x10, SizeLast 20 — the terminator GDI writes
    /// and `EMFDocumentWriter.encodeEOF` produces. Appended only when the source
    /// lacks an EOF (see `overlayEMF`).
    private static let canonicalEMFEOF: [UInt8] = [
        14, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0, 0x10, 0, 0, 0, 20, 0, 0, 0,
    ]

    public static func export(_ scene: Scene, as format: ExportFormat) throws(SceneExportError) -> ExportResult {
        let sourceIsEMF = scene.source.format == .emf
        guard sourceIsEMF == format.isEMFFamily else {
            throw .unsupported(reason: "cross-container export (EMF \u{2194} WMF) is not supported in E1b1")
        }

        if !isEdited(scene) {
            let data = try reEmitUnchanged(scene)
            return ExportResult(data: finalize(data, format), warnings: [])
        }

        if format.isEMFFamily {
            guard scene.source.renderPath != .emfPlus else {
                throw .unsupported(reason: "editing an EMF+ file is not supported in E1b1")
            }
            let file: EMFFile
            do { file = try EMFFile.parse(scene.source.data) } catch { throw .unreadableSource }
            let result: (Data, [ExportWarning])
            do { result = try overlayEMF(file, scene, source: scene.source.data) }
            catch { throw .emfWriteFailed(error) }
            return ExportResult(data: finalize(result.0, format), warnings: result.1)
        }
        let (data, warnings) = try exportEditedWMF(scene)
        return ExportResult(data: finalize(data, format), warnings: warnings)
    }

    // MARK: - Change detection

    /// A scene is edited when any element is marked edited, a new element was
    /// inserted (no provenance), or a source content record is no longer owned
    /// by any element (a deletion).
    static func isEdited(_ scene: Scene) -> Bool {
        var covered = Set<Int>()
        for element in scene.elements {
            if element.provenance.edited { return true }
            if element.provenance.sourceRecordIndices.isEmpty { return true }   // new
            covered.formUnion(element.provenance.sourceRecordIndices)
        }
        let content = scene.partition.drawing.union(scene.partition.passthrough)
        return covered != content
    }

    // MARK: - Unchanged: re-emit verbatim (E0)

    private static func reEmitUnchanged(_ scene: Scene) throws(SceneExportError) -> Data {
        switch scene.source.format {
        case .emf:
            let file: EMFFile
            do { file = try EMFFile.parse(scene.source.data) } catch { throw .unreadableSource }
            do { return try EMFDocumentWriter.reEmit(file, source: scene.source.data) }
            catch { throw .emfWriteFailed(error) }
        case .wmf, .placeableWMF:
            let file: WMFFile
            do { file = try WMFFile.parse(scene.source.data) } catch { throw .unreadableSource }
            do { return try WMFDocumentWriter.reEmit(file, source: scene.source.data) }
            catch { throw .wmfWriteFailed(error) }
        }
    }

    // MARK: - Edited GDI EMF: lossless overlay (original header preserved)

    /// The EMF overlay: every unedited record is kept byte-verbatim; an edited
    /// element's records are replaced in place by a synthesised kind-matched
    /// block; new elements are inserted at their z-position. The ORIGINAL header
    /// is preserved (only Bytes/Records/Handles patched, like `reEmit`), so
    /// pixel-format and extension fields survive.
    private static func overlayEMF(_ file: EMFFile, _ scene: Scene, source: Data) throws(EMFWriteError) -> (Data, [ExportWarning]) {
        guard !file.records.isEmpty else { throw .sourceRecordOutOfBounds(recordOffset: 0, recordSize: 0) }
        let bytes = [UInt8](source)
        var headerBytes = try rawOrThrow(bytes, file.records[0])

        var ownerByIndex: [Int: Element] = [:]
        for element in scene.elements where !element.provenance.sourceRecordIndices.isEmpty {
            for index in element.provenance.sourceRecordIndices { ownerByIndex[index] = element }
        }
        let content = scene.partition.drawing.union(scene.partition.passthrough)
        let firstContent = content.min()
        let baseHandle = maxTableIndex(file.records, bytes) + 1
        let insertions = planInsertions(scene)

        var body: [[UInt8]] = []
        var warnings: [ExportWarning] = []

        // Mirror reEmit: re-emit every record[1…] (the EOF keeps its position);
        // drop deleted elements, replace edited ones, insert new ones at z.
        for i in 1 ..< file.records.count {
            let record = file.records[i]
            if i == firstContent { try appendEMFBlocks(insertions.atStart, baseHandle, &body, &warnings) }

            if content.contains(i) {
                if let owner = ownerByIndex[i] {
                    if owner.provenance.edited {
                        if i == owner.provenance.sourceRecordIndices.max() {
                            try appendEMFBlocks([owner], baseHandle, &body, &warnings)
                        }
                    } else {
                        body.append(try rawOrThrow(bytes, record))
                    }
                }   // deleted → drop
            } else {
                body.append(try rawOrThrow(bytes, record))   // structural / state / EOF
            }
            if let after = insertions.afterRecord[i] { try appendEMFBlocks(after, baseHandle, &body, &warnings) }
        }
        if firstContent == nil { try appendEMFBlocks(insertions.atStart, baseHandle, &body, &warnings) }

        // Guarantee a terminating EMR_EOF. The lossless overlay keeps the source's
        // own EOF record in place (it is structural, re-emitted verbatim above), but
        // some real-world files are malformed and carry no EOF at all — an edited
        // file we rewrite must still be well-formed, exactly as the WMF overlay
        // always appends its META_EOF. (Unchanged exports go through reEmit and are
        // left byte-identical, EOF or not.)
        if file.records.last?.type != eofType { body.append(canonicalEMFEOF) }

        let bodyTotal = body.reduce(0) { $0 + $1.count }
        let totalBytes = headerBytes.count + bodyTotal
        guard totalBytes <= Int(UInt32.max) else { throw .fileTooLarge(byteLength: totalBytes) }
        let recordCount = UInt32(clamping: 1 + body.count)
        let computedHandles = try handleCount(body)
        let handles = max(file.header.handles, computedHandles)

        patchU32(&headerBytes, 48, UInt32(totalBytes))
        patchU32(&headerBytes, 52, recordCount)
        patchU16(&headerBytes, 56, handles)

        var out = [UInt8]()
        out.reserveCapacity(totalBytes)
        out.append(contentsOf: headerBytes)
        for chunk in body { out.append(contentsOf: chunk) }
        return (Data(out), warnings)
    }

    private static func appendEMFBlocks(_ elements: [Element], _ baseHandle: UInt32, _ body: inout [[UInt8]], _ warnings: inout [ExportWarning]) throws(EMFWriteError) {
        for element in elements where !element.hidden {
            for payload in SceneSynthesis.emfBlock(for: element, baseHandle: baseHandle, warnings: &warnings) {
                body.append([UInt8](try EMFRecordEncoder.encode(payload)))
            }
        }
    }

    // MARK: - Edited WMF

    private static func exportEditedWMF(_ scene: Scene) throws(SceneExportError) -> (Data, [ExportWarning]) {
        let wmf: WMFFile
        do { wmf = try WMFFile.parse(scene.source.data) } catch { throw .unreadableSource }
        do {
            if scene.source.renderPath == .gdi {
                return try overlayEmbeddedWMF(wmf, scene)
            }
            return try overlayWMF(wmf, scene)
        } catch let error as WMFWriteError {
            throw .wmfWriteFailed(error)
        } catch let error as EMFWriteError {
            throw .emfWriteFailed(error)
        } catch {
            throw .unreadableSource
        }
    }

    /// True WMF overlay (renderPath .wmf): element provenance maps through the
    /// translated program's per-payload source index back to source WMF records,
    /// so every unedited record is kept verbatim and an edited element is replaced
    /// in place by a block drawn in the file's own LOGICAL coordinate space (object
    /// slots modelled along the stream). Mirrors the EMF overlay.
    private static func overlayWMF(_ wmf: WMFFile, _ scene: Scene) throws -> (Data, [ExportWarning]) {
        let program = WMFTranslator.translate(wmf)
        let srcIndex = program.payloadSourceIndices
        let bytes = [UInt8](scene.source.data)
        let space = wmfLogicalSpace(program)

        func sources(of payloadIndices: [Int]) -> [Int] {
            payloadIndices.compactMap { $0 >= 0 && $0 < srcIndex.count && srcIndex[$0] >= 0 ? srcIndex[$0] : nil }
        }
        var ownerBySource: [Int: Element] = [:]
        var drawKeyOf: [Int: Int] = [:]   // element id → its last source WMF record
        for element in scene.elements where !element.provenance.sourceRecordIndices.isEmpty {
            let recs = sources(of: element.provenance.sourceRecordIndices)
            for s in recs { ownerBySource[s] = element }
            if let k = recs.max() { drawKeyOf[element.id] = k }
        }
        var contentSources = Set<Int>()
        for p in scene.partition.drawing.union(scene.partition.passthrough) where p < srcIndex.count && srcIndex[p] >= 0 {
            contentSources.insert(srcIndex[p])
        }
        let insertions = planInsertionsWMF(scene, srcIndex: srcIndex)
        let firstContent = contentSources.min()

        var table = SlotTable()
        var warnings: [ExportWarning] = []
        var body: [[UInt8]] = []
        var maxRecordWords: UInt32 = 0
        func emit(_ chunk: [UInt8]) {
            body.append(chunk)
            maxRecordWords = max(maxRecordWords, UInt32(chunk.count / 2))
        }
        func emitBlocks(_ elements: [Element]) throws(WMFWriteError) {
            for element in elements where !element.hidden {
                for record in try wmfBlockRecords(element, space: space, table: &table, warnings: &warnings) {
                    emit(try WMFRecordEncoder.encode(record))
                }
            }
        }

        for (i, record) in wmf.records.enumerated() {
            if record.function == 0x0000 { continue }   // META_EOF — appended last
            if i == firstContent { try emitBlocks(insertions.atStart) }

            if contentSources.contains(i) {
                if let owner = ownerBySource[i] {
                    if owner.provenance.edited {
                        if i == drawKeyOf[owner.id] { try emitBlocks([owner]) }
                    } else {
                        emit(try wmfRawOrThrow(bytes, record))
                    }
                }   // deleted → drop
            } else {
                emit(try wmfRawOrThrow(bytes, record))
            }
            applyWMFObjectEffect(record, bytes: bytes, table: &table)
            if let after = insertions.afterRecord[i] { try emitBlocks(after) }
        }
        if firstContent == nil { try emitBlocks(insertions.atStart) }

        return (try assembleWMF(source: bytes, wmf: wmf, body: body, maxRecordWords: maxRecordWords,
                                numberOfObjects: max(wmf.header.numberOfObjects, UInt16(clamping: table.highWater))), warnings)
    }

    /// Embedded-EMF WMF overlay (renderPath .gdi): the drawing comes from an
    /// embedded EMF, so the edit lands there — overlay the embedded EMF, re-embed
    /// it as fresh WMFC escape records, and keep the WMF records unchanged (a
    /// WMF-only reader still shows the original: `embeddedEMFOnly` warning).
    private static func overlayEmbeddedWMF(_ wmf: WMFFile, _ scene: Scene) throws -> (Data, [ExportWarning]) {
        guard case .reassembled(let emfData) = WMFEmbeddedEMF.reassemble(wmf) else {
            return try overlayWMF(wmf, scene)   // defensive: no usable embedded EMF
        }
        let emfFile = try EMFFile.parse(emfData)
        var (editedEMF, warnings) = try overlayEMF(emfFile, scene, source: emfData)
        warnings.append(.embeddedEMFOnly)

        let bytes = [UInt8](scene.source.data)
        let newEscapes = try WMFEmbeddedEMFWriter.escapeRecords(for: editedEMF)
        editedEMF.removeAll(keepingCapacity: false)

        var body: [[UInt8]] = []
        var maxRecordWords: UInt32 = 0
        for chunk in newEscapes { body.append(chunk); maxRecordWords = max(maxRecordWords, UInt32(chunk.count / 2)) }
        for record in wmf.records {
            if record.function == 0x0000 { continue }   // EOF appended last
            if isWMFCEscape(bytes, record) { continue } // drop old embedded-EMF escapes
            let chunk = try wmfRawOrThrow(bytes, record)
            body.append(chunk); maxRecordWords = max(maxRecordWords, UInt32(chunk.count / 2))
        }
        return (try assembleWMF(source: bytes, wmf: wmf, body: body, maxRecordWords: maxRecordWords,
                                numberOfObjects: wmf.header.numberOfObjects), warnings)
    }

    // MARK: - WMF assembly

    /// Builds the output WMF: preserved placeable (checksum patched) + META_HEADER
    /// (SizeLow/High, MaxRecord, NumberOfObjects patched) + `body` + META_EOF.
    private static func assembleWMF(source: [UInt8], wmf: WMFFile, body: [[UInt8]], maxRecordWords: UInt32, numberOfObjects: UInt16) throws(WMFWriteError) -> Data {
        let eof: [UInt8] = [0x03, 0x00, 0x00, 0x00, 0x00, 0x00]   // RecordSize 3 words, Function META_EOF
        let hasPlaceable = wmf.placeable != nil
        let metaOffset = hasPlaceable ? 22 : 0
        guard source.count >= metaOffset + 18 else { throw .sourceRecordOutOfBounds(recordOffset: 0, recordSize: 18) }

        var bodyBytes = 0
        for chunk in body { bodyBytes += chunk.count }
        let metafileBytes = 18 + bodyBytes + eof.count
        guard metafileBytes / 2 <= Int(UInt32.max) else { throw .fileTooLarge(byteCount: metafileBytes) }
        let metafileWords = metafileBytes / 2
        let mrw = max(maxRecordWords, UInt32(eof.count / 2))

        var header = Array(source[metaOffset ..< metaOffset + 18])
        patchU16(&header, 6, UInt16(metafileWords & 0xFFFF))
        patchU16(&header, 8, UInt16((metafileWords >> 16) & 0xFFFF))
        patchU16(&header, 10, numberOfObjects)
        patchU32(&header, 12, mrw)

        var out = [UInt8]()
        if hasPlaceable {
            var placeable = Array(source[0 ..< 22])
            patchU16(&placeable, 20, placeableChecksum(placeable))
            out.append(contentsOf: placeable)
        }
        out.append(contentsOf: header)
        for chunk in body { out.append(contentsOf: chunk) }
        out.append(contentsOf: eof)
        return Data(out)
    }

    /// Updates the slot model for a source WMF record's object effect.
    private static func applyWMFObjectEffect(_ record: WMFRawRecord, bytes: [UInt8], table: inout SlotTable) {
        let createFunctions: Set<UInt16> = [0x02FA, 0x02FB, 0x02FC, 0x00F7, 0x01F9, 0x0142, 0x06FF]
        if createFunctions.contains(record.function) {
            _ = table.allocate()
        } else if record.function == 0x01F0 {   // META_DELETEOBJECT
            let o = record.offset + 6
            guard o >= 0, o + 2 <= bytes.count else { return }
            let slot = UInt16(bytes[o]) | (UInt16(bytes[o + 1]) << 8)
            if slot & 0x8000 == 0 { table.free(Int(slot)) }
        }
    }

    /// Builds one element's logical-space WMF block, allocating its object slots
    /// from the running slot model. The element is first mapped into the WMF's
    /// LOGICAL coordinate space (`space`) so the block draws exactly where the
    /// file's own records do — full scale in any spec-correct reader.
    private static func wmfBlockRecords(_ element: Element, space: WMFLogicalSpace, table: inout SlotTable, warnings: inout [ExportWarning]) throws(WMFWriteError) -> [WMFRecord] {
        let needs = SceneSynthesis.wmfSlotNeeds(for: element)
        let penSlot = needs.pen ? table.allocate() : 0
        let brushSlot = needs.brush ? table.allocate() : 0
        let fontSlot = needs.font ? table.allocate() : 0
        let logical = wmfLogicalElement(element, space)
        let records = SceneSynthesis.wmfBlock(for: logical, winOrg: space.winOrg, winExt: space.winExt, penSlot: penSlot, brushSlot: brushSlot, fontSlot: fontSlot, warnings: &warnings)
        if needs.font { table.free(Int(fontSlot)) }
        if needs.brush { table.free(Int(brushSlot)) }
        if needs.pen { table.free(Int(penSlot)) }
        return records
    }

    /// The WMF page's base window (the translated program's preamble) and the
    /// device-canvas → WMF-logical affine. A synthesised block is drawn in this
    /// logical space, like every verbatim record, so a spec-correct standalone
    /// reader maps it to the full output frame (not to the small device canvas).
    private struct WMFLogicalSpace {
        var winOrg: PointL
        var winExt: SizeL
        var canvasToLogical: CGAffineTransform
    }

    /// Reads the base window org/ext out of the translated program's synthetic
    /// preamble (payloads with source index -1) — the mapping `pageSetup` built —
    /// and inverts the window→canvas scale into the canvas→logical affine
    /// (logical = winOrg + canvas × winExt / canvasSize). Defaults keep the map
    /// finite for a degenerate window ([MS-WMF] §2.3.5.30, §3.1.4.2).
    private static func wmfLogicalSpace(_ program: WMFRenderProgram) -> WMFLogicalSpace {
        let cw = max(1, program.canvasWidth), ch = max(1, program.canvasHeight)
        var org = PointL(x: 0, y: 0)
        var ext = SizeL(cx: Int32(cw), cy: Int32(ch))
        for (i, payload) in program.payloads.enumerated()
        where i < program.payloadSourceIndices.count && program.payloadSourceIndices[i] == -1 {
            switch payload {
            case .setWindowOrgEx(let o): org = o
            case .setWindowExtEx(let e): ext = e
            default: break
            }
        }
        let sx = ext.cx == 0 ? 1 : Double(ext.cx) / Double(cw)
        let sy = ext.cy == 0 ? 1 : Double(ext.cy) / Double(ch)
        let canvasToLogical = CGAffineTransform(
            a: CGFloat(sx), b: 0, c: 0, d: CGFloat(sy),
            tx: CGFloat(org.x), ty: CGFloat(org.y)
        )
        return WMFLogicalSpace(winOrg: org, winExt: ext, canvasToLogical: canvasToLogical)
    }

    /// Returns a copy of `element` mapped into WMF-logical space with an identity
    /// transform: geometry, image destination and the (post-edit) text reference
    /// go through `canvasToLogical`, so the synthesis — which reads these fields
    /// and scales widths by `averageScale(transform)` (now 1) — emits logical
    /// records at logical pen widths and font heights.
    private static func wmfLogicalElement(_ element: Element, _ space: WMFLogicalSpace) -> Element {
        var mapped = element
        mapped.geometryDevice = element.geometryDevice.applying(space.canvasToLogical)
        if var text = mapped.text {
            let device = CGPoint(x: text.referenceLogical.x, y: text.referenceLogical.y).applying(element.transform)
            text.referenceLogical = device.applying(space.canvasToLogical)
            mapped.text = text
        }
        if var image = mapped.image {
            image.destRectDevice = image.destRectDevice.applying(space.canvasToLogical)
            mapped.image = image
        }
        mapped.transform = .identity
        return mapped
    }

    private static func isWMFCEscape(_ bytes: [UInt8], _ record: WMFRawRecord) -> Bool {
        guard record.function == 0x0626 else { return false }   // META_ESCAPE
        let o = record.offset + 6
        guard o + 8 <= bytes.count else { return false }
        let escapeFn = UInt16(bytes[o]) | (UInt16(bytes[o + 1]) << 8)
        guard escapeFn == 0x000F else { return false }          // MFCOMMENT
        let id = UInt32(bytes[o + 4]) | (UInt32(bytes[o + 5]) << 8) | (UInt32(bytes[o + 6]) << 16) | (UInt32(bytes[o + 7]) << 24)
        return id == 0x4346_4D57                                // "WMFC"
    }

    private static func wmfRawOrThrow(_ bytes: [UInt8], _ record: WMFRawRecord) throws(WMFWriteError) -> [UInt8] {
        let start = record.offset, size = record.byteSize
        guard start >= 0, size >= 0, size <= bytes.count, start <= bytes.count - size else {
            throw .sourceRecordOutOfBounds(recordOffset: start, recordSize: size)
        }
        return Array(bytes[start ..< start + size])
    }

    // MARK: - Insertions (z-position)

    private struct Insertions { var atStart: [Element]; var afterRecord: [Int: [Element]] }

    /// Maps new (no-provenance) elements to the source record after which they
    /// insert — the last record of the source element below them in z-order (or
    /// the start of the drawing records for the bottom).
    private static func planInsertions(_ scene: Scene) -> Insertions {
        var atStart: [Element] = []
        var afterRecord: [Int: [Element]] = [:]
        var prevSourceLast: Int?
        for element in scene.elements {
            if element.provenance.sourceRecordIndices.isEmpty {
                if let p = prevSourceLast { afterRecord[p, default: []].append(element) }
                else { atStart.append(element) }
            } else {
                prevSourceLast = element.provenance.sourceRecordIndices.max()
            }
        }
        return Insertions(atStart: atStart, afterRecord: afterRecord)
    }

    private static func planInsertionsWMF(_ scene: Scene, srcIndex: [Int]) -> Insertions {
        var atStart: [Element] = []
        var afterRecord: [Int: [Element]] = [:]
        var prevSourceLast: Int?
        for element in scene.elements {
            if element.provenance.sourceRecordIndices.isEmpty {
                if let p = prevSourceLast { afterRecord[p, default: []].append(element) }
                else { atStart.append(element) }
            } else {
                let recs = element.provenance.sourceRecordIndices.compactMap { $0 >= 0 && $0 < srcIndex.count && srcIndex[$0] >= 0 ? srcIndex[$0] : nil }
                if let k = recs.max() { prevSourceLast = k }
            }
        }
        return Insertions(atStart: atStart, afterRecord: afterRecord)
    }

    // MARK: - Helpers

    /// Gzip-wraps the bytes when the format is compressed.
    private static func finalize(_ data: Data, _ format: ExportFormat) -> Data {
        format.isCompressed ? GzipWriter.compress(data) : data
    }

    /// One past the largest object-table index any creation/reference record
    /// names, so synthesised objects use slots no existing record touches.
    private static func maxTableIndex(_ records: [EMFRawRecord], _ bytes: [UInt8]) -> UInt32 {
        var maxIndex: UInt32 = 0
        for record in records where handleFieldTypes.contains(record.type) {
            let offset = record.offset + 8
            guard record.size >= 12, offset >= 0, offset <= bytes.count - 4 else { continue }
            let raw = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
            if raw & 0x8000_0000 == 0, raw > maxIndex { maxIndex = raw }
        }
        return maxIndex
    }

    private static func rawOrThrow(_ bytes: [UInt8], _ record: EMFRawRecord) throws(EMFWriteError) -> [UInt8] {
        let start = record.offset
        let size = Int(record.size)
        guard start >= 0, size >= 0, size <= bytes.count, start <= bytes.count - size else {
            throw .sourceRecordOutOfBounds(recordOffset: start, recordSize: record.size)
        }
        return Array(bytes[start ..< start + size])
    }

    /// The handle-table size the body demands: one past the largest table index
    /// any output record (verbatim or synthesised) names in its offset-8 field.
    private static func handleCount(_ chunks: [[UInt8]]) throws(EMFWriteError) -> UInt16 {
        var maxIndex: UInt32 = 0
        var sawAny = false
        for chunk in chunks where chunk.count >= 12 {
            let type = UInt32(chunk[0]) | (UInt32(chunk[1]) << 8) | (UInt32(chunk[2]) << 16) | (UInt32(chunk[3]) << 24)
            guard handleFieldTypes.contains(type) else { continue }
            let raw = UInt32(chunk[8]) | (UInt32(chunk[9]) << 8) | (UInt32(chunk[10]) << 16) | (UInt32(chunk[11]) << 24)
            guard raw & 0x8000_0000 == 0 else { continue }
            sawAny = true
            if raw > maxIndex { maxIndex = raw }
        }
        guard sawAny else { return 1 }
        let count = maxIndex + 1
        guard count <= UInt32(UInt16.max) else { throw .objectTableOverflow(index: maxIndex) }
        return UInt16(count)
    }

    private static func patchU32(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt32) {
        guard offset >= 0, offset <= buffer.count - 4 else { return }
        buffer[offset] = UInt8(value & 0xFF)
        buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
        buffer[offset + 2] = UInt8((value >> 16) & 0xFF)
        buffer[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
    private static func patchU16(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt16) {
        guard offset >= 0, offset <= buffer.count - 2 else { return }
        buffer[offset] = UInt8(value & 0xFF)
        buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    /// The Aldus placeable `Checksum`: XOR of the first ten 16-bit WORDs
    /// ([MS-WMF] §2.3.2.3), the computation WMFParse verifies.
    private static func placeableChecksum(_ placeable: [UInt8]) -> UInt16 {
        var checksum: UInt16 = 0
        for i in 0 ..< 10 where i * 2 + 1 < placeable.count {
            checksum ^= UInt16(placeable[i * 2]) | (UInt16(placeable[i * 2 + 1]) << 8)
        }
        return checksum
    }
}

/// The WMF object-table model for the overlay ([MS-WMF] §3.1.4.1): simulated
/// along the source stream so a synthesised block takes the lowest free slots
/// the same allocator would, and `highWater` gives the `NumberOfObjects` the
/// output must declare.
private struct SlotTable {
    private var occupied = Set<Int>()
    private(set) var highWater = 0
    mutating func allocate() -> UInt16 {
        var slot = 0
        while occupied.contains(slot) { slot += 1 }
        occupied.insert(slot)
        highWater = max(highWater, slot + 1)
        return UInt16(truncatingIfNeeded: slot)
    }
    mutating func free(_ slot: Int) { occupied.remove(slot) }
}
