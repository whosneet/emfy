import Foundation
import EMFParse

/// Emfy's private layer table, persisted as ONE EMR_COMMENT record ([MS-EMF]
/// §2.3.3 EMR_COMMENT). EMF has no layer concept, so Emfy records the layer
/// structure — each layer's `{name, hidden, locked}` and its element COUNT, in
/// z-order (back to front) — in a single private comment. On import the z-ordered
/// elements are split back into layers by those counts.
///
/// A count table (rather than per-record begin/end brackets) is used because it is
/// independent of where each element's draw record sits: an EMF+ file packs many
/// drawing records into one EMR_COMMENT carrier, so several elements share a
/// record index and no positional bracket could separate them — but their z-order
/// is always well defined, so a count split round-trips GDI and EMF+ alike, and
/// an empty layer (count 0) costs nothing.
///
/// The 8-byte signature makes other readers — and Emfy's own EMF+ detector
/// (CommentIdentifier 0x2B464D45) — treat the record as an unknown private comment
/// that draws nothing, so a file with the table renders identically everywhere.
/// §8: every field is bounds-checked on decode, with hard caps; a malformed or
/// foreign comment decodes to `nil` and the importer falls back to one layer.
public enum EMFLayerMarker {

    /// EMR_COMMENT type id ([MS-EMF] §2.1.1).
    static let commentType: UInt32 = 70

    /// The 8-byte CommentData signature identifying an Emfy layer table. ASCII
    /// "EmfyLyr1"; its leading little-endian word (0x79666D45) matches no public
    /// CommentIdentifier — EMF+ is 0x2B464D45, EMR_COMMENT_EMFSPOOL/PUBLIC use
    /// 0x00000000/0x00000001 ([MS-EMF] §2.3.3.1–§2.3.3.4).
    static let signature: [UInt8] = Array("EmfyLyr1".utf8)

    /// Table-record kind byte (distinguishes this layout for forward-compatibility).
    static let tableKind: UInt8 = 2

    /// Hard cap on a layer name's UTF-8 byte length (§8). The editor limits names
    /// to 256 characters; 256 characters are at most 1024 UTF-8 bytes.
    public static let maxNameBytes = 1024

    /// Hard cap on the number of layers a table may carry (§8). A table declaring
    /// more falls back to one layer on import.
    public static let maxLayers = 256

    /// One layer's persisted attributes and element count.
    public struct LayerInfo: Sendable, Equatable {
        public var name: String
        public var hidden: Bool
        public var locked: Bool
        /// Number of elements in this layer, in z-order.
        public var count: Int

        public init(name: String, hidden: Bool, locked: Bool, count: Int) {
            self.name = name
            self.hidden = hidden
            self.locked = locked
            self.count = count
        }
    }

    private static let hiddenBit: UInt8 = 0x01
    private static let lockedBit: UInt8 = 0x02

    // MARK: - Encode

    /// The full EMR_COMMENT record bytes for the layer table.
    public static func table(_ layers: [LayerInfo]) -> [UInt8] {
        var data = ByteWriter()
        data.appendBytes(signature)
        data.appendUInt8(tableKind)
        data.appendUInt8(0)                               // reserved
        data.appendUInt16(UInt16(clamping: layers.count))
        for layer in layers {
            var nameBytes = Array(layer.name.utf8)
            if nameBytes.count > maxNameBytes { nameBytes = Array(nameBytes.prefix(maxNameBytes)) }
            var flags: UInt8 = 0
            if layer.hidden { flags |= hiddenBit }
            if layer.locked { flags |= lockedBit }
            data.appendUInt8(flags)
            data.appendUInt8(0)                           // reserved
            data.appendUInt32(UInt32(clamping: max(0, layer.count)))
            data.appendUInt16(UInt16(clamping: nameBytes.count))
            data.appendBytes(nameBytes)
        }
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

    /// Decodes the layer table from one EMR_COMMENT record's bytes (from its `Type`
    /// field), or `nil` when the record is not an Emfy table or is malformed. The
    /// input may be any length and carry any field values — a short record, an
    /// absurd DataSize/layerCount/nameLength, or a foreign CommentIdentifier all
    /// return `nil`, never a trap (§8).
    public static func decodeTable(recordBytes b: [UInt8]) -> [LayerInfo]? {
        guard b.count >= 12, u32(b, 0) == commentType else { return nil }
        let dataSize = Int(u32(b, 8))
        let dataEnd = 12 + dataSize
        guard dataSize >= signature.count + 4, dataEnd <= b.count else { return nil }
        for i in 0 ..< signature.count where b[12 + i] != signature[i] { return nil }

        var o = 12 + signature.count
        guard b[o] == tableKind else { return nil }
        o += 1
        o += 1                                            // reserved
        guard o + 2 <= dataEnd else { return nil }
        let layerCount = Int(u16(b, o)); o += 2
        guard layerCount >= 0, layerCount <= maxLayers else { return nil }

        var layers: [LayerInfo] = []
        layers.reserveCapacity(layerCount)
        for _ in 0 ..< layerCount {
            // flags(1) reserved(1) count(4) nameLen(2) = 8 fixed bytes per entry.
            guard o + 8 <= dataEnd else { return nil }
            let flags = b[o]; o += 1
            o += 1                                        // reserved
            let count = Int(u32(b, o)); o += 4
            let nameLen = Int(u16(b, o)); o += 2
            guard nameLen >= 0, nameLen <= maxNameBytes, o + nameLen <= dataEnd else { return nil }
            let name = String(decoding: b[o ..< o + nameLen], as: UTF8.self)
            o += nameLen
            layers.append(LayerInfo(name: name, hidden: flags & hiddenBit != 0,
                                    locked: flags & lockedBit != 0, count: count))
        }
        return layers
    }

    /// Whether an EMR_COMMENT record's bytes are an Emfy layer table.
    public static func isLayerTable(recordBytes: [UInt8]) -> Bool {
        decodeTable(recordBytes: recordBytes) != nil
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }
}
