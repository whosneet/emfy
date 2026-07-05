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
