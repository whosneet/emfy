import Foundation
import Testing
@testable import EMFParse

/// Wraps one hand-built record in a minimal clean file (108-byte header +
/// record + EOF, advisory fields set to match) and parses it. The record
/// under test comes back as `records[1]`.
func parseWithSingleRecord(
    _ recordBytes: [UInt8]
) throws -> (file: EMFFile, record: EMFRawRecord) {
    var fixture = FixtureBuilder()
    fixture.appendBytes(
        FixtureBuilder.header(
            fixedSize: 108,
            bytesField: UInt32(108 + recordBytes.count + 20),
            recordsField: 3
        )
    )
    fixture.appendBytes(recordBytes)
    fixture.appendBytes(FixtureBuilder.eof())
    let file = try EMFFile.parse(fixture.data)
    try #require(file.records.count == 3)
    return (file, file.records[1])
}

/// Parses a single hand-built record and decodes its payload.
func decodeSingle(_ recordBytes: [UInt8]) throws -> EMFRecordPayload {
    let (file, record) = try parseWithSingleRecord(recordBytes)
    return file.payload(of: record)
}

/// True when `payload` is the exact enum case expected for `type` — the
/// per-type case mapping under test in the parameterized geometry tests.
func payloadCaseMatches(type: UInt32, payload: EMFRecordPayload) -> Bool {
    switch (type, payload) {
    case (2, .polyBezier(_)), (3, .polygon(_)), (4, .polyline(_)),
         (5, .polyBezierTo(_)), (6, .polylineTo(_)),
         (85, .polyBezier16(_)), (86, .polygon16(_)), (87, .polyline16(_)),
         (88, .polyBezierTo16(_)), (89, .polylineTo16(_)),
         (90, .polyPolyline16(_)), (91, .polyPolygon16(_)):
        return true
    default:
        return false
    }
}

/// Reads a committed corpus file into `Data`, `#require`-ing it exists.
///
/// FRAGILITY NOTE (mirrors `CorpusPathTests`' `CorpusPaths`): the location is
/// resolved from this source file's compile-time path
/// (`<repo>/EMFKit/Tests/EMFParseTests/`), so it breaks if this file moves or
/// the tree is built without its sibling `corpus/`. SPM has no supported way
/// to reference files outside the package.
func requireCorpus(
    _ name: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // EMFParseTests
        .deletingLastPathComponent()    // Tests
        .deletingLastPathComponent()    // EMFKit
        .deletingLastPathComponent()    // repo root
        .appendingPathComponent("corpus")
        .appendingPathComponent(name)
    return try #require(
        try? Data(contentsOf: url),
        "corpus file not readable at \(url.path) — see requireCorpus fragility note",
        sourceLocation: sourceLocation
    )
}

extension EMFRecordPayload {
    /// The shared 32-bit poly payload, whichever geometry case carries it.
    var poly32: PolyPointsPayload? {
        switch self {
        case .polyBezier(let p), .polygon(let p), .polyline(let p),
             .polyBezierTo(let p), .polylineTo(let p):
            return p
        default:
            return nil
        }
    }

    /// The shared 16-bit poly payload, whichever geometry case carries it.
    var poly16: Poly16PointsPayload? {
        switch self {
        case .polyBezier16(let p), .polygon16(let p), .polyline16(let p),
             .polyBezierTo16(let p), .polylineTo16(let p):
            return p
        default:
            return nil
        }
    }

    /// The poly-poly 16-bit payload from either carrying case.
    var polyPoly16: PolyPoly16Payload? {
        switch self {
        case .polyPolyline16(let p), .polyPolygon16(let p):
            return p
        default:
            return nil
        }
    }

    /// The malformed reason, if this is a `.malformed` verdict.
    var malformedReason: EMFPayloadIssue? {
        if case .malformed(_, let reason) = self { return reason }
        return nil
    }
}
