import Foundation

/// The metafile container a byte prefix looks like, by signature alone. This is
/// detection, not parsing: it reads only the first few dozen bytes and never
/// decodes a body.
public enum MetafileFormat: Sendable, Equatable {
    /// Enhanced Metafile: EMR_HEADER (type 1) at offset 0 with the " EMF"
    /// RecordSignature at offset 40 ([MS-EMF] §2.2.9, §2.3.4.2).
    case emf
    /// Placeable WMF: the 0x9AC6CDD7 key followed by a plausible META_HEADER
    /// ([MS-WMF] §2.3.2.3).
    case placeableWMF
    /// Standard (non-placeable) WMF: a plausible META_HEADER at offset 0
    /// ([MS-WMF] §2.3.2.2).
    case wmf
    /// gzip member (RFC 1952): a .emz / .wmz wrapper to be inflated.
    case gzip
    /// None of the above, or too few bytes to tell.
    case unknown
}

/// A non-fatal observation made while sniffing a signature. Header fields are
/// advisory (§8), so a mismatch here never changes the detected format.
public enum MetafileSniffDiagnostic: Sendable, Equatable {
    /// The placeable WMF Checksum WORD did not match the XOR of the first ten
    /// header WORDs ([MS-WMF] §2.3.2.3). Advisory only — real files miscompute
    /// it — so the file is still reported as `.placeableWMF`.
    case placeableChecksumMismatch(stored: UInt16, computed: UInt16)
}

/// The result of sniffing a byte prefix: the detected format plus any advisory
/// diagnostics.
public struct MetafileSignature: Sendable, Equatable {
    public let format: MetafileFormat
    public let diagnostics: [MetafileSniffDiagnostic]

    // MARK: - Constants

    /// META_PLACEABLE Key ([MS-WMF] §2.3.2.3), little-endian at offset 0.
    static let placeableKey: UInt32 = 0x9AC6_CDD7
    /// The placeable header is 22 bytes; the META_HEADER follows immediately
    /// ([MS-WMF] §2.3.2.3).
    static let placeableHeaderSize = 22

    /// How many leading bytes the sniff ever reads. The furthest read is the EMF
    /// RecordSignature at offset 40 (4 bytes, so byte 43); 64 is a safe round
    /// cover for every check below. Sniffing a bounded prefix keeps `detect` from
    /// copying a whole multi-megabyte input into a `ByteReader` just to look at
    /// the header — Quick Look sniffs every file Finder shows (§8).
    static let sniffPrefixLength = 64

    // MARK: - Detection

    /// Classifies `data` by signature. Never reads past the buffer, never
    /// throws; short or unrecognised input is `.unknown`.
    public static func detect(_ data: Data) -> MetafileSignature {
        // Copy at most `sniffPrefixLength` bytes into the reader, never the whole
        // input: every signature read below targets an offset under 64, and each
        // read is bounds-checked, so a short prefix simply fails to match.
        let reader = ByteReader(data.prefix(sniffPrefixLength))

        // gzip (RFC 1952 §2.3.1): ID1 0x1F, ID2 0x8B, CM 0x08 (DEFLATE). CM is
        // checked here too so a non-DEFLATE "gzip" is not advertised as
        // inflatable.
        if reader.count >= 3,
           reader.bytes[0] == 0x1F, reader.bytes[1] == 0x8B, reader.bytes[2] == 0x08 {
            return MetafileSignature(format: .gzip, diagnostics: [])
        }

        // EMF: EMR_HEADER iType == 1 at offset 0 and the " EMF" RecordSignature
        // 0x464D4520 at offset 40 ([MS-EMF] §2.2.9, §2.3.4.2).
        if reader.readUInt32(at: 0) == EMFFile.headerType,
           reader.readUInt32(at: 40) == EMFFile.recordSignatureValue {
            return MetafileSignature(format: .emf, diagnostics: [])
        }

        // Placeable WMF: Key at offset 0, then a plausible META_HEADER at offset
        // 22 ([MS-WMF] §2.3.2.3). The key alone is a very specific 32-bit value,
        // but requiring a plausible META_HEADER avoids a false positive on any
        // file that merely opens with those four bytes.
        if reader.readUInt32(at: 0) == placeableKey {
            if isPlausibleMetaHeader(reader, at: placeableHeaderSize) {
                var diagnostics: [MetafileSniffDiagnostic] = []
                if let diagnostic = placeableChecksumDiagnostic(reader) {
                    diagnostics.append(diagnostic)
                }
                return MetafileSignature(format: .placeableWMF, diagnostics: diagnostics)
            }
            return MetafileSignature(format: .unknown, diagnostics: [])
        }

        // Standard (non-placeable) WMF: a plausible META_HEADER at offset 0.
        if isPlausibleMetaHeader(reader, at: 0) {
            return MetafileSignature(format: .wmf, diagnostics: [])
        }

        return MetafileSignature(format: .unknown, diagnostics: [])
    }

    // MARK: - WMF helpers

    /// META_HEADER plausibility ([MS-WMF] §2.3.2.2): Type ∈ {MEMORYMETAFILE
    /// 0x0001, DISKMETAFILE 0x0002} (§2.1.1.18), HeaderSize == 0x0009 (nine
    /// 16-bit WORDs), and Version ∈ {METAVERSION100 0x0100, METAVERSION300
    /// 0x0300} (§2.1.1.19).
    static func isPlausibleMetaHeader(_ reader: ByteReader, at offset: Int) -> Bool {
        guard let type = reader.readUInt16(at: offset),
              let headerSize = reader.readUInt16(at: offset + 2),
              let version = reader.readUInt16(at: offset + 4)
        else { return false }
        let typeOK = type == 0x0001 || type == 0x0002
        let sizeOK = headerSize == 0x0009
        let versionOK = version == 0x0100 || version == 0x0300
        return typeOK && sizeOK && versionOK
    }

    /// META_PLACEABLE Checksum check ([MS-WMF] §2.3.2.3): the stored Checksum
    /// WORD at offset 20 should equal the XOR of the first ten header WORDs
    /// (Key…Reserved, offsets 0, 2, …, 18). Returns a diagnostic on mismatch, or
    /// `nil` when they agree or the bytes are unreadable. Never a rejection.
    static func placeableChecksumDiagnostic(_ reader: ByteReader) -> MetafileSniffDiagnostic? {
        var computed: UInt16 = 0
        for i in 0 ..< 10 {
            guard let word = reader.readUInt16(at: i * 2) else { return nil }
            computed ^= word
        }
        guard let stored = reader.readUInt16(at: 20) else { return nil }
        if computed != stored {
            return .placeableChecksumMismatch(stored: stored, computed: computed)
        }
        return nil
    }
}
