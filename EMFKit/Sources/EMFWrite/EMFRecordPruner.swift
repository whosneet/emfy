import EMFParse
import Foundation

// MARK: - Drop redundant records from an EMF, re-patching the header (X1b item 2)
//
// Given a parsed EMF and a set of record indices to drop, re-emits the kept records'
// bytes VERBATIM (every kept record is copied exactly, so nothing it draws changes) and
// patches the EMR_HEADER's nBytes and nRecords to the new totals. EMR_HEADER and EMR_EOF
// are structural and never dropped. This is the shared machinery behind the optimised
// copy (drop provably-redundant records) and the compatible copy (drop EMF+ comment
// records to leave plain GDI). Clean-room byte surgery from [MS-EMF] §2.3.4.2 only.

public enum EMFRecordPruner {

    public enum PruneError: Error, Sendable, Equatable {
        /// A kept record's byte range fell outside the source data (should never happen
        /// for a parsed file, but checked rather than trusted — §8).
        case recordOutOfBounds
        /// Nothing was dropped (the drop set was empty after removing structural records).
        case nothingToDrop
    }

    /// [MS-EMF] §2.3.4.2: in EMR_HEADER, `nBytes` (total size) is at record offset 48 and
    /// `nRecords` (total record count) at offset 52, both u32 little-endian.
    static let nBytesOffset = 48
    static let nRecordsOffset = 52
    static let eofType: UInt32 = 14
    static let headerType: UInt32 = 1

    /// Re-emits `data` without the records at `dropIndices` (indices into `file.records`).
    /// Structural records (EMR_HEADER, EMR_EOF) are kept even if named. Returns the new
    /// bytes with the header's nBytes/nRecords patched to the new totals.
    public static func rewrite(data: Data, file: EMFFile, dropping dropIndices: Set<Int>) throws(PruneError) -> Data {
        let records = file.records
        // Keep structural records regardless of the drop set.
        var effectiveDrop = Set<Int>()
        for index in dropIndices where index >= 0 && index < records.count {
            let type = records[index].type
            if type != headerType && type != eofType { effectiveDrop.insert(index) }
        }
        guard !effectiveDrop.isEmpty else { throw PruneError.nothingToDrop }

        var output = Data()
        output.reserveCapacity(data.count)
        var keptCount = 0
        let base = data.startIndex
        for (index, record) in records.enumerated() where !effectiveDrop.contains(index) {
            // §8: no unchecked arithmetic on the parse path — a hostile offset/size must
            // fail as a typed error, never trap. Every add is overflow-checked.
            let (start, startOverflow) = base.addingReportingOverflow(record.offset)
            let (end, endOverflow) = start.addingReportingOverflow(Int(record.size))
            guard !startOverflow, !endOverflow,
                  record.offset >= 0, start >= base, end <= data.endIndex, start <= end else {
                throw PruneError.recordOutOfBounds
            }
            output.append(data[start ..< end])
            keptCount += 1
        }

        patchU32(&output, at: nBytesOffset, value: UInt32(truncatingIfNeeded: output.count))
        patchU32(&output, at: nRecordsOffset, value: UInt32(truncatingIfNeeded: keptCount))
        return output
    }

    /// Writes `value` little-endian at byte `offset` of `data` (the header sits at the
    /// start, so the offset is absolute). A no-op if the data is too short.
    private static func patchU32(_ data: inout Data, at offset: Int, value: UInt32) {
        guard offset >= 0, offset + 4 <= data.count else { return }
        let base = data.startIndex + offset
        data[base] = UInt8(truncatingIfNeeded: value)
        data[base + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[base + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[base + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
