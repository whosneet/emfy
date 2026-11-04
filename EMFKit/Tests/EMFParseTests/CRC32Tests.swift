import Foundation
import Testing
@testable import EMFParse

/// CRC-32/IEEE against published check values. These are the same constants
/// `GzipInflate` validates a gzip trailer with, so pinning them guards the
/// whole gzip-integrity path.
@Suite("CRC-32/IEEE")
struct CRC32Tests {
    @Test("empty input is 0")
    func empty() {
        #expect(CRC32.checksum([UInt8]()) == 0x0000_0000)
    }

    @Test("the standard \"123456789\" check value is 0xCBF43926")
    func standardCheckValue() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test("the quick-brown-fox vector is 0x414FA339")
    func quickBrownFox() {
        let input = Array("The quick brown fox jumps over the lazy dog".utf8)
        #expect(CRC32.checksum(input) == 0x414F_A339)
    }

    @Test("a single zero byte is 0xD202EF8D")
    func singleZeroByte() {
        #expect(CRC32.checksum([0x00]) == 0xD202_EF8D)
    }

    @Test("Data and [UInt8] produce the same checksum")
    func dataAndArrayAgree() {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03]
        #expect(CRC32.checksum(bytes) == CRC32.checksum(Data(bytes)))
    }
}
