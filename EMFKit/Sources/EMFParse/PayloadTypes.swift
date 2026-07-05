import Foundation

/// A signed 32-bit point ([MS-WMF] §2.2.2.15, "PointL"). Logical units.
public struct PointL: Sendable, Equatable {
    public var x: Int32
    public var y: Int32

    public init(x: Int32, y: Int32) {
        self.x = x
        self.y = y
    }
}

/// A signed 16-bit point ([MS-WMF] §2.2.2.16, "PointS"). Used by the
/// 16-bit geometry records (EMR_*16). Logical units.
public struct PointS: Sendable, Equatable {
    public var x: Int16
    public var y: Int16

    public init(x: Int16, y: Int16) {
        self.x = x
        self.y = y
    }
}

/// A device-independent color ([MS-WMF] §2.2.2.8, "ColorRef").
/// On-disk byte order is Red, Green, Blue, Reserved — i.e. the familiar
/// 0x00BBGGRR COLORREF read little-endian puts red in the lowest byte.
public struct ColorRef: Sendable, Equatable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    /// MUST NOT be used and MUST be ignored per the spec; carried for
    /// round-trip fidelity only.
    public var reserved: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, reserved: UInt8 = 0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.reserved = reserved
    }
}

/// A two-dimensional linear transform ([MS-EMF] §2.2.28, "XForm"): six
/// little-endian FLOAT values in file order M11, M12, M21, M22, Dx, Dy.
///
/// Point mapping per the spec:
///     X' = M11 * X + M21 * Y + Dx
///     Y' = M12 * X + M22 * Y + Dy
///
/// Decoders reject non-finite values (NaN/Inf) with a `.malformed` payload —
/// hostile floats never propagate out of EMFParse.
public struct XForm: Sendable, Equatable {
    public var m11: Float
    public var m12: Float
    public var m21: Float
    public var m22: Float
    public var dx: Float
    public var dy: Float

    public init(m11: Float, m12: Float, m21: Float, m22: Float, dx: Float, dy: Float) {
        self.m11 = m11
        self.m12 = m12
        self.m21 = m21
        self.m22 = m22
        self.dx = dx
        self.dy = dy
    }

    /// True when every component is finite (no NaN, no infinity).
    public var isFinite: Bool {
        m11.isFinite && m12.isFinite && m21.isFinite
            && m22.isFinite && dx.isFinite && dy.isFinite
    }
}

/// Mapping mode ([MS-EMF] §2.1.21, MapMode enumeration). Out-of-range values
/// decode to `.unknown` rather than failing (log-and-skip).
public enum MapMode: Sendable, Equatable {
    /// MM_TEXT (0x01): 1 logical unit = 1 device pixel; positive y is down.
    case text
    /// MM_LOMETRIC (0x02): 0.1 mm units; positive y is up.
    case loMetric
    /// MM_HIMETRIC (0x03): 0.01 mm units; positive y is up.
    case hiMetric
    /// MM_LOENGLISH (0x04): 0.01 inch units; positive y is up.
    case loEnglish
    /// MM_HIENGLISH (0x05): 0.001 inch units; positive y is up.
    case hiEnglish
    /// MM_TWIPS (0x06): 1/1440 inch units; positive y is up.
    case twips
    /// MM_ISOTROPIC (0x07): arbitrary units, x and y equally scaled.
    case isotropic
    /// MM_ANISOTROPIC (0x08): arbitrary units, independently scaled axes.
    case anisotropic
    case unknown(UInt32)

    public init(_ raw: UInt32) {
        switch raw {
        case 0x01: self = .text
        case 0x02: self = .loMetric
        case 0x03: self = .hiMetric
        case 0x04: self = .loEnglish
        case 0x05: self = .hiEnglish
        case 0x06: self = .twips
        case 0x07: self = .isotropic
        case 0x08: self = .anisotropic
        default: self = .unknown(raw)
        }
    }
}

/// Background mix mode ([MS-EMF] §2.1.4, BackgroundMode enumeration).
public enum BackgroundMode: Sendable, Equatable {
    /// TRANSPARENT (0x0001): background remains untouched.
    case transparent
    /// OPAQUE (0x0002): background filled with the background color first.
    case opaque
    case unknown(UInt32)

