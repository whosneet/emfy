import Foundation

/// A rectangle of four 16-bit signed logical coordinates ([MS-WMF] §2.2.2.18,
/// "Rect Object"). The placeable header's BoundingBox is a Rect.
public struct WMFRect16: Sendable, Equatable {
    public var left: Int16
    public var top: Int16
    public var right: Int16
    public var bottom: Int16

    public init(left: Int16, top: Int16, right: Int16, bottom: Int16) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
}

/// The optional Aldus META_PLACEABLE header ([MS-WMF] §2.3.2.3), a 22-byte
/// extension prepended before the META_HEADER that records the destination
/// rectangle and the logical units per inch.
///
/// The checksum is a diagnostic signal, never a reason to reject the file: real
/// files miscompute it ([MS-WMF] §2.3.2.3). `checksumOK` reports whether the
/// stored value matches the XOR of the first ten header WORDs; both values are
/// kept so tooling can show them.
public struct WMFPlaceableHeader: Sendable, Equatable {
    /// `BoundingBox`: the destination rectangle in logical units.
    public var boundingBox: WMFRect16
    /// `Inch`: logical units per inch (1440 twips by convention).
    public var inch: UInt16
    /// `Checksum`: the stored checksum WORD at offset 20.
    public var checksumStored: UInt16
    /// The checksum recomputed as the XOR of the first ten header WORDs.
    public var checksumComputed: UInt16

    public init(
        boundingBox: WMFRect16,
        inch: UInt16,
        checksumStored: UInt16,
        checksumComputed: UInt16
    ) {
        self.boundingBox = boundingBox
        self.inch = inch
        self.checksumStored = checksumStored
        self.checksumComputed = checksumComputed
    }

    /// True when the stored checksum matches the recomputed one.
    public var checksumOK: Bool { checksumStored == checksumComputed }
}

/// The decoded META_HEADER ([MS-WMF] §2.3.2.2), the first record of a standard
/// metafile (or the record immediately after the placeable header).
///
/// Every field here is ADVISORY (§8): `sizeLow`/`sizeHigh`, `numberOfObjects`
/// and `maxRecord` describe the emitter's view of the file and are
/// cross-checked against the walk, never used to bound loops or allocate.
public struct WMFMetaHeader: Sendable, Equatable {
    /// `Type`: MEMORYMETAFILE (0x0001) or DISKMETAFILE (0x0002)
    /// ([MS-WMF] §2.1.1.18). Advisory.
    public var type: UInt16
    /// `HeaderSize`: the header size in 16-bit WORDs; 0x0009 for a valid header.
    public var headerSizeWords: UInt16
    /// `Version`: METAVERSION100 (0x0100) or METAVERSION300 (0x0300)
    /// ([MS-WMF] §2.1.1.19). Advisory.
    public var version: UInt16
    /// `SizeLow`: low-order WORD of the whole-metafile size, in WORDs. Advisory.
    public var sizeLow: UInt16
    /// `SizeHigh`: high-order WORD of the whole-metafile size, in WORDs. Advisory.
    public var sizeHigh: UInt16
    /// `NumberOfObjects`: the size of the object table (max concurrent graphics
    /// objects), NOT the number of creation records. Advisory; it cannot be
    /// reconciled against the walk until the object table lands (W4).
    public var numberOfObjects: UInt16
    /// `MaxRecord`: the largest record size in the metafile, in WORDs. Advisory.
    public var maxRecord: UInt32
    /// `NumberOfMembers`: unused; SHOULD be 0x0000.
    public var numberOfMembers: UInt16

    public init(
        type: UInt16,
        headerSizeWords: UInt16,
        version: UInt16,
        sizeLow: UInt16,
        sizeHigh: UInt16,
        numberOfObjects: UInt16,
        maxRecord: UInt32,
        numberOfMembers: UInt16
    ) {
        self.type = type
        self.headerSizeWords = headerSizeWords
        self.version = version
        self.sizeLow = sizeLow
        self.sizeHigh = sizeHigh
        self.numberOfObjects = numberOfObjects
        self.maxRecord = maxRecord
        self.numberOfMembers = numberOfMembers
    }

    /// The whole-metafile size in 16-bit WORDs, from `sizeHigh:sizeLow`.
    /// `UInt32(UInt16) << 16` cannot overflow (the high 16 bits are zero before
    /// the shift). Advisory.
    public var metafileSizeWords: UInt32 {
        (UInt32(sizeHigh) << 16) | UInt32(sizeLow)
    }
}
