import Foundation
import EMFParse

/// Emfy's private layer markers, persisted as EMR_COMMENT records
/// ([MS-EMF] §2.3.3 EMR_COMMENT). EMF has no layer concept, so Emfy brackets each
/// layer's drawing records with a begin/end marker comment carrying the layer's
/// `{name, hidden, locked}`. The 8-byte CommentData signature makes other readers
/// — and Emfy's own EMF+ detector (CommentIdentifier 0x2B464D45) — treat the
/// record as an unknown private comment that draws nothing, so a file with
/// markers renders identically everywhere.
///
/// §8: every field is bounds-checked on decode, with a hard cap on the name
/// length; a malformed or foreign comment decodes to `nil`, and the importer
/// falls back to one layer rather than ever trapping.
public enum EMFLayerMarker {

    /// EMR_COMMENT type id ([MS-EMF] §2.1.1).
    static let commentType: UInt32 = 70

    /// The 8-byte CommentData signature identifying an Emfy layer marker. ASCII
    /// "EmfyLyr1"; its leading little-endian word (0x79666D45) matches no public
    /// CommentIdentifier — EMF+ is 0x2B464D45, EMR_COMMENT_EMFSPOOL/PUBLIC use
    /// 0x00000000/0x00000001 ([MS-EMF] §2.3.3.1–§2.3.3.4) — so no conformant
    /// reader mistakes it for a known comment.
    static let signature: [UInt8] = Array("EmfyLyr1".utf8)

    /// Hard cap on a marker name's UTF-8 byte length (§8). The editor limits names
    /// to 256 characters; 256 characters are at most 1024 UTF-8 bytes.
    public static let maxNameBytes = 1024

    /// Hard cap on the number of layers an import rebuilds from markers (§8). A
    /// hostile file with more layer-begin markers than this falls back to one layer.
    public static let maxLayers = 256

    public enum Kind: UInt8, Sendable, Equatable { case begin = 0, end = 1 }

    /// A decoded marker: its kind, and (for a begin) the layer's attributes.
    public struct Marker: Sendable, Equatable {
        public var kind: Kind
        public var name: String
        public var hidden: Bool
        public var locked: Bool

        public init(kind: Kind, name: String, hidden: Bool, locked: Bool) {
            self.kind = kind
            self.name = name
            self.hidden = hidden
            self.locked = locked
        }
    }

    private static let hiddenBit: UInt8 = 0x01
    private static let lockedBit: UInt8 = 0x02

    // MARK: - Encode

    /// The full EMR_COMMENT record bytes for a layer-begin marker.
    public static func begin(name: String, hidden: Bool, locked: Bool) -> [UInt8] {
        encode(kind: .begin, name: name, hidden: hidden, locked: locked)
    }

    /// The full EMR_COMMENT record bytes for a layer-end marker.
    public static func end() -> [UInt8] {
        encode(kind: .end, name: "", hidden: false, locked: false)
    }

    private static func encode(kind: Kind, name: String, hidden: Bool, locked: Bool) -> [UInt8] {
        var nameBytes = Array(name.utf8)
        if nameBytes.count > maxNameBytes { nameBytes = Array(nameBytes.prefix(maxNameBytes)) }
        var flags: UInt8 = 0
        if hidden { flags |= hiddenBit }
        if locked { flags |= lockedBit }

        // CommentData: signature(8) kind(1) flags(1) reserved(2) nameLen(4) name.
        var data = ByteWriter()
        data.appendBytes(signature)
        data.appendUInt8(kind.rawValue)
        data.appendUInt8(flags)
        data.appendUInt16(0)
        data.appendUInt32(UInt32(nameBytes.count))
        data.appendBytes(nameBytes)
        let commentData = data.bytes

        // EMR_COMMENT frame: Type(4) Size(4) DataSize(4) CommentData, padded to 4.
        let unpadded = 12 + commentData.count
        let size = (unpadded + 3) & ~3
        var rec = ByteWriter(capacity: size)
        rec.appendUInt32(commentType)
        rec.appendUInt32(UInt32(size))
        rec.appendUInt32(UInt32(commentData.count))
        rec.appendBytes(commentData)
        rec.appendZeros(size - unpadded)
        return rec.bytes
    }

    // MARK: - Decode

    /// Decodes a layer marker from one EMR_COMMENT record's bytes (from its `Type`
    /// field), or `nil` when the record is not an Emfy marker or is malformed. The
    /// input may be any length and carry any field values — a short record, an
    /// absurd DataSize/nameLength, or a foreign CommentIdentifier all return `nil`,
    /// never a trap (§8).
    public static func decode(recordBytes: [UInt8]) -> Marker? {
        // Record header: Type(4) Size(4) DataSize(4).
        guard recordBytes.count >= 12, u32(recordBytes, 0) == commentType else { return nil }
        let dataSize = Int(u32(recordBytes, 8))
        // CommentData must hold at least signature(8) + kind/flags/reserved(4) + nameLen(4).
        guard dataSize >= signature.count + 8, 12 + dataSize <= recordBytes.count else { return nil }
        for i in 0 ..< signature.count where recordBytes[12 + i] != signature[i] { return nil }

        var o = 12 + signature.count
        guard let kind = Kind(rawValue: recordBytes[o]) else { return nil }
        o += 1
        let flags = recordBytes[o]; o += 1
        o += 2  // reserved
        let nameLen = Int(u32(recordBytes, o)); o += 4
        guard nameLen >= 0, nameLen <= maxNameBytes,
              o + nameLen <= 12 + dataSize, o + nameLen <= recordBytes.count else { return nil }
        let name = String(decoding: recordBytes[o ..< o + nameLen], as: UTF8.self)
        return Marker(kind: kind, name: name, hidden: flags & hiddenBit != 0, locked: flags & lockedBit != 0)
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
}
