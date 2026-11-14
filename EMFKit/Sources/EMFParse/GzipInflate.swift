import Compression
import Foundation

// The ONE approved import addition to EMFParse (v3 plan §2, primer §8 v1.5):
// Apple's `Compression` framework, used here and ONLY here for streaming DEFLATE
// inflate under a hard output ceiling. `NSData.decompressed(using:)` is
// deliberately NOT used anywhere — it allocates the whole output before any
// bound can be checked, which is exactly the decompression-bomb surface §8 bans.

/// A typed failure from gzip inflation. Every malformed-input path returns one
/// of these rather than trapping — Quick Look feeds this decoder hostile .emz /
/// .wmz files automatically (§8).
public enum GzipError: Error, Sendable, Equatable {
    /// Fewer bytes than a 10-byte member header plus an 8-byte trailer can fit.
    case tooShort
    /// ID1/ID2 were not 0x1F 0x8B (RFC 1952 §2.3.1).
    case badMagic(id1: UInt8, id2: UInt8)
    /// CM (compression method) was not 8 (DEFLATE) (RFC 1952 §2.3.1).
    case unsupportedMethod(cm: UInt8)
    /// One of FLG's reserved bits (5–7) was set (RFC 1952 §2.3.1.2).
    case reservedFlagsSet(flags: UInt8)
    /// An optional header field (FEXTRA / FNAME / FCOMMENT / FHCRC) ran past the
    /// end of the buffer.
    case truncatedHeader
    /// The DEFLATE stream was malformed or truncated — the decoder could not
    /// finalise it.
    case inflateFailed
    /// Inflation would exceed the output ceiling. Raised the moment the running
    /// total would pass the cap, so no more than `ceiling` + one chunk is ever
    /// allocated (decompression-bomb guard, §8).
    case outputTooLarge(ceiling: Int)
    /// The DEFLATE data decoded, but no 8-byte trailer holding this output's
    /// CRC-32 could be found — a corrupt CRC, or a member with no trailer at
    /// all. `stored` is the value at the end-of-buffer trailer slot.
    case crcMismatch(stored: UInt32, computed: UInt32)
}

/// A non-fatal observation from gzip inflation (header fields are advisory, §8).
public enum GzipDiagnostic: Sendable, Equatable {
    /// The trailer's ISIZE did not match the inflated byte count. Advisory:
    /// ISIZE is only the size mod 2^32 (RFC 1952 §2.3.1), so it legitimately
    /// disagrees for payloads over 4 GiB.
    case isizeMismatch(stored: UInt32, actual: UInt32)
    /// Bytes remained after the first gzip member. Only the first member is
    /// used; the rest (a second member, or padding) is ignored.
    case trailingBytesAfterMember(count: Int)
}

/// Streaming gzip (RFC 1952) inflate over a single member, capped at a hard
/// output ceiling. Foundation + Compression only.
enum GzipInflate {
    /// Result of a successful inflate: the payload plus any advisory diagnostics.
    struct Result: Sendable, Equatable {
        let data: Data
        let diagnostics: [GzipDiagnostic]
    }

    /// Hard macOS ceiling on inflated output (§8). Justification (census,
    /// 4 Nov 2026): the largest real EMF seen across `corpus/` + `corpus-local/`
    /// (246 files) is ~14.1 MiB; only one file exceeds 10 MiB and none exceed
    /// 15 MiB. 64 MiB is ~4.5× that largest real metafile and clears the ~50 MB
    /// input the record walker already contemplates (EMFFile.recordCountLimit
    /// note), while staying far below any level that would jetsam a sandboxed
    /// macOS Quick Look extension.
    static let macOSOutputCeiling = 64 * 1024 * 1024

    /// Hard iOS ceiling on inflated output (§8). iOS Quick Look preview/thumbnail
    /// extensions run under a far tighter footprint than macOS — I4 measured a
    /// peak phys_footprint of 27–38 MiB per corpus pass against a ~30 MB iOS
    /// extension budget — so the inflated payload (which the parser then copies
    /// into its own working buffer) is capped well under that budget. 24 MiB is
    /// still ~1.7× the largest real metafile and clears every corpus .emz/.wmz,
    /// while leaving headroom for the parse buffer and object array on iOS.
    static let iOSOutputCeiling = 24 * 1024 * 1024

    /// The platform's inflate output ceiling: iOS gets the tighter budget, macOS
    /// (and anything else) the 64 MiB value. Overridable per call via `ceiling`.
    #if os(iOS)
    static let defaultOutputCeiling = iOSOutputCeiling
    #else
    static let defaultOutputCeiling = macOSOutputCeiling
    #endif

