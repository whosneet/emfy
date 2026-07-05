import CoreGraphics
import CoreText
import EMFParse
import Foundation

// MARK: - Resolved drawing objects
//
// Selections in the DC hold RESOLVED VALUES, never object-table references:
// EMR_SELECTOBJECT copies the object's resolved form into the DC, so a later
// EMR_DELETEOBJECT of a selected handle is safe and drawing continues with the
// copy (GDI-faithful — GDI keeps a selected object alive — and value-semantic).

/// A brush resolved to its drawable value.
enum ResolvedBrush: Equatable, Sendable {
    /// BS_NULL / NULL_BRUSH: the fill half of a shape is skipped.
    case none
    /// BS_SOLID (or the logged fallback for unsupported styles).
    case solid(ColorRef)
}

/// The dash treatment of a resolved pen's line.
enum ResolvedLineStyle: Equatable, Sendable {
    case solid
    case dash          // PS_DASH
    case dot           // PS_DOT
    case dashDot       // PS_DASHDOT
    case dashDotDot    // PS_DASHDOTDOT
    /// PS_USERSTYLE: dash/gap lengths from the EMR_EXTCREATEPEN style array —
    /// logical units for geometric pens, device units for cosmetic pens
    /// ([MS-EMF] §2.2.20).
    case userStyle([UInt32])
}

/// A stroking pen resolved to its drawable value.
struct ResolvedStroke: Equatable, Sendable {
    var color: ColorRef
    /// PS_COSMETIC (or width 0): the line is one DEVICE pixel wide regardless
    /// of the logical→device transform.
    var isCosmetic: Bool
    /// Width in logical units; meaningful only when `isCosmetic` is false.
    var width: Double
    var lineStyle: ResolvedLineStyle
    var cap: CGLineCap
    var join: CGLineJoin
}

/// A pen resolved to its drawable value.
enum ResolvedPen: Equatable, Sendable {
    /// PS_NULL / NULL_PEN: the stroke half of a shape is skipped.
    case none
    case stroke(ResolvedStroke)

    /// Solid cosmetic one-device-pixel pen — the stock pen shape.
    static func cosmetic(_ color: ColorRef) -> ResolvedPen {
        .stroke(ResolvedStroke(
            color: color,
            isCosmetic: true,
            width: 0,
            lineStyle: .solid,
            cap: .round,
            join: .round
        ))
    }
}

/// A font resolved to a base CTFont plus the drawing attributes CoreText's
/// font object does not itself carry (underline, strike-out, baseline
/// rotation) and the SIGNED logical height (§2.2.13) the text drawer scales to
/// a device point size at draw time — the transform in effect can change
/// between SELECTOBJECT and EXTTEXTOUTW, exactly like a geometric pen's width.
///
/// `Equatable`/`Sendable` are synthesised over CTFont: `CTFont` is a
/// toll-free-bridged CoreFoundation type that conforms to both. Two resolved
/// fonts are equal when their base CTFont and attributes match.
struct ResolvedFont: Equatable, @unchecked Sendable {
    /// The substituted base font at a nominal size (`FontMapper.nominalSize`);
    /// the drawer copies it to the device size at draw time.
    var base: CTFont
    /// Signed logical character/cell height (§2.2.13): < 0 em height, > 0 cell
    /// height, 0 → default. Scaled to a device point size by the text drawer.
    var logicalHeight: Int32
    /// lfEscapement, tenths of a degree counterclockwise ([MS-EMF] §2.2.13):
    /// rotates the text baseline.
    var escapementTenths: Int32
    /// lfUnderline: draw a single underline.
    var underline: Bool
    /// lfStrikeOut: draw a manual strike-through (CoreText has no
    /// strikethrough attribute).
    var strikeOut: Bool
}

/// One object-table slot.
enum TableObject: Equatable, @unchecked Sendable {
    case pen(ResolvedPen)
    case brush(ResolvedBrush)
    case font(ResolvedFont)
}

// MARK: - PenStyle bit field ([MS-EMF] §2.1.25, values verified 2026-07-05)

