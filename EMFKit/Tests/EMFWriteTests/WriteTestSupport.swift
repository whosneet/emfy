import Foundation
import Testing
import EMFParse
import EMFWrite

/// A little-endian byte builder for hand-constructing record fixtures in the
/// writer tests — the write-side twin of EMFParseTests' `FixtureBuilder`,
/// duplicated here because that one lives in a different test target.
struct LE {
    private(set) var bytes: [UInt8] = []
    var count: Int { bytes.count }

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8((v >> 8) & 0xFF))
    }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) {
        bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8((v >> 8) & 0xFF))
        bytes.append(UInt8((v >> 16) & 0xFF)); bytes.append(UInt8((v >> 24) & 0xFF))
    }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func raw(_ v: [UInt8]) { bytes.append(contentsOf: v) }
    mutating func utf16(_ s: String) { for unit in s.utf16 { u16(unit) } }
    mutating func zeros(_ n: Int) { if n > 0 { bytes.append(contentsOf: repeatElement(0, count: n)) } }

    /// A full record: Type, Size (8 + body, unless overridden), body.
    static func record(_ type: UInt32, _ body: [UInt8], size: UInt32? = nil) -> [UInt8] {
        var b = LE()
        b.u32(type)
        b.u32(size ?? UInt32(8 + body.count))
        b.raw(body)
        return b.bytes
    }

    /// A 108-byte EMR_HEADER (HeaderExtension2) with recognisable fields, enough
    /// for `EMFFile.parse` to accept a wrapped single record.
    static func header108(records: UInt32, bytes: UInt32) -> [UInt8] {
        var b = LE()
        b.u32(1)              // iType
        b.u32(108)            // nSize
        b.i32(0); b.i32(0); b.i32(400); b.i32(300)        // rclBounds
        b.i32(0); b.i32(0); b.i32(9000); b.i32(7000)      // rclFrame
        b.u32(0x464D_4520)    // signature
        b.u32(0x0001_0000)    // version
        b.u32(bytes)          // Bytes
        b.u32(records)        // Records
        b.u16(1)              // Handles
        b.u16(0)              // Reserved
        b.u32(0); b.u32(0)    // nDescription, offDescription
        b.u32(0)              // nPalEntries
        b.i32(401); b.i32(301)  // Device
        b.i32(98); b.i32(72)    // Millimeters
        b.u32(0); b.u32(0); b.u32(0)  // ext1
        b.u32(0); b.u32(0)            // ext2
        return b.bytes
    }

    /// EMR_EOF, 20 bytes, canonical form.
    static func eof() -> [UInt8] {
        record(14, { var b = LE(); b.u32(0); b.u32(0x10); b.u32(20); return b.bytes }(), size: 20)
    }
}

/// Wraps one hand-built record in a minimal clean EMF and parses it; the record
/// under test is `records[1]`.
func parseSingle(_ recordBytes: [UInt8]) throws -> (file: EMFFile, record: EMFRawRecord) {
    var fixture = LE()
    let total = 108 + recordBytes.count + 20
    fixture.raw(LE.header108(records: 3, bytes: UInt32(total)))
    fixture.raw(recordBytes)
    fixture.raw(LE.eof())
    let file = try EMFFile.parse(Data(fixture.bytes))
    try #require(file.records.count == 3)
    return (file, file.records[1])
}

/// Asserts that a canonical record decodes to a payload `check` approves, and
/// that re-encoding that payload reproduces the original bytes exactly — the
/// per-record round-trip gate (decode → encode is byte-identical).
func assertRoundTrip(
    _ recordBytes: [UInt8],
    check: (EMFRecordPayload) -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let (file, record) = try parseSingle(recordBytes)
    let payload = file.payload(of: record)
    #expect(check(payload), "unexpected decoded payload: \(payload)", sourceLocation: sourceLocation)
    #expect(
        EMFRecordEncoder.isFaithfullyEncodable(payload),
        "payload reported not faithfully encodable: \(payload)",
        sourceLocation: sourceLocation
    )
    let encoded = try EMFRecordEncoder.encode(payload)
    #expect(
        [UInt8](encoded) == recordBytes,
        "re-encoded bytes differ from original (\(encoded.count) vs \(recordBytes.count) bytes)",
        sourceLocation: sourceLocation
    )
}

// MARK: - Corpus access

/// `<repo>/corpus/<name>`. Same `#filePath` anchoring (and fragility) as
/// EMFParseTests' `requireCorpus`.
func repoRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // EMFWriteTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // EMFKit
        .deletingLastPathComponent()   // repo root
}

func corpusData(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> Data {
    let url = repoRootURL().appendingPathComponent("corpus").appendingPathComponent(name)
    return try #require(try? Data(contentsOf: url), "corpus file not readable at \(url.path)",
                        sourceLocation: sourceLocation)
}

/// The committed EMF/EMZ corpus file names (no WMF — that is E0c).
func committedEMFCorpus() -> [String] {
    let dir = repoRootURL().appendingPathComponent("corpus")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasSuffix(".emf") || $0.hasSuffix(".emz") }.sorted()
}

/// Every file under `corpus-local/` (recursively), or an empty list when the
/// directory is absent (it is gitignored and may not exist). Work-sourced files
/// there are CONFIDENTIAL — callers must report counts only, never these paths.
func corpusLocalFiles() -> [URL] {
    let dir = repoRootURL().appendingPathComponent("corpus-local")
    guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {
        return []
    }
    var out: [URL] = []
    for case let url as URL in e {
        let ext = url.pathExtension.lowercased()
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
           ext == "emf" || ext == "emz" {
            out.append(url)
        }
    }
    return out
}
