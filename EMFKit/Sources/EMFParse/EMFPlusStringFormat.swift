import Foundation

// MARK: - StringFormat model

/// A range of character positions, [MS-EMFPLUS] §2.2.2.8 EmfPlusCharacterRange.
public struct EMFPlusCharacterRange: Sendable, Equatable {
    public let first: Int32
    public let length: Int32

    public init(first: Int32, length: Int32) {
        self.first = first
        self.length = length
    }
}

/// A decoded string format, [MS-EMFPLUS] §2.2.1.9 EmfPlusStringFormat (+ its
/// §2.2.2.44 StringFormatData). The fixed scalar fields are kept raw — a later
/// increment interprets the alignment/trimming/language enumerations and flags.
public struct EMFPlusStringFormat: Sendable, Equatable {
    public let version: UInt32
    public let stringFormatFlags: UInt32
    public let language: UInt32
    public let stringAlignment: UInt32
    public let lineAlign: UInt32
    public let digitSubstitution: UInt32
    public let digitLanguage: UInt32
    public let firstTabOffset: Float
    public let hotkeyPrefix: Int32
    public let leadingMargin: Float
    public let trailingMargin: Float
    public let tracking: Float
    public let trimming: UInt32
    /// The optional tab stops (§2.2.2.44 TabStops); empty when TabStopCount is 0.
    public let tabStops: [Float]
    /// The optional character ranges (§2.2.2.44 CharRange); empty when RangeCount is 0.
    public let characterRanges: [EMFPlusCharacterRange]

    public init(
        version: UInt32, stringFormatFlags: UInt32, language: UInt32,
        stringAlignment: UInt32, lineAlign: UInt32, digitSubstitution: UInt32, digitLanguage: UInt32,
        firstTabOffset: Float, hotkeyPrefix: Int32, leadingMargin: Float, trailingMargin: Float,
        tracking: Float, trimming: UInt32, tabStops: [Float], characterRanges: [EMFPlusCharacterRange]
    ) {
        self.version = version
        self.stringFormatFlags = stringFormatFlags
        self.language = language
        self.stringAlignment = stringAlignment
        self.lineAlign = lineAlign
        self.digitSubstitution = digitSubstitution
        self.digitLanguage = digitLanguage
        self.firstTabOffset = firstTabOffset
        self.hotkeyPrefix = hotkeyPrefix
        self.leadingMargin = leadingMargin
        self.trailingMargin = trailingMargin
        self.tracking = tracking
        self.trimming = trimming
        self.tabStops = tabStops
        self.characterRanges = characterRanges
    }
}

// MARK: - StringFormat decode

/// Decodes an EmfPlusStringFormat ([MS-EMFPLUS] §2.2.1.9): the fifteen fixed
/// fields (ending in the signed TabStopCount and RangeCount), then the
/// §2.2.2.44 StringFormatData — TabStopCount floats followed by RangeCount
/// EmfPlusCharacterRange pairs. Both counts are signed: a negative count, or a
/// count larger than the remaining bytes, fails typed before any allocation.
func decodeStringFormat(_ cursor: inout ByteCursor)
    -> Result<EMFPlusStringFormat, EMFPlusObjectDecodeFailure> {
    guard let version = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusStringFormat.Version"))
    }
    guard let stringFormatFlags = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusStringFormat.StringFormatFlags"))
    }
    guard let language = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusStringFormat.Language"))
    }
    guard let stringAlignment = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusStringFormat.StringAlignment"))
    }
    guard let lineAlign = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusStringFormat.LineAlign"))
    }
    guard let digitSubstitution = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusStringFormat.DigitSubstitution"))
    }
    guard let digitLanguage = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusStringFormat.DigitLanguage"))
    }
    guard let firstTabOffset = cursor.readFloat() else {
        return .failure(.truncated(field: "EmfPlusStringFormat.FirstTabOffset"))
    }
    guard let hotkeyPrefix = cursor.readInt32() else {
        return .failure(.truncated(field: "EmfPlusStringFormat.HotkeyPrefix"))
    }
    guard let leadingMargin = cursor.readFloat() else {
        return .failure(.truncated(field: "EmfPlusStringFormat.LeadingMargin"))
    }
    guard let trailingMargin = cursor.readFloat() else {
        return .failure(.truncated(field: "EmfPlusStringFormat.TrailingMargin"))
    }
    guard let tracking = cursor.readFloat() else {
        return .failure(.truncated(field: "EmfPlusStringFormat.Tracking"))
    }
    guard let trimming = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusStringFormat.Trimming"))
    }
    guard let tabStopCount = cursor.readInt32() else {
        return .failure(.truncated(field: "EmfPlusStringFormat.TabStopCount"))
    }
    guard let rangeCount = cursor.readInt32() else {
        return .failure(.truncated(field: "EmfPlusStringFormat.RangeCount"))
    }

    // Both counts are signed; a negative value is invalid, and the arrays
    // (tabStops: n×4, ranges: n×8 bytes) are validated against the remaining
    // bytes before allocation — overflow-free, one array at a time.
    guard tabStopCount >= 0 else {
        return .failure(.arrayCountExceedsBuffer(
            field: "EmfPlusStringFormatData.TabStopCount",
            count: UInt32(bitPattern: tabStopCount), remainingBytes: cursor.remaining))
    }
    guard let tabStops = cursor.readFloats(count: Int(tabStopCount)) else {
        return .failure(.arrayCountExceedsBuffer(
            field: "EmfPlusStringFormatData.TabStops",
            count: UInt32(bitPattern: tabStopCount), remainingBytes: cursor.remaining))
    }
    guard rangeCount >= 0, Int(rangeCount) <= cursor.remaining / 8 else {
        return .failure(.arrayCountExceedsBuffer(
            field: "EmfPlusStringFormatData.CharRange",
            count: UInt32(bitPattern: rangeCount), remainingBytes: cursor.remaining))
    }
    var characterRanges: [EMFPlusCharacterRange] = []
    characterRanges.reserveCapacity(Int(rangeCount))
    for _ in 0 ..< Int(rangeCount) {
        guard let first = cursor.readInt32(), let length = cursor.readInt32() else {
            return .failure(.truncated(field: "EmfPlusCharacterRange"))
        }
        characterRanges.append(EMFPlusCharacterRange(first: first, length: length))
    }

    return .success(EMFPlusStringFormat(
        version: version, stringFormatFlags: stringFormatFlags, language: language,
        stringAlignment: stringAlignment, lineAlign: lineAlign,
        digitSubstitution: digitSubstitution, digitLanguage: digitLanguage,
        firstTabOffset: firstTabOffset, hotkeyPrefix: hotkeyPrefix,
        leadingMargin: leadingMargin, trailingMargin: trailingMargin, tracking: tracking,
        trimming: trimming, tabStops: tabStops, characterRanges: characterRanges))
}
