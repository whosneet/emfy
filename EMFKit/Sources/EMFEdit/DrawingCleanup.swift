import EMFParse
import EMFWrite
import Foundation

// MARK: - Clean-up & compatibility report (X1b item 2)
//
// Walks an EMF's records and reports PROVABLY-redundant records — ones whose removal
// cannot change what the file draws ([MS-EMF] §2.3) — plus the EMF+ comment records a
// plain-EMF compatible copy would strip. It produces two drop sets: `optimisableIndices`
// (redundant GDI records, for "Save Optimised Copy") and `emfPlusCommentIndices` (EMF+
// comment records, for "Save Compatible Copy"). The caller writes a copy with
// `EMFRecordPruner` and verifies render-equivalence before offering it; this report
// never mutates anything.
//
// Conservative by design: a record is only listed when its removal is provably render-
// neutral — an object created but never selected, a state set that repeats the current
// value, or an empty SaveDC/RestoreDC pair. Paths, clips and geometry are left alone.

public struct DrawingCleanup: Sendable, Equatable {

    /// A category of redundancy.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case unusedObject          // a pen/brush/font created but never selected
        case unusedDelete          // a DeleteObject of a never-used / dangling handle
        case redundantStateSet     // a state set repeating the current value
        case emptySaveRestore      // a SaveDC immediately followed by RestoreDC
        case emfPlusComment        // an EMF+ comment record (compatible-copy only)
    }

    public struct Item: Sendable, Equatable, Identifiable {
        public var id: String { kind.rawValue }
        public var kind: Kind
        public var count: Int
        public var bytes: Int
        public init(kind: Kind, count: Int, bytes: Int) {
            self.kind = kind
            self.count = count
            self.bytes = bytes
        }
    }

    /// The grouped findings (non-empty kinds only), highest byte-saving first.
    public var items: [Item]
    /// Total size of the source file, in bytes.
    public var originalByteCount: Int
    /// Record indices safe to drop for an optimised copy (redundant GDI records).
    public var optimisableIndices: Set<Int>
    /// Bytes saved by the optimised copy.
    public var optimisableBytes: Int
    /// EMF+ comment record indices (dropped for a plain-EMF compatible copy).
    public var emfPlusCommentIndices: Set<Int>
    /// Bytes removed by the compatible copy (the EMF+ comments).
    public var emfPlusBytes: Int
    /// Whether the file carries any EMF+ content at all.
    public var hasEMFPlus: Bool
    /// Whether the file is an EMF+ dual file (has a GDI fallback). A compatible copy of a
    /// non-dual EMF+-only file would lose all drawing — the UI warns/refuses.
    public var isDual: Bool

    public init(items: [Item], originalByteCount: Int, optimisableIndices: Set<Int>, optimisableBytes: Int, emfPlusCommentIndices: Set<Int>, emfPlusBytes: Int, hasEMFPlus: Bool, isDual: Bool) {
        self.items = items
        self.originalByteCount = originalByteCount
        self.optimisableIndices = optimisableIndices
        self.optimisableBytes = optimisableBytes
        self.emfPlusCommentIndices = emfPlusCommentIndices
        self.emfPlusBytes = emfPlusBytes
        self.hasEMFPlus = hasEMFPlus
        self.isDual = isDual
    }

    /// Whether an optimised copy would remove anything.
    public var hasOptimisations: Bool { !optimisableIndices.isEmpty }
    /// Byte count after optimisation.
    public var optimisedByteCount: Int { max(0, originalByteCount - optimisableBytes) }
    /// Byte count after the compatible copy (EMF+ comments removed).
    public var compatibleByteCount: Int { max(0, originalByteCount - emfPlusBytes) }

    // MARK: - Analysis

    /// The EMF+ comment identifier "EMF+" ([MS-EMF] §2.3.3.4).
    private static let emfPlusIdentifier: UInt32 = 0x2B46_4D45
    private static let commentType: UInt32 = 70

    /// Analyses `data` as an EMF. A non-EMF or unparseable file yields an empty report.
    public init(data: Data) {
        guard let file = try? EMFFile.parse(data) else {
            self.init(items: [], originalByteCount: data.count, optimisableIndices: [], optimisableBytes: 0, emfPlusCommentIndices: [], emfPlusBytes: 0, hasEMFPlus: false, isDual: false)
            return
        }

        var unusedObjectIndices = Set<Int>()
        var unusedDeleteIndices = Set<Int>()
        var redundantStateIndices = Set<Int>()
        var emptySaveRestoreIndices = Set<Int>()
        var emfPlusIndices = Set<Int>()

        // Object table: which create record currently owns each table slot, and whether
        // that create has been selected yet. A delete links back to its create.
        var ownerCreate: [UInt32: Int] = [:]      // table index → create record index
        var createSelected: [Int: Bool] = [:]     // create record index → ever selected
        var createDelete: [Int: Int] = [:]        // create record index → its delete record

        // DC state for the redundant-set check. nil = unknown (never flag the first set,
        // and invalidate across a SaveDC/RestoreDC barrier so an adjacent set is never
        // wrongly flagged).
        var lastState: [StateKey: EMFRecordPayload] = [:]

        let records = file.records
        for index in records.indices {
            let record = records[index]
            let payload = file.payload(of: record)

            switch payload {
            case .createPen(let p): Self.registerCreate(p.ihPen, index, &ownerCreate, &createSelected)
            case .extCreatePen(let p): Self.registerCreate(p.ihPen, index, &ownerCreate, &createSelected)
            case .createBrushIndirect(let p): Self.registerCreate(p.ihBrush, index, &ownerCreate, &createSelected)
            case .extCreateFontIndirectW(let p): Self.registerCreate(p.ihFonts, index, &ownerCreate, &createSelected)

            case .selectObject(let handle):
                if case .table(let slot) = handle, let create = ownerCreate[slot] {
                    createSelected[create] = true
                }

            case .deleteObject(let handle):
                if case .table(let slot) = handle, let create = ownerCreate[slot] {
                    createDelete[create] = index   // the delete belongs to this create
                    ownerCreate[slot] = nil
                } else {
                    // Deleting a handle no live create owns → provably a no-op.
                    unusedDeleteIndices.insert(index)
                }

            case .saveDC:
                // An empty SaveDC/RestoreDC pair: this SaveDC directly followed by a
                // RestoreDC saves and restores nothing.
                if index + 1 < records.count, case .restoreDC = file.payload(of: records[index + 1]) {
                    emptySaveRestoreIndices.insert(index)
                    emptySaveRestoreIndices.insert(index + 1)
                }
                lastState.removeAll(keepingCapacity: true)   // state barrier
            case .restoreDC:
                lastState.removeAll(keepingCapacity: true)   // state barrier

            default:
                if let key = Self.stateKey(for: payload) {
                    if lastState[key] == payload {
                        redundantStateIndices.insert(index)   // repeats the current value
                    } else {
                        lastState[key] = payload
                    }
                }
            }

            // EMF+ comment detection (type 70, identifier "EMF+"): raw, bounds-checked.
            if record.type == Self.commentType, Self.isEMFPlusComment(data, record: record) {
                emfPlusIndices.insert(index)
            }
        }

        // Objects never selected → their create (and matching delete) are redundant. A
        // create still owning a slot at EOF but never selected is also unused.
        for (create, selected) in createSelected where !selected {
            unusedObjectIndices.insert(create)
            if let delete = createDelete[create] { unusedDeleteIndices.insert(delete) }
        }

        // Build the drop sets and the grouped report.
        let optimisable = unusedObjectIndices
            .union(unusedDeleteIndices)
            .union(redundantStateIndices)
            .union(emptySaveRestoreIndices)
        let bytes: (Set<Int>) -> Int = { set in set.reduce(0) { $0 + Int(records[$1].size) } }

        var built: [Item] = []
        func add(_ kind: Kind, _ set: Set<Int>) {
            guard !set.isEmpty else { return }
            built.append(Item(kind: kind, count: set.count, bytes: bytes(set)))
        }
        add(.unusedObject, unusedObjectIndices)
        add(.unusedDelete, unusedDeleteIndices)
        add(.redundantStateSet, redundantStateIndices)
        add(.emptySaveRestore, emptySaveRestoreIndices)
        add(.emfPlusComment, emfPlusIndices)
        built.sort { $0.bytes > $1.bytes }

        self.init(
            items: built,
            originalByteCount: data.count,
            optimisableIndices: optimisable,
            optimisableBytes: bytes(optimisable),
            emfPlusCommentIndices: emfPlusIndices,
            emfPlusBytes: bytes(emfPlusIndices),
            hasEMFPlus: !emfPlusIndices.isEmpty,
            isDual: file.emfPlusIsDual())
    }

    // MARK: - Writers

    /// Writes an optimised copy of `data` (redundant records removed), or nil when there
    /// is nothing to remove.
    public func optimisedCopy(of data: Data) -> Data? {
        guard !optimisableIndices.isEmpty, let file = try? EMFFile.parse(data) else { return nil }
        return try? EMFRecordPruner.rewrite(data: data, file: file, dropping: optimisableIndices)
    }

    /// Writes a plain-EMF compatible copy of `data` (EMF+ comment records removed), or
    /// nil when there is no EMF+ to strip.
    public func compatibleCopy(of data: Data) -> Data? {
        guard !emfPlusCommentIndices.isEmpty, let file = try? EMFFile.parse(data) else { return nil }
        return try? EMFRecordPruner.rewrite(data: data, file: file, dropping: emfPlusCommentIndices)
    }

    // MARK: - State-set key

    /// The attributes whose repeated set is provably redundant.
    private enum StateKey: Hashable {
        case textColor, bkColor, bkMode, textAlign, polyFillMode, rop2, mapMode
    }

    private static func stateKey(for payload: EMFRecordPayload) -> StateKey? {
        switch payload {
        case .setTextColor: return .textColor
        case .setBkColor: return .bkColor
        case .setBkMode: return .bkMode
        case .setTextAlign: return .textAlign
        case .setPolyFillMode: return .polyFillMode
        case .setROP2: return .rop2
        case .setMapMode: return .mapMode
        default: return nil
        }
    }

    // MARK: - EMF+ comment detection

    /// Whether `record` (type 70) is an EMR_COMMENT_EMFPLUS: DataSize (u32) at record
    /// offset 8 ≥ 4, then CommentIdentifier (u32) at offset 12 equals "EMF+" ([MS-EMF]
    /// §2.3.3.4). Bounds-checked — a truncated comment is simply "not EMF+".
    private static func isEMFPlusComment(_ data: Data, record: EMFRawRecord) -> Bool {
        guard let dataSize = readU32(data, at: record.offset + 8), dataSize >= 4,
              let identifier = readU32(data, at: record.offset + 12) else { return false }
        return identifier == emfPlusIdentifier
    }

    /// A bounds-checked little-endian u32 read at an absolute byte offset, or nil.
    private static func readU32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0 else { return nil }
        let base = data.startIndex + offset
        guard base + 4 <= data.endIndex else { return nil }
        return UInt32(data[base]) | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16) | (UInt32(data[base + 3]) << 24)
    }

    // MARK: - Object-table helper

    /// Records a creation record as the current owner of its table slot, unselected.
    private static func registerCreate(_ slot: UInt32, _ index: Int, _ owner: inout [UInt32: Int], _ selected: inout [Int: Bool]) {
        owner[slot] = index
        selected[index] = false
    }
}
