import Foundation
import EMFParse

/// Packages a complete EMF into a run of META_ESCAPE_ENHANCED_METAFILE records
/// ([MS-WMF] §2.3.6.25) — the exact inverse of `WMFParse.WMFEmbeddedEMF`'s
/// reassembly. Embedding the EMF lets a richer reader (including Emfy itself)
/// recover the full drawing instead of the lossy GDI record playback.
///
/// Each record is a META_ESCAPE (§2.3.6.1) whose EscapeFunction is MFCOMMENT
/// (0x000F): EscapeFunction, ByteCount, then a 34-byte comment header
/// (CommentIdentifier "WMFC", CommentType, Version, Checksum, Flags,
/// CommentRecordCount, CurrentRecordSize, RemainingBytes,
/// EnhancedMetafileDataSize) and up to 8192 bytes of the EMF. The Checksum is
/// written zero — real emitters zero or miscompute it, and the reader does not
/// gate on it (`WMFEmbeddedEMF`).
public enum WMFEmbeddedEMFWriter {
    /// MFCOMMENT EscapeFunction ([MS-WMF] §2.1.1.17).
    static let escapeFunction: UInt16 = 0x000F
    /// CommentIdentifier "WMFC" ([MS-WMF] §2.3.6.25).
    static let commentIdentifier: UInt32 = 0x4346_4D57
    /// CommentType ([MS-WMF] §2.3.6.25).
    static let commentType: UInt32 = 0x0000_0001
    /// Version written into each chunk (the value LibreOffice/GDI emit).
    static let version: UInt32 = 0x0001_0000
    /// Per-chunk EnhancedMetafileData maximum ([MS-WMF] §2.3.6.25).
    static let maxChunkBytes = 8192

    /// Builds the consecutive escape records that carry `emf`. Returns an empty
    /// array for an empty input (nothing to embed). Throws only if the EMF's size
    /// overflows the 32-bit size fields (unreachable for a real metafile).
    public static func escapeRecords(for emf: Data) throws(WMFWriteError) -> [[UInt8]] {
        let bytes = [UInt8](emf)
        let total = bytes.count
        guard total > 0 else { return [] }
        guard total <= Int(UInt32.max) else { throw .fileTooLarge(byteCount: total) }

        // Split into <= 8192-byte chunks. A from-scratch EMF is a multiple of 4,
        // so every chunk is even and each record stays WORD-aligned.
        var chunks: [[UInt8]] = []
        var offset = 0
        while offset < total {
            let len = min(maxChunkBytes, total - offset)
            chunks.append(Array(bytes[offset ..< offset + len]))
            offset += len
        }
        let recordCount = UInt32(chunks.count)

        var records: [[UInt8]] = []
        records.reserveCapacity(chunks.count)
        var accumulated = 0
        for chunk in chunks {
            accumulated += chunk.count
            let remaining = UInt32(total - accumulated)   // 0 ≤ remaining ≤ total

            var data = ByteWriter()
            data.appendUInt32(commentIdentifier)          // CommentIdentifier "WMFC"
            data.appendUInt32(commentType)                // CommentType
            data.appendUInt32(version)                    // Version
            data.appendUInt16(0)                          // Checksum (not gated on read)
            data.appendUInt32(0)                          // Flags
            data.appendUInt32(recordCount)                // CommentRecordCount
            data.appendUInt32(UInt32(chunk.count))        // CurrentRecordSize
            data.appendUInt32(remaining)                  // RemainingBytes (after this chunk)
            data.appendUInt32(UInt32(total))              // EnhancedMetafileDataSize
            data.appendBytes(chunk)                       // EnhancedMetafileData

            records.append(
                try WMFRecordEncoder.encode(.escape(escapeFunction: escapeFunction, data: data.bytes))
            )
        }
        return records
    }
}