    public init(_ raw: UInt32) {
        switch raw {
        case 0x0001: self = .transparent
        case 0x0002: self = .opaque
        default: self = .unknown(raw)
        }
    }
}

/// Polygon fill mode ([MS-EMF] §2.1.27, PolygonFillMode enumeration).
public enum PolygonFillMode: Sendable, Equatable {
    /// ALTERNATE (0x01): even-odd fill.
    case alternate
    /// WINDING (0x02): nonzero-winding fill.
    case winding
    case unknown(UInt32)

    public init(_ raw: UInt32) {
        switch raw {
        case 0x01: self = .alternate
        case 0x02: self = .winding
        default: self = .unknown(raw)
        }
    }
}

/// World-transform modification mode ([MS-EMF] §2.1.24,
/// ModifyWorldTransformMode enumeration).
public enum ModifyWorldTransformMode: Sendable, Equatable {
    /// MWT_IDENTITY (0x01): reset to identity; the record's transform data
    /// is ignored.
    case identity
    /// MWT_LEFTMULTIPLY (0x02): record's transform is the LEFT multiplicand,
    /// the current transform the right.
    case leftMultiply
    /// MWT_RIGHTMULTIPLY (0x03): record's transform is the RIGHT
    /// multiplicand, the current transform the left.
    case rightMultiply
    /// MWT_SET (0x04): replace the current transform.
    case set
    case unknown(UInt32)

    public init(_ raw: UInt32) {
        switch raw {
        case 0x01: self = .identity
        case 0x02: self = .leftMultiply
        case 0x03: self = .rightMultiply
        case 0x04: self = .set
        default: self = .unknown(raw)
        }
    }
}

/// Predefined graphics objects ([MS-EMF] §2.1.31, StockObject enumeration).
/// Stock indices have the most-significant bit set; 0x80000009 is not
/// defined and, like any unlisted high-bit value, decodes to `.unknownStock`.
public enum StockObject: Sendable, Equatable {
    case whiteBrush          // 0x80000000
    case ltGrayBrush         // 0x80000001
    case grayBrush           // 0x80000002
    case dkGrayBrush         // 0x80000003
    case blackBrush          // 0x80000004
    case nullBrush           // 0x80000005
    case whitePen            // 0x80000006
    case blackPen            // 0x80000007
    case nullPen             // 0x80000008
    case oemFixedFont        // 0x8000000A
    case ansiFixedFont       // 0x8000000B
    case ansiVarFont         // 0x8000000C
    case systemFont          // 0x8000000D
    case deviceDefaultFont   // 0x8000000E
    case defaultPalette      // 0x8000000F
    case systemFixedFont     // 0x80000010
    case defaultGuiFont      // 0x80000011
    case dcBrush             // 0x80000012
    case dcPen               // 0x80000013
    case unknownStock(UInt32)

    public init(_ raw: UInt32) {
        switch raw {
        case 0x8000_0000: self = .whiteBrush
        case 0x8000_0001: self = .ltGrayBrush
        case 0x8000_0002: self = .grayBrush
        case 0x8000_0003: self = .dkGrayBrush
        case 0x8000_0004: self = .blackBrush
        case 0x8000_0005: self = .nullBrush
        case 0x8000_0006: self = .whitePen
        case 0x8000_0007: self = .blackPen
        case 0x8000_0008: self = .nullPen
        case 0x8000_000A: self = .oemFixedFont
        case 0x8000_000B: self = .ansiFixedFont
        case 0x8000_000C: self = .ansiVarFont
        case 0x8000_000D: self = .systemFont
        case 0x8000_000E: self = .deviceDefaultFont
        case 0x8000_000F: self = .defaultPalette
        case 0x8000_0010: self = .systemFixedFont
        case 0x8000_0011: self = .defaultGuiFont
        case 0x8000_0012: self = .dcBrush
        case 0x8000_0013: self = .dcPen
        default: self = .unknownStock(raw)
        }
    }
}

/// Region combination mode ([MS-EMF] §2.1.29, RegionMode enumeration).
/// Carried by EMR_SELECTCLIPPATH and EMR_EXTSELECTCLIPRGN to say how the new
/// region combines with the current clipping region. Out-of-range values
/// decode to `.unknown` rather than failing (log-and-skip).
public enum RegionMode: Sendable, Equatable {
    /// RGN_AND (0x01): intersection with the current clipping region.
    case and
    /// RGN_OR (0x02): union with the current clipping region.
    case or
    /// RGN_XOR (0x03): symmetric difference with the current clipping region.
    case xor
    /// RGN_DIFF (0x04): current region minus the new region.
    case diff
    /// RGN_COPY (0x05): replace with the new region (or, for
    /// EMR_EXTSELECTCLIPRGN with no region data, reset to the default region).
    case copy
    case unknown(UInt32)