/// PenStyle is a bit-packed combination of pen type, line style, line cap and
/// line join. Values below are verbatim from the spec's enumeration:
/// PS_SOLID 0x0, PS_DASH 0x1, PS_DOT 0x2, PS_DASHDOT 0x3, PS_DASHDOTDOT 0x4,
/// PS_NULL 0x5, PS_INSIDEFRAME 0x6, PS_USERSTYLE 0x7, PS_ALTERNATE 0x8;
/// PS_ENDCAP_ROUND 0x000, PS_ENDCAP_SQUARE 0x100, PS_ENDCAP_FLAT 0x200;
/// PS_JOIN_ROUND 0x0000, PS_JOIN_BEVEL 0x1000, PS_JOIN_MITER 0x2000;
/// PS_COSMETIC 0x00000, PS_GEOMETRIC 0x10000. The masks are the standard GDI
/// group masks implied by that value layout.
enum PenStyleBits {
    static let styleMask: UInt32 = 0x0000_000F
    static let endCapMask: UInt32 = 0x0000_0F00
    static let joinMask: UInt32 = 0x0000_F000
    static let typeMask: UInt32 = 0x000F_0000

    static let solid: UInt32 = 0x00
    static let dash: UInt32 = 0x01
    static let dot: UInt32 = 0x02
    static let dashDot: UInt32 = 0x03
    static let dashDotDot: UInt32 = 0x04
    static let null: UInt32 = 0x05
    static let insideFrame: UInt32 = 0x06
    static let userStyle: UInt32 = 0x07

    static let endCapSquare: UInt32 = 0x100
    static let endCapFlat: UInt32 = 0x200
    static let joinBevel: UInt32 = 0x1000
    static let joinMiter: UInt32 = 0x2000
    static let geometric: UInt32 = 0x0001_0000
}

// MARK: - BrushStyle values ([MS-WMF] §2.1.1.4, verified 2026-07-05)

enum BrushStyleValues {
    static let solid: UInt32 = 0x0000    // BS_SOLID
    static let null: UInt32 = 0x0001     // BS_NULL (a.k.a. BS_HOLLOW)
}

// MARK: - Payload → resolved object

enum ObjectResolver {

    /// Resolves an EMR_CREATEPEN LogPen ([MS-EMF] §2.2.19). Per the wingdi
    /// CreatePen contract these legacy pens carry their width in LOGICAL
    /// units; width <= 0 means "one device pixel regardless of transform".
    /// Legacy pens draw round caps and joins. Only the line-style nibble is
    /// meaningful in LogPen's PenStyle; styles outside the supported set are
    /// logged and fall back to solid.
    static func resolve(_ payload: CreatePenPayload, log: inout EMFRenderLog) -> ResolvedPen {
        let style = payload.style & PenStyleBits.styleMask
        if style == PenStyleBits.null { return .none }

        let lineStyle = resolveLineStyle(
            style: style,
            fullStyleBits: payload.style,
            userEntries: [],
            log: &log
        )
        return .stroke(ResolvedStroke(
            color: payload.color,
            isCosmetic: payload.width.x <= 0,
            width: Double(max(0, payload.width.x)),
            lineStyle: lineStyle,
            cap: .round,
            join: .round
        ))
    }

    /// Resolves an EMR_EXTCREATEPEN LogPenEx ([MS-EMF] §2.2.20). PS_GEOMETRIC
    /// pens measure width in logical units and carry cap/join bits and an
    /// optional PS_USERSTYLE array; PS_COSMETIC pens are one device pixel.
    /// The pen's brush: BS_SOLID colours the line, BS_NULL makes the pen draw
    /// nothing, anything else is logged and falls back to the payload colour.
    static func resolve(_ payload: ExtCreatePenPayload, log: inout EMFRenderLog) -> ResolvedPen {
        let style = payload.style & PenStyleBits.styleMask
        if style == PenStyleBits.null { return .none }

        // A geometric pen whose brush is BS_NULL draws nothing ([MS-WMF]
        // BS_NULL: "MUST have the same effect as using no brush at all").
        if payload.brushStyle == BrushStyleValues.null { return .none }
        if payload.brushStyle != BrushStyleValues.solid {
            log.note(.unsupportedBrushStyle(rawStyle: payload.brushStyle))
            // Fall through: solid fallback from the payload's ColorRef.
        }

        let isGeometric = payload.style & PenStyleBits.typeMask == PenStyleBits.geometric
        let lineStyle = resolveLineStyle(
            style: style,
            fullStyleBits: payload.style,
            userEntries: payload.styleEntries,
            log: &log
        )

        let cap: CGLineCap
        switch payload.style & PenStyleBits.endCapMask {
        case PenStyleBits.endCapSquare: cap = .square
        case PenStyleBits.endCapFlat: cap = .butt
        default: cap = .round               // PS_ENDCAP_ROUND == 0
        }

        let join: CGLineJoin
        switch payload.style & PenStyleBits.joinMask {
        case PenStyleBits.joinBevel: join = .bevel
        case PenStyleBits.joinMiter: join = .miter
        default: join = .round              // PS_JOIN_ROUND == 0
        }

        return .stroke(ResolvedStroke(
            color: payload.color,
            // PS_COSMETIC width MUST be 1 device unit ([MS-EMF] §2.2.20);
            // geometric width 0 degrades to the same one-device-pixel line.
            isCosmetic: !isGeometric || payload.width == 0,
            width: Double(payload.width),
            lineStyle: lineStyle,
            cap: cap,
            join: join
        ))
    }

