import Foundation
import Testing
@testable import EMFParse

/// Decode coverage for EMR_ABORTPATH (68) ([MS-EMF] §2.3.10.1): a parameterless
/// record, like EMR_BEGINPATH. Golden decode plus a lying-nSize variant proving
/// the walker refuses an overrun and keeps what parsed (primer §8).
@Suite("ABORTPATH record decode")
struct PayloadAbortPathTests {

    @Test("ABORTPATH decodes to the parameterless .abortPath case")
    func golden() throws {
        #expect(try decodeSingle(FixtureBuilder.record(type: 68, payload: [])) == .abortPath)
    }

    @Test("a lying nSize on ABORTPATH stops the walk safely")
    func lyingSize() throws {
        var fixture = FixtureBuilder()
        fixture.appendBytes(FixtureBuilder.header(fixedSize: 108))
        // nSize claims 64 bytes but the record is only its 8-byte header.
        fixture.appendBytes(FixtureBuilder.record(type: 68, payload: [], sizeOverride: 64))
        fixture.appendBytes(FixtureBuilder.eof())
        let file = try EMFFile.parse(fixture.data)
        #expect(file.records.count == 1)   // only the header walked
        #expect(file.diagnostics.contains { if case .sizeExceedsRemaining = $0 { return true }; return false })
    }
}