    public init(_ raw: UInt32) {
        switch raw {
        case 0x01: self = .and
        case 0x02: self = .or
        case 0x03: self = .xor
        case 0x04: self = .diff
        case 0x05: self = .copy
        default: self = .unknown(raw)
        }
    }
}

/// Text alignment flags carried by EMR_SETTEXTALIGN ([MS-EMF] §2.3.11.25,
/// TextAlignmentMode from [MS-WMF] §2.1.2.3). The raw mask is a combination
/// of horizontal, vertical, and current-position flags; the accessors decode
/// the ones the renderer needs.
///
/// The horizontal and vertical alignment values are NOT single bits — they
/// are small multi-bit codes masked out of the field:
///   horizontal (mask 0x0006): TA_LEFT=0, TA_RIGHT=2, TA_CENTER=6
///   vertical   (mask 0x0018): TA_TOP=0, TA_BOTTOM=8, TA_BASELINE=24 (0x18)
///   TA_UPDATECP=1 (TA_NOUPDATECP=0) is a standalone bit.
/// Values verified against [MS-WMF] §2.1.2.3 (not present in the local
/// [MS-EMF] PDF, which references it) as supplied in the task.
public struct TextAlign: Sendable, Equatable {
    /// Horizontal alignment of the reference point relative to the text.
    public enum Horizontal: Sendable, Equatable {
        /// TA_LEFT (0): reference point is at the left of the bounding rect.
        case left
        /// TA_RIGHT (2): reference point is at the right.
        case right
        /// TA_CENTER (6): reference point is horizontally centered.
        case center
    }

    /// Vertical alignment of the reference point relative to the text.
    public enum Vertical: Sendable, Equatable {
        /// TA_TOP (0): reference point is at the top of the bounding rect.
        case top
        /// TA_BOTTOM (8): reference point is at the bottom.
        case bottom
        /// TA_BASELINE (24): reference point is on the text baseline.
        case baseline
    }

    /// The mask as read from the record ([MS-WMF] §2.1.2.3).
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// TA_UPDATECP (0x0001): the current position is updated by text output.
    public var updatesCurrentPosition: Bool { rawValue & 0x0001 != 0 }

    /// Horizontal component (mask 0x0006). TA_CENTER (0x0006) is checked
    /// before TA_RIGHT (0x0002) because it shares the TA_RIGHT bit.
    public var horizontal: Horizontal {
        switch rawValue & 0x0006 {
        case 0x0006: return .center
        case 0x0002: return .right
        default: return .left
        }
    }

    /// Vertical component (mask 0x0018). TA_BASELINE (0x0018) is checked
    /// before TA_BOTTOM (0x0008) because it shares the TA_BOTTOM bit.
    public var vertical: Vertical {
        switch rawValue & 0x0018 {
        case 0x0018: return .baseline
        case 0x0008: return .bottom
        default: return .top
        }
    }
}

/// ExtTextOut option flags ([MS-EMF] §2.1.11, ExtTextOutOptions enumeration).
/// Carried raw so the renderer sees every flag; accessors expose the ones that
/// change decode or layout. Bit values verified against §2.1.11.
public struct ExtTextOutOptions: Sendable, Equatable {
    /// The full Options field as read.
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// ETO_OPAQUE (0x0002): fill the rectangle with the background color.
    public var opaque: Bool { rawValue & 0x0002 != 0 }
    /// ETO_CLIPPED (0x0004): clip text to the rectangle.
    public var clipped: Bool { rawValue & 0x0004 != 0 }
    /// ETO_GLYPH_INDEX (0x0010): the string holds glyph indices, not
    /// character codes.
    public var glyphIndex: Bool { rawValue & 0x0010 != 0 }
    /// ETO_RTLREADING (0x0080): lay characters out right-to-left.
    public var rtlReading: Bool { rawValue & 0x0080 != 0 }
    /// ETO_PDY (0x2000): the Dx array carries two values (dx, dy) per
    /// character rather than one.
    public var pdy: Bool { rawValue & 0x2000 != 0 }
}