    /// Resolves an EMR_CREATEBRUSHINDIRECT LogBrushEx ([MS-EMF] §2.2.12).
    /// BS_SOLID and BS_NULL are the phase-2 set; hatched/pattern styles log
    /// and fall back to a solid fill of the payload's ColorRef.
    static func resolve(_ payload: CreateBrushPayload, log: inout EMFRenderLog) -> ResolvedBrush {
        switch payload.style {
        case BrushStyleValues.solid:
            return .solid(payload.color)
        case BrushStyleValues.null:
            return .none
        default:
            log.note(.unsupportedBrushStyle(rawStyle: payload.style))
            return .solid(payload.color)
        }
    }

    /// Maps a line-style nibble to the resolved dash treatment, logging and
    /// falling back to solid for the unsupported styles (PS_INSIDEFRAME,
    /// PS_ALTERNATE, and undefined values 9–15).
    private static func resolveLineStyle(
        style: UInt32,
        fullStyleBits: UInt32,
        userEntries: [UInt32],
        log: inout EMFRenderLog
    ) -> ResolvedLineStyle {
        switch style {
        case PenStyleBits.solid: return .solid
        case PenStyleBits.dash: return .dash
        case PenStyleBits.dot: return .dot
        case PenStyleBits.dashDot: return .dashDot
        case PenStyleBits.dashDotDot: return .dashDotDot
        case PenStyleBits.userStyle where !userEntries.isEmpty:
            return .userStyle(userEntries)
        default:
            // PS_INSIDEFRAME, PS_ALTERNATE, undefined values, or a
            // PS_USERSTYLE with an empty entry array.
            log.note(.unsupportedPenStyle(rawStyle: fullStyleBits))
            return .solid
        }
    }
}

// MARK: - Stock objects ([MS-EMF] §2.1.31)

/// What a stock-object selection resolves to.
enum StockResolution: Equatable {
    case brush(ResolvedBrush)
    case pen(ResolvedPen)
    /// A stock FONT (SYSTEM_FONT, DEFAULT_GUI_FONT, …): resolves to the system
    /// font at a reasonable size. `rawValue` is the on-disk index (for the
    /// coalesced stock-font log — the exact metrics are Windows-specific).
    case font(ResolvedFont, rawValue: UInt32)
    /// Palette or undefined stock values — nothing the DC can select.
    /// `rawValue` is the on-disk 0x8000_00xx index.
    case unsupported(rawValue: UInt32)
}

enum StockObjects {
    static let white = ColorRef(red: 255, green: 255, blue: 255)
    static let ltGray = ColorRef(red: 0xC0, green: 0xC0, blue: 0xC0)
    static let gray = ColorRef(red: 0x80, green: 0x80, blue: 0x80)
    static let dkGray = ColorRef(red: 0x40, green: 0x40, blue: 0x40)
    static let black = ColorRef(red: 0, green: 0, blue: 0)

    /// Resolves a stock object per the StockObject enumeration. DC_BRUSH and
    /// DC_PEN resolve to their GDI defaults (white brush, black pen) — the
    /// EMR_SETDCBRUSHCOLOR/SETDCPENCOLOR records that would recolour them are
    /// outside the phase-2 record set and surface as unimplemented-record log
    /// entries if met.
    static func resolve(_ stock: StockObject) -> StockResolution {
        switch stock {
        case .whiteBrush: return .brush(.solid(white))
        case .ltGrayBrush: return .brush(.solid(ltGray))
        case .grayBrush: return .brush(.solid(gray))
        case .dkGrayBrush: return .brush(.solid(dkGray))
        case .blackBrush: return .brush(.solid(black))
        case .nullBrush: return .brush(.none)
        case .dcBrush: return .brush(.solid(white))
        case .whitePen: return .pen(.cosmetic(white))
        case .blackPen: return .pen(.cosmetic(black))
        case .nullPen: return .pen(.none)
        case .dcPen: return .pen(.cosmetic(black))
        // Stock FONTs resolve to the system font at a reasonable size. The
        // exact GDI stock-font metrics are Windows-specific, so this is an
        // approximation the caller logs (coalesced) — never a blank canvas.
        case .oemFixedFont: return stockFont(0x8000_000A)
        case .ansiFixedFont: return stockFont(0x8000_000B)
        case .ansiVarFont: return stockFont(0x8000_000C)
        case .systemFont: return stockFont(0x8000_000D)
        case .deviceDefaultFont: return stockFont(0x8000_000E)
        case .systemFixedFont: return stockFont(0x8000_0010)
        case .defaultGuiFont: return stockFont(0x8000_0011)
        case .defaultPalette: return .unsupported(rawValue: 0x8000_000F)
        case .unknownStock(let raw): return .unsupported(rawValue: raw)
        }
    }

