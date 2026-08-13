import Foundation

// MARK: - Font model

/// A decoded font, [MS-EMFPLUS] §2.2.1.3 EmfPlusFont.
///
/// The raw `styleFlags` word is kept (mask-test it; GDI+ may write bits beyond
/// the four documented ones); the boolean accessors report the [MS-EMFPLUS]
/// §2.1.2.4 FontStyle flags. `sizeUnit` is a raw §2.1.1.32 UnitType — a later
/// increment interprets it. `familyName` is decoded from UTF-16LE the same way
/// the GDI text path decodes EMR_EXTTEXTOUTW strings: lone surrogates become
/// U+FFFD, so a hostile name never fails the object.
public struct EMFPlusFont: Sendable, Equatable {
    public let version: UInt32
    public let emSize: Float
    public let sizeUnit: UInt32
    public let styleFlags: Int32
    public let familyName: String

    public init(version: UInt32, emSize: Float, sizeUnit: UInt32, styleFlags: Int32, familyName: String) {
        self.version = version
        self.emSize = emSize
        self.sizeUnit = sizeUnit
        self.styleFlags = styleFlags
        self.familyName = familyName
    }

    /// §2.1.2.4 FontStyleBold (0x1).
    public var isBold: Bool { styleFlags & 0x1 != 0 }
    /// §2.1.2.4 FontStyleItalic (0x2).
    public var isItalic: Bool { styleFlags & 0x2 != 0 }
    /// §2.1.2.4 FontStyleUnderline (0x4).
    public var isUnderline: Bool { styleFlags & 0x4 != 0 }
    /// §2.1.2.4 FontStyleStrikeout (0x8).
    public var isStrikeout: Bool { styleFlags & 0x8 != 0 }
}

// MARK: - Font decode

/// Decodes an EmfPlusFont ([MS-EMFPLUS] §2.2.1.3): Version, EmSize (f32),
/// SizeUnit, FontStyleFlags (i32), Reserved (ignored), Length (a CHARACTER
/// count, not a byte count), then `Length` UTF-16LE code units of FamilyName.
func decodeFont(_ cursor: inout ByteCursor)
    -> Result<EMFPlusFont, EMFPlusObjectDecodeFailure> {
    guard let version = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusFont.Version"))
    }
    guard let emSize = cursor.readFloat() else {
        return .failure(.truncated(field: "EmfPlusFont.EmSize"))
    }
    guard let sizeUnit = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusFont.SizeUnit"))
    }
    guard let styleFlags = cursor.readInt32() else {
        return .failure(.truncated(field: "EmfPlusFont.FontStyleFlags"))
    }
    guard cursor.readUInt32() != nil else {   // Reserved, ignored (§2.2.1.3)
        return .failure(.truncated(field: "EmfPlusFont.Reserved"))
    }
    guard let length = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusFont.Length"))
    }

    // Length counts characters; the name occupies Length × 2 bytes. Validate
    // against the remaining bytes before reading (a lying count fails here).
    let charCount = Int(length)
    guard charCount <= cursor.remaining / 2, let nameBytes = cursor.readBytes(charCount * 2) else {
        return .failure(.arrayCountExceedsBuffer(
            field: "EmfPlusFont.FamilyName", count: length, remainingBytes: cursor.remaining))
    }

    return .success(EMFPlusFont(
        version: version, emSize: emSize, sizeUnit: sizeUnit,
        styleFlags: styleFlags, familyName: utf16LEString(nameBytes)))
}

/// Decodes UTF-16LE bytes into a `String`, matching the GDI text path: lossless
/// (`String(decoding:as:)` substitutes U+FFFD for a lone surrogate and never
/// fails). `bytes` holds an even number of bytes (validated by the caller); a
/// trailing odd byte, if any, is ignored.
private func utf16LEString(_ bytes: Data) -> String {
    let reader = ByteReader(bytes)
    var units: [UInt16] = []
    units.reserveCapacity(reader.count / 2)
    var offset = 0
    while offset + 2 <= reader.count {
        if let unit = reader.readUInt16(at: offset) { units.append(unit) }
        offset += 2
    }
    return String(decoding: units, as: UTF16.self)
}