    /// Output drained from the decoder per `compression_stream_process` call.
    /// On a bomb, at most this much is allocated beyond the ceiling before the
    /// run stops.
    static let outputChunkSize = 64 * 1024

    /// The fixed part of a gzip member header, in bytes (RFC 1952 §2.3.1).
    private static let fixedHeaderSize = 10
    /// The member trailer: CRC-32 then ISIZE.
    private static let trailerSize = 8

    /// Inflates the first gzip member of `data`.
    ///
    /// Throws a `GzipError` on any malformed input; returns the inflated bytes
    /// and advisory diagnostics otherwise. `ceiling` caps the output.
    static func inflate(
        _ data: Data,
        ceiling: Int = defaultOutputCeiling
    ) throws(GzipError) -> Result {
        let reader = ByteReader(data)
        let count = reader.count

        guard count >= fixedHeaderSize + trailerSize else { throw .tooShort }

        // Fixed header (RFC 1952 §2.3.1). These four indices are in range
        // because count >= 18.
        let id1 = reader.bytes[0]
        let id2 = reader.bytes[1]
        guard id1 == 0x1F, id2 == 0x8B else { throw .badMagic(id1: id1, id2: id2) }
        let cm = reader.bytes[2]
        guard cm == 8 else { throw .unsupportedMethod(cm: cm) }
        let flg = reader.bytes[3]
        // Bits 5–7 of FLG are reserved and MUST be zero (RFC 1952 §2.3.1.2).
        guard flg & 0xE0 == 0 else { throw .reservedFlagsSet(flags: flg) }
        // Bytes 4–9: MTIME (4) + XFL (1) + OS (1) — advisory, skipped.

        var cursor = fixedHeaderSize

        // FEXTRA (FLG bit 2): XLEN (2 bytes, LE) then XLEN bytes.
        if flg & 0x04 != 0 {
            guard let xlen = reader.readUInt16(at: cursor) else { throw .truncatedHeader }
            cursor += 2
            let (end, overflow) = cursor.addingReportingOverflow(Int(xlen))
            guard !overflow, end <= count else { throw .truncatedHeader }
            cursor = end
        }
        // FNAME (FLG bit 3): a NUL-terminated string.
        if flg & 0x08 != 0 {
            cursor = try skipZeroTerminated(reader, from: cursor, count: count)
        }
        // FCOMMENT (FLG bit 4): a NUL-terminated string.
        if flg & 0x10 != 0 {
            cursor = try skipZeroTerminated(reader, from: cursor, count: count)
        }
        // FHCRC (FLG bit 1): a 2-byte CRC-16 of the header so far.
        if flg & 0x02 != 0 {
            let (end, overflow) = cursor.addingReportingOverflow(2)
            guard !overflow, end <= count else { throw .truncatedHeader }
            cursor = end
        }

        // The DEFLATE stream (RFC 1951) runs from here to the trailer.
        let deflateStart = cursor
        let output = try inflateDeflate(
            reader: reader,
            start: deflateStart,
            count: count,
            ceiling: ceiling
        )

        let computedCRC = CRC32.checksum(output)
        // ISIZE is the size mod 2^32 (RFC 1952 §2.3.1).
        let outputISize = UInt32(truncatingIfNeeded: output.count)

        // Trailer location. Apple's decoder over-consumes its input window once
        // it hits the DEFLATE end marker, so the stream's exact end offset cannot
        // be read back from it. Instead, recognise the trailer by the value it
        // MUST hold for this output: CRC-32 then ISIZE. The common single-member
        // file (everything `gzip` emits) has it as the last 8 bytes.
        guard let endCRC = reader.readUInt32(at: count - trailerSize),
              let endISize = reader.readUInt32(at: count - 4)
        else {
            // Unreachable: count >= 18 guarantees these reads. Typed, not a trap.
            throw .crcMismatch(stored: 0, computed: computedCRC)
        }

        if endCRC == computedCRC {
            var diagnostics: [GzipDiagnostic] = []
            if endISize != outputISize {
                diagnostics.append(.isizeMismatch(stored: endISize, actual: outputISize))
            }
            return Result(data: output, diagnostics: diagnostics)
        }

        // The last 8 bytes are not this output's trailer. Look for the real
        // trailer earlier in the buffer; anything past member-end is trailing
        // data (only the first member is used).
        if let trailerStart = findTrailer(
            reader: reader,
            from: deflateStart,
            upTo: count - trailerSize,
            crc: computedCRC,
            isize: outputISize
        ) {
            var diagnostics: [GzipDiagnostic] = []
            let memberEnd = trailerStart + trailerSize
            if memberEnd < count {
                diagnostics.append(.trailingBytesAfterMember(count: count - memberEnd))
            }
            return Result(data: output, diagnostics: diagnostics)
        }

        throw .crcMismatch(stored: endCRC, computed: computedCRC)
    }

