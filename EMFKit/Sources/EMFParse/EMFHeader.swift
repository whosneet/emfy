import Foundation

/// A signed rectangle of four 32-bit logical coordinates ([MS-EMF] §2.2.19,
/// "RectL"). Both `rclBounds` and `rclFrame` in the header are RectL and are
/// inclusive-inclusive.
public struct RectL: Sendable, Equatable {
    public var left: Int32
    public var top: Int32
    public var right: Int32
    public var bottom: Int32

    public init(left: Int32, top: Int32, right: Int32, bottom: Int32) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
}

/// A pair of signed 32-bit dimensions ([MS-EMF] §2.2.21, "SizeL"). Used for
/// the header's `Device` and `Millimeters` reference-device sizes.
public struct SizeL: Sendable, Equatable {
    public var cx: Int32
    public var cy: Int32

    public init(cx: Int32, cy: Int32) {
        self.cx = cx
        self.cy = cy
    }
}

/// HeaderExtension1 fields ([MS-EMF] §2.2.10), present when the header's
/// fixed part is at least 100 bytes.
public struct EMFHeaderExtension1: Sendable, Equatable {
    /// Size in bytes of the pixel-format descriptor, or 0 if absent.
    public var cbPixelFormat: UInt32
    /// Offset from the record start to the pixel-format descriptor, or 0.
    public var offPixelFormat: UInt32
    /// Non-zero if OpenGL records are present.
    public var bOpenGL: UInt32

    public init(cbPixelFormat: UInt32, offPixelFormat: UInt32, bOpenGL: UInt32) {
        self.cbPixelFormat = cbPixelFormat
        self.offPixelFormat = offPixelFormat
        self.bOpenGL = bOpenGL
    }
}

/// HeaderExtension2 fields ([MS-EMF] §2.2.11), present when the header's
/// fixed part is at least 108 bytes. The device-surface size in micrometres.
public struct EMFHeaderExtension2: Sendable, Equatable {
    public var micrometersX: UInt32
    public var micrometersY: UInt32

    public init(micrometersX: UInt32, micrometersY: UInt32) {
        self.micrometersX = micrometersX
        self.micrometersY = micrometersY
    }
}

/// Which fixed-part variant of the EMR_HEADER a file uses, decided by the
/// HeaderSize algorithm ([MS-EMF] §2.3.4.2), never by `Size` alone.
public enum EMFHeaderVariant: Sendable, Equatable {
    /// 88-byte fixed part; no extensions.
    case base
    /// 100-byte fixed part; HeaderExtension1 present.
    case extension1
    /// 108-byte fixed part; HeaderExtension1 and HeaderExtension2 present.
    case extension2
}

/// The decoded EMR_HEADER ([MS-EMF] §2.2.9 header object, wrapped by the
/// §2.3.4.2 header record). All multi-byte fields are little-endian.
public struct EMFHeader: Sendable, Equatable {
    /// `rclBounds`: the drawing bounds in logical units, inclusive-inclusive
    /// ([MS-EMF] §2.2.9; see primer delta D1 — the spec says logical units
    /// while real files record device-pixel-scale values).
    public var bounds: RectL
    /// `rclFrame`: the drawing frame in hundredths of a millimetre,
    /// inclusive-inclusive. Drives physical size and aspect ratio.
    public var frame: RectL
    /// `RecordSignature`: must be 0x464D4520 (" EMF") for a valid header.
    public var recordSignature: UInt32
    /// `Version` of the metafile format.
    public var version: UInt32
    /// `Bytes`: emitter-declared file size. Advisory only — never used for
    /// loop bounds or allocation ([MS-EMF] §2.2.9; primer §8 / delta D4).
    public var bytes: UInt32
    /// `Records`: emitter-declared record count. Advisory only; a real corpus
    /// file under-reports this by one (primer §8 / delta D4).
    public var records: UInt32
    /// `Handles`: size of the object handle table (1-based; index 0 reserved).
    public var handles: UInt16
    /// `nDescription`: number of UTF-16 characters in the description string
    /// (0 if none).
    public var nDescription: UInt32
    /// `offDescription`: byte offset from the record start to the description
    /// string (0 if none).
    public var offDescription: UInt32
    /// `nPalEntries`: number of palette entries in the metafile.
    public var nPalEntries: UInt32
    /// `Device`: reference-device size in pixels.
    public var device: SizeL
    /// `Millimeters`: reference-device size in millimetres.
    public var millimeters: SizeL
    /// HeaderExtension1 fields, present for `.extension1` and `.extension2`.
    public var extension1: EMFHeaderExtension1?
    /// HeaderExtension2 fields, present for `.extension2` only.
    public var extension2: EMFHeaderExtension2?
    /// The description string, decoded as UTF-16LE only when `nDescription`
    /// is non-zero and the byte range lies fully inside the header record.
    /// `nil` when absent or unreadable.
    public var description: String?
    /// The detected header variant.
    public var variant: EMFHeaderVariant

    public init(
        bounds: RectL,
        frame: RectL,
        recordSignature: UInt32,
        version: UInt32,
        bytes: UInt32,
        records: UInt32,
        handles: UInt16,
        nDescription: UInt32,
        offDescription: UInt32,
        nPalEntries: UInt32,
        device: SizeL,
        millimeters: SizeL,
        extension1: EMFHeaderExtension1?,
        extension2: EMFHeaderExtension2?,
        description: String?,
        variant: EMFHeaderVariant
    ) {
        self.bounds = bounds
        self.frame = frame
        self.recordSignature = recordSignature
        self.version = version
        self.bytes = bytes
        self.records = records
        self.handles = handles
        self.nDescription = nDescription
        self.offDescription = offDescription
        self.nPalEntries = nPalEntries
        self.device = device
        self.millimeters = millimeters
        self.extension1 = extension1
        self.extension2 = extension2
        self.description = description
        self.variant = variant
    }
}
