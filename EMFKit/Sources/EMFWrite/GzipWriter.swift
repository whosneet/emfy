import Compression
import Foundation
import EMFParse

// Compression is imported here for the ONE thing EMFWrite uses it for: raw
// DEFLATE *encode* (COMPRESSION_ZLIB with COMPRESSION_STREAM_ENCODE), the exact
// inverse of GzipInflate's COMPRESSION_ZLIB decode. COMPRESSION_ZLIB is Apple's
// raw-DEFLATE codec (no zlib header/adler), which is precisely what a gzip
// member body carries (RFC 1952 §2.3.1 wraps a raw RFC 1951 stream). Verified
// by round-trip through GzipInflate and by `gunzip -t` (E0a report).

/// Writes an RFC 1952 gzip member around raw DEFLATE — the .emz / .wmz wrapper,
/// the write-side inverse of `OpenedMetafile.open`'s inflate. The uncompressed
/// payload's CRC-32 (RFC 1952 §2.3.1) comes from EMFParse's `CRC32`, the same
/// implementation the inflater verifies against.
public enum GzipWriter {

    /// Gzip-compresses `data`. `filename` (optional) is written as the member's
    /// FNAME field; omit it for an anonymous member (what .emz/.wmz normally
    /// carry). Never fails: if the Compression encoder is unavailable the body
    /// falls back to RFC 1951 stored (uncompressed) blocks, which inflate the
    /// same way.
    public static func compress(_ data: Data, filename: String? = nil) -> Data {
        let input = [UInt8](data)
        let body = rawDeflate(input) ?? storedDeflate(input)
        let crc = CRC32.checksum(input)
        // ISIZE is the uncompressed size mod 2^32 (RFC 1952 §2.3.1).
        let isize = UInt32(truncatingIfNeeded: input.count)

        var w = ByteWriter(capacity: 10 + body.count + 8)
        // Fixed 10-byte member header (RFC 1952 §2.3.1).
        w.appendUInt8(0x1F)                  // ID1
        w.appendUInt8(0x8B)                  // ID2
        w.appendUInt8(0x08)                  // CM = DEFLATE
        var flags: UInt8 = 0
        var nameBytes: [UInt8] = []
        if let filename {
            flags |= 0x08                    // FNAME present
            nameBytes = Array(filename.utf8) + [0]   // NUL-terminated
        }
        w.appendUInt8(flags)                 // FLG
        w.appendUInt32(0)                    // MTIME (none)
        w.appendUInt8(0)                     // XFL
        w.appendUInt8(0xFF)                  // OS = unknown
        if !nameBytes.isEmpty {
            w.appendBytes(nameBytes)
        }
        w.appendBytes(body)                  // raw DEFLATE
        w.appendUInt32(crc)                  // CRC-32 of the uncompressed data
        w.appendUInt32(isize)                // ISIZE
        return w.data
    }

    // MARK: - DEFLATE encode

    private static let outputChunkSize = 64 * 1024

    /// Raw DEFLATE of `input` via Compression's `COMPRESSION_ZLIB` encoder.
    /// Returns nil only if the stream cannot be created or stalls — the caller
    /// then uses the stored-block path, so compression is always possible.
    private static func rawDeflate(_ input: [UInt8]) -> [UInt8]? {
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: outputChunkSize)
        defer { dst.deallocate() }

        var stream = compression_stream(
            dst_ptr: dst, dst_size: 0,
            src_ptr: UnsafePointer(dst), src_size: 0,
            state: nil
        )
        guard compression_stream_init(
            &stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB
        ) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(&stream) }

        var output: [UInt8] = []
        var ok = true

        input.withUnsafeBufferPointer { src in
            // An empty input has a nil baseAddress; a valid non-null src_ptr with
            // src_size 0 still finalises to the empty-stream DEFLATE.
            stream.src_ptr = src.baseAddress ?? UnsafePointer(dst)
            stream.src_size = src.count
            let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)

            while true {
                let srcSizeBefore = stream.src_size
                stream.dst_ptr = dst
                stream.dst_size = outputChunkSize
                let status = compression_stream_process(&stream, flags)
                let produced = outputChunkSize - stream.dst_size
                if produced > 0 {
                    output.append(contentsOf: UnsafeBufferPointer(start: dst, count: produced))
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return
                case COMPRESSION_STATUS_OK:
                    // Stall guard: a call that produced and consumed nothing can
                    // only repeat; fall back to the stored path.
                    if produced == 0, stream.src_size == srcSizeBefore {
                        ok = false
                        return
                    }
                    continue
                default:
                    ok = false
                    return
                }
            }
        }
        return ok ? output : nil
    }

    /// RFC 1951 §3.2.4 stored (uncompressed) blocks: a trap-free fallback that
    /// always yields valid DEFLATE. Chunks the input into ≤ 65535-byte blocks,
    /// the last flagged BFINAL. Byte-aligned, so no bit packing is needed.
    private static func storedDeflate(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        let maxBlock = 0xFFFF

        guard !input.isEmpty else {
            out.append(0x01)              // BFINAL = 1, BTYPE = 00
            out.append(0x00); out.append(0x00)   // LEN  = 0
            out.append(0xFF); out.append(0xFF)   // NLEN = ~LEN
            return out
        }

        var offset = 0
        while offset < input.count {
            let blockLen = min(input.count - offset, maxBlock)
            let isFinal = offset + blockLen >= input.count
            out.append(isFinal ? 0x01 : 0x00)    // BFINAL + BTYPE = 00
            let len = UInt16(blockLen)
            out.append(UInt8(len & 0xFF)); out.append(UInt8(len >> 8))
            let nlen = ~len
            out.append(UInt8(nlen & 0xFF)); out.append(UInt8(nlen >> 8))
            out.append(contentsOf: input[offset ..< offset + blockLen])
            offset += blockLen
        }
        return out
    }
}
