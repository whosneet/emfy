import Compression
import Foundation
@testable import EMFParse

// Shared helpers for the W2 signature / gzip tests: a corpus-path anchor and a
// hand-rolled gzip member builder. The test target MAY import Compression (only
// EMFParse's own sources are bound by the Foundation-only / gzip-file-only
// import rule); it is used here to synthesise DEFLATE streams and the
// decompression-bomb payload at test time, so no giant fixture is committed.

enum MetafileCorpus {
    /// `<repo>/corpus/<name>`. Resolved from this file's compile-time path, the
    /// same fragile-but-supported trick as CorpusPathTests' `CorpusPaths`.
    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // EMFParseTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // EMFKit
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("corpus")
            .appendingPathComponent(name)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }
}

/// Builds gzip members (RFC 1952) by hand so tests can exercise every header and
/// trailer path, including deliberately malformed ones.
enum GzipFixture {
    /// Raw DEFLATE (RFC 1951) of `payload`, via Apple's `COMPRESSION_ZLIB` — the
    /// exact codec `GzipInflate` decodes, and what a gzip member carries.
    static func deflate(_ payload: [UInt8]) -> [UInt8] {
        let capacity = payload.count + 4096
        var dst = [UInt8](repeating: 0, count: capacity)
        let produced = payload.withUnsafeBufferPointer { src -> Int in
            dst.withUnsafeMutableBufferPointer { out -> Int in
                compression_encode_buffer(
                    out.baseAddress!, out.count,
                    src.baseAddress!, src.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        precondition(produced > 0, "deflate of \(payload.count) bytes produced nothing")
        return Array(dst[0 ..< produced])
    }

    private static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }

    /// Assembles a gzip member. Any optional field present sets its FLG bit.
    /// `deflateOverride`, `crcOverride`, `isizeOverride` and `trailing` let a
    /// test inject malformed or trailing bytes.
    static func make(
        payload: [UInt8],
        extraFlags: UInt8 = 0,
        extra: [UInt8]? = nil,
        name: [UInt8]? = nil,
        comment: [UInt8]? = nil,
        fhcrc: Bool = false,
        deflateOverride: [UInt8]? = nil,
        crcOverride: UInt32? = nil,
        isizeOverride: UInt32? = nil,
        trailing: [UInt8] = []
    ) -> Data {
        var flags = extraFlags
        if fhcrc { flags |= 0x02 }
        if extra != nil { flags |= 0x04 }
        if name != nil { flags |= 0x08 }
        if comment != nil { flags |= 0x10 }

        var bytes: [UInt8] = [0x1F, 0x8B, 0x08, flags]
        bytes += [0, 0, 0, 0]   // MTIME
        bytes += [0x00]         // XFL
        bytes += [0xFF]         // OS (unknown)

        if let extra {
            bytes += le16(UInt16(extra.count))
            bytes += extra
        }
        if let name {
            bytes += name
            bytes += [0x00]
        }
        if let comment {
            bytes += comment
            bytes += [0x00]
        }
        if fhcrc {
            bytes += [0x00, 0x00]   // dummy CRC-16; the inflater skips it
        }

        bytes += deflateOverride ?? deflate(payload)
        bytes += le32(crcOverride ?? CRC32.checksum(payload))
        bytes += le32(isizeOverride ?? UInt32(truncatingIfNeeded: payload.count))
        bytes += trailing
        return Data(bytes)
    }
}