    // MARK: - Header helpers

    /// Advances past a NUL-terminated header string, returning the index just
    /// after the NUL, or throwing if no NUL appears before the buffer ends.
    private static func skipZeroTerminated(
        _ reader: ByteReader,
        from start: Int,
        count: Int
    ) throws(GzipError) -> Int {
        var i = start
        while i < count {
            if reader.bytes[i] == 0 { return i + 1 }
            i += 1
        }
        throw .truncatedHeader
    }

    // MARK: - DEFLATE

    /// Inflates the DEFLATE stream at `[start, count)` in fixed-size output
    /// chunks, stopping with `.outputTooLarge` the instant the running total
    /// would pass `ceiling`. The `compression_stream` is destroyed on every exit
    /// path (`defer`). `COMPRESSION_ZLIB` is Apple's raw-DEFLATE codec (no zlib
    /// wrapper), which is exactly what a gzip member carries.
    private static func inflateDeflate(
        reader: ByteReader,
        start: Int,
        count: Int,
        ceiling: Int
    ) throws(GzipError) -> Data {
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: outputChunkSize)
        defer { dst.deallocate() }

        var stream = compression_stream(
            dst_ptr: dst, dst_size: 0,
            src_ptr: UnsafePointer(dst), src_size: 0,
            state: nil
        )
        guard compression_stream_init(
            &stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB
        ) == COMPRESSION_STATUS_OK else {
            throw .inflateFailed
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        var failure: GzipError?

        reader.bytes.withUnsafeBytes { rawSrc in
            guard let base = rawSrc.bindMemory(to: UInt8.self).baseAddress else {
                failure = .inflateFailed
                return
            }
            stream.src_ptr = base + start
            stream.src_size = count - start
            let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)

            // Belt-and-braces finite iteration bound (§8). The stall guard below
            // already forbids a no-progress loop; this makes termination
            // unconditional even against unspecified decoder behaviour. It is
            // provably never reached by a progressing decode: every continuing OK
            // iteration advances at least one of two monotonic, bounded counters
            // — bytes emitted (held at or below `ceiling` by the check below) or
            // bytes consumed (at most `count - start`) — by at least one, since
            // an iteration advancing neither is rejected by the stall guard. The
            // iteration count is therefore bounded by their sum.
            let iterationCap = ceiling + (count - start) + 1
            var iterations = 0

            while true {
                iterations += 1
                if iterations > iterationCap {
                    failure = .inflateFailed
                    return
                }

                let srcSizeBefore = stream.src_size
                stream.dst_ptr = dst
                stream.dst_size = outputChunkSize
                let status = compression_stream_process(&stream, flags)
                let produced = outputChunkSize - stream.dst_size

                if produced > 0 {
                    if output.count + produced > ceiling {
                        failure = .outputTooLarge(ceiling: ceiling)
                        return
                    }
                    output.append(dst, count: produced)
                }

                switch status {
                case COMPRESSION_STATUS_END:
                    return
                case COMPRESSION_STATUS_OK:
                    // Stall guard (§8): a call that emitted nothing AND consumed
                    // nothing (src_size unchanged from before the call) can only
                    // repeat forever. This covers both an exhausted input
                    // (srcSizeBefore == 0) and a decoder that otherwise stops
                    // making progress. Fail rather than spin in a sandboxed Quick
                    // Look extension.
                    if produced == 0 && stream.src_size == srcSizeBefore {
                        failure = .inflateFailed
                        return
                    }
                    continue
                default:
                    // COMPRESSION_STATUS_ERROR and any unknown status.
                    failure = .inflateFailed
                    return
                }
            }
        }

        if let failure { throw failure }
        return output
    }

    /// Scans `[from + 1, upTo]` for an 8-byte trailer `[crc LE][isize LE]`,
    /// returning its start offset or `nil`. The match must sit after at least
    /// one DEFLATE byte. Two 32-bit reads per position; both are bounds-checked
    /// by `ByteReader`.
    private static func findTrailer(
        reader: ByteReader,
        from: Int,
        upTo: Int,
        crc: UInt32,
        isize: UInt32
    ) -> Int? {
        var p = from + 1
        while p <= upTo {
            if reader.readUInt32(at: p) == crc,
               reader.readUInt32(at: p + 4) == isize {
                return p
            }
            p += 1
        }
        return nil
    }
}