/// A LogFont object ([MS-EMF] §2.2.13): the basic attributes of a logical
/// font. Fixed size 92 bytes (0x5C) — 28-byte field block + 64-byte FaceName.
/// This same 92-byte prefix begins the LogFontEx / LogFontExDv / LogFontPanose
/// variants, so it decodes from any of them.
///
/// `height` is carried SIGNED per §2.2.13: a negative value is the character
/// (em) height, a positive value is the cell height, and zero means "font
/// mapper default". The renderer's LOGFONT→CTFont mapping (Task B) relies on
/// this sign.
public struct LogFont: Sendable, Equatable {
    /// Character-cell height, logical units, SIGNED (§2.2.13): < 0 character
    /// height, > 0 cell height, 0 default.
    public var height: Int32
    /// Average character width, logical units; 0 means "derive from height".
    public var width: Int32
    /// Escapement angle, tenths of a degree.
    public var escapement: Int32
    /// Character orientation angle, tenths of a degree.
    public var orientation: Int32
    /// Weight, 0–1000 (400 = normal, 700 = bold); 0 = default.
    public var weight: Int32
    /// 0x01 if italic.
    public var italic: UInt8
    /// 0x01 if underlined.
    public var underline: UInt8
    /// 0x01 if struck out.
    public var strikeOut: UInt8
    /// CharacterSet enumeration value ([MS-WMF] §2.1.1.5).
    public var charSet: UInt8
    /// OutPrecision enumeration value ([MS-WMF] §2.1.1.21).
    public var outPrecision: UInt8
    /// ClipPrecision flags ([MS-WMF] §2.1.2.1).
    public var clipPrecision: UInt8
    /// FontQuality enumeration value ([MS-WMF] §2.1.1.10).
    public var quality: UInt8
    /// PitchAndFamily ([MS-WMF] §2.2.2.14).
    public var pitchAndFamily: UInt8
    /// Typeface name, decoded from up to 32 UTF-16LE code units, NUL-truncated
    /// (§2.2.13: a name shorter than 32 units MUST be NUL-terminated; a name
    /// using all 32 units carries no terminator — both decode here).
    public var faceName: String

    public init(
        height: Int32,
        width: Int32,
        escapement: Int32,
        orientation: Int32,
        weight: Int32,
        italic: UInt8,
        underline: UInt8,
        strikeOut: UInt8,
        charSet: UInt8,
        outPrecision: UInt8,
        clipPrecision: UInt8,
        quality: UInt8,
        pitchAndFamily: UInt8,
        faceName: String
    ) {
        self.height = height
        self.width = width
        self.escapement = escapement
        self.orientation = orientation
        self.weight = weight
        self.italic = italic
        self.underline = underline
        self.strikeOut = strikeOut
        self.charSet = charSet
        self.outPrecision = outPrecision
        self.clipPrecision = clipPrecision
        self.quality = quality
        self.pitchAndFamily = pitchAndFamily
        self.faceName = faceName
    }
}

/// A single color-table entry in a DIB ([MS-WMF] §2.2.2.20, RGBQuad).
///
/// CRITICAL byte order: on disk the quad is Blue, Green, Red, Reserved — the
/// REVERSE of a ColorRef (Red, Green, Blue, Reserved). Kept a distinct type so
/// the two can never be confused when building pixel colors (Task B).
public struct RGBQuad: Sendable, Equatable {
    public var blue: UInt8
    public var green: UInt8
    public var red: UInt8
    /// MUST be 0 and ignored per the spec; carried for fidelity.
    public var reserved: UInt8

    public init(blue: UInt8, green: UInt8, red: UInt8, reserved: UInt8 = 0) {
        self.blue = blue
        self.green = green
        self.red = red
        self.reserved = reserved
    }
}

/// DIB compression ([MS-WMF] §2.1.1.3, Compression enumeration). Only the
/// values this phase acts on are named; everything else is `.other(raw)` and
/// yields a `.unsupported` DIB (a valid, precisely-logged payload).
public enum BitmapCompression: Sendable, Equatable {
    /// BI_RGB (0x0000): uncompressed.
    case rgb
    /// BI_RLE8 (0x0001): 8-bit run-length encoded.
    case rle8
    /// BI_RLE4 (0x0002): 4-bit run-length encoded.
    case rle4
    /// BI_BITFIELDS (0x0003): uncompressed with explicit channel masks.
    case bitfields
    /// BI_JPEG (0x0004): a JPEG image.
    case jpeg
    /// BI_PNG (0x0005): a PNG image.
    case png
    case other(UInt32)