    /// A stock font resolved to the system font at a default cell height
    /// (logical height 0 → the drawer's 12pt default, scaled by the transform).
    private static func stockFont(_ rawValue: UInt32) -> StockResolution {
        .font(
            ResolvedFont(
                base: FontMapper.systemBaseFont(),
                logicalHeight: 0,
                escapementTenths: 0,
                underline: false,
                strikeOut: false
            ),
            rawValue: rawValue
        )
    }
}

// MARK: - Device stroke parameters

/// Everything a CGContext needs to stroke with a resolved pen, in target
/// (final canvas) units.
struct DeviceStrokeParameters: Equatable {
    var width: CGFloat
    /// Dash lengths in target units; empty means a solid line.
    var dash: [CGFloat]
    var cap: CGLineCap
    var join: CGLineJoin
}

enum StrokeMapper {

    /// The average of a transform's axis scale magnitudes — the documented
    /// approximation for mapping a scalar pen width through a possibly
    /// anisotropic (or rotated) transform: GDI widens geometric pens by the
    /// full transform of the stroke outline; we approximate with a single
    /// width of (|sx| + |sy|) / 2, where sx/sy are the transformed unit-axis
    /// lengths.
    static func averageScale(_ t: CGAffineTransform) -> CGFloat {
        let sx = (t.a * t.a + t.b * t.b).squareRoot()
        let sy = (t.c * t.c + t.d * t.d).squareRoot()
        return (sx + sy) / 2
    }

    /// Maps a resolved stroke to device stroke parameters.
    ///
    /// - Cosmetic pens (and zero-width pens): exactly one DEVICE pixel wide,
    ///   so the width scales only by `deviceToTarget` (the canvas fit),
    ///   never by the logical→device mapping.
    /// - Geometric pens: width in logical units, scaled by the full composed
    ///   logical→target transform (average-of-axes approximation above).
    /// - Standard dash patterns are multiples of the line width ([MS-EMF]
    ///   gives no device-unit dash tables; multiples-of-width is the agreed
    ///   approximation), floored at 1 target unit so hairline dashes stay
    ///   visible. PS_USERSTYLE entries are absolute lengths — logical units
    ///   for geometric pens, device units for cosmetic ([MS-EMF] §2.2.20) —
    ///   so they scale by the same factor as the pen's width basis.
    static func deviceStroke(
        for stroke: ResolvedStroke,
        logicalToTarget: CGAffineTransform,
        deviceToTarget: CGAffineTransform
    ) -> DeviceStrokeParameters {
        let width: CGFloat
        let unitScale: CGFloat
        if stroke.isCosmetic {
            unitScale = averageScale(deviceToTarget)
            width = 1 * unitScale
        } else {
            unitScale = averageScale(logicalToTarget)
            width = CGFloat(stroke.width) * unitScale
        }

        let dashBasis = max(width, 1)
        let dash: [CGFloat]
        switch stroke.lineStyle {
        case .solid:
            dash = []
        case .dash:
            dash = [3, 1].map { $0 * dashBasis }
        case .dot:
            dash = [1, 1].map { $0 * dashBasis }
        case .dashDot:
            dash = [3, 1, 1, 1].map { $0 * dashBasis }
        case .dashDotDot:
            dash = [3, 1, 1, 1, 1, 1].map { $0 * dashBasis }
        case .userStyle(let entries):
            let scaled = entries.map { CGFloat($0) * unitScale }
            // An all-zero pattern would make CG's dash machinery degenerate;
            // treat it as solid.
            dash = scaled.contains(where: { $0 > 0 }) ? scaled : []
        }

        return DeviceStrokeParameters(
            width: width,
            dash: dash,
            cap: stroke.cap,
            join: stroke.join
        )
    }
}