    public init(_ raw: UInt32) {
        switch raw {
        case 0x0000: self = .rgb
        case 0x0001: self = .rle8
        case 0x0002: self = .rle4
        case 0x0003: self = .bitfields
        case 0x0004: self = .jpeg
        case 0x0005: self = .png
        default: self = .other(raw)
        }
    }
}

/// Why a DIB decoded to `.unsupported` rather than `.pixels`. This is a VALID
/// payload verdict the renderer logs precisely — it is NOT `.malformed`
/// (which means the DIB's own size/count fields were internally inconsistent
/// or hostile).
public enum DIBUnsupportedReason: Sendable, Equatable {
    /// A compression other than BI_RGB (RLE, BITFIELDS, JPEG, PNG, …).
    case compression(BitmapCompression)
    /// A BitCount this phase does not decode (1, 4, 16; or 8/24/32 in a
    /// combination not supported). Carries the value as read.
    case bitCount(UInt16)
    /// DIB_PAL_COLORS / DIB_PAL_INDICES usage: the color table indexes a
    /// palette in the playback DC, which this phase does not track.
    case paletteUsage(UInt32)
}

/// A decoded device-independent bitmap: its header dimensions plus either the
/// pixel bytes (BI_RGB 24/32-bit or 8-bit palettised) or a typed reason it is
/// unsupported. The pixel bytes and palette are validated against the DIB's
/// own size fields AND the enclosing record before this value exists
/// (primer §8).
///
/// Header fields decoded from BitmapInfoHeader ([MS-WMF] §2.2.2.3; the
/// structure is not in the local [MS-EMF] PDF — layout per the task's
/// [MS-WMF]-verified description). `height` is SIGNED: a negative value means
/// a top-down DIB (rows stored top-to-bottom); positive is bottom-up.
public struct DIB: Sendable, Equatable {
    /// The DIB's pixel payload, or why it is not decoded.
    public enum Content: Sendable, Equatable {
        /// Uncompressed pixels plus, for palettised bitmaps, the color table.
        /// `stride` is the padded row length in bytes.
        case pixels(bytes: Data, stride: Int, palette: [RGBQuad])
        /// The DIB is well-formed but this phase does not decode it.
        case unsupported(DIBUnsupportedReason)
    }

    /// Bitmap width in pixels (BitmapInfoHeader.Width).
    public var width: Int32
    /// Bitmap height in pixels, SIGNED: < 0 = top-down (BitmapInfoHeader.Height).
    public var height: Int32
    /// Bits per pixel (BitmapInfoHeader.BitCount).
    public var bitCount: UInt16
    /// Compression scheme (BitmapInfoHeader.Compression).
    public var compression: BitmapCompression
    /// Pixels, or the unsupported reason.
    public var content: Content

    public init(
        width: Int32,
        height: Int32,
        bitCount: UInt16,
        compression: BitmapCompression,
        content: Content
    ) {
        self.width = width
        self.height = height
        self.bitCount = bitCount
        self.compression = compression
        self.content = content
    }

    /// True when the DIB stores rows top-to-bottom (negative header height).
    public var isTopDown: Bool { height < 0 }
}

/// An object-table reference as carried by EMR_SELECTOBJECT / EMR_DELETEOBJECT.
///
/// Per [MS-EMF] §2.1.31 (p. 46): "The index of a stock object can be
/// distinguished from the index of an explicit object by the value of the
/// most-significant bit. If that bit is set, the object is a stock object."
/// The decoder represents what is in the file; semantic rules (e.g.
/// EMR_DELETEOBJECT MUST NOT name a stock object, §2.3.8.3) are the
/// renderer's to enforce with a logged skip.
public enum ObjectHandle: Sendable, Equatable {
    case stock(StockObject)
    case table(index: UInt32)

    public init(raw: UInt32) {
        if raw & 0x8000_0000 != 0 {
            self = .stock(StockObject(raw))
        } else {
            self = .table(index: raw)
        }
    }
}
