import CoreGraphics
import Foundation

/// EMF+ text-record decode + text-layout math ([MS-EMFPLUS] §2.3.4.14
/// EmfPlusDrawString, §2.3.4.6 EmfPlusDrawDriverString). This file owns the
/// bounds-checked DECODE of the two record bodies and the pure alignment
/// arithmetic; `EMFPlusPlayback` owns object-table resolution, font sizing
/// through the shared `FontMapper`, and the CoreGraphics/CoreText draw. Every
/// self-described count is validated against the record's own bytes BEFORE any
/// allocation (primer §8: this parser feeds a Quick Look preview hostile files).
enum EMFPlusText {

    // MARK: - DrawString (§2.3.4.14)

    /// The decoded body of an EmfPlusDrawString record.
    struct StringRecord {
        var brushId: UInt32
        var formatId: UInt32
        var layoutRect: CGRect
        var string: String
    }

    /// Decodes an EmfPlusDrawString body ([MS-EMFPLUS] §2.3.4.14): BrushId (u32),
    /// FormatID (u32 — the object-table index of an optional EmfPlusStringFormat),
    /// Length (u32 characters), LayoutRect (EmfPlusRectF, 16 bytes), then Length
    /// UTF-16LE code units of StringData (any 4-aligned AlignmentPadding follows
    /// and is ignored). Length is validated against the remaining bytes BEFORE the
    /// string is read, so a lying Length fails to nil rather than over-reading or
    /// over-allocating.
    static func decodeString(_ data: Data) -> StringRecord? {
        var reader = PlusReader(data)
        guard let brushId = reader.u32(), let formatId = reader.u32(),
              let length = reader.u32(), let rect = reader.rectF() else { return nil }
        let count = Int(length)
        guard count <= reader.remaining / 2 else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0 ..< count {
            guard let unit = reader.u16() else { return nil }
            units.append(unit)
        }
        // Lossless UTF-16 (a lone surrogate becomes U+FFFD; never fails) — the
        // same decode as the GDI text path and EmfPlusFont.familyName.
        return StringRecord(
            brushId: brushId, formatId: formatId,
            layoutRect: rect, string: String(decoding: units, as: UTF16.self))
    }

    // MARK: - DrawDriverString (§2.3.4.6)

    /// The decoded body of an EmfPlusDrawDriverString record.
    struct DriverStringRecord {
        var brushId: UInt32
        var options: UInt32
        /// Either character codes (CmapLookup set) or raw font glyph indices.
        var values: [UInt16]
        /// GlyphPos: one baseline origin per glyph (world space). When
        /// RealizedAdvance is set the record carries only the first origin.
        var positions: [CGPoint]
        /// The optional per-glyph transform (MatrixPresent == 1).
        var matrix: CGAffineTransform?

        /// §2.1.2.3 DriverStringOptionsCmapLookup (0x1): the values are Unicode
        /// characters (mapped through the font); else they are raw glyph indices.
        var cmapLookup: Bool { options & 0x1 != 0 }
        /// §2.1.2.3 DriverStringOptionsVertical (0x2).
        var vertical: Bool { options & 0x2 != 0 }
        /// §2.1.2.3 DriverStringOptionsRealizedAdvance (0x4): only the first
        /// glyph's position is stored; the rest advance from it.
        var realizedAdvance: Bool { options & 0x4 != 0 }
    }

    /// Decodes an EmfPlusDrawDriverString body ([MS-EMFPLUS] §2.3.4.6): BrushId
    /// (u32), DriverStringOptionsFlags (u32), MatrixPresent (u32), GlyphCount
    /// (u32), then GlyphCount 16-bit Glyphs, then the GlyphPos array of
    /// EmfPlusPointF (GlyphCount entries, or a single entry when RealizedAdvance
    /// is set), then an optional 24-byte TransformMatrix when MatrixPresent == 1.
    /// GlyphCount is validated against the remaining bytes before any allocation;
    /// the positions and matrix reads are each independently bounds-checked.
    static func decodeDriverString(_ data: Data) -> DriverStringRecord? {
        var reader = PlusReader(data)
        guard let brushId = reader.u32(), let options = reader.u32(),
              let matrixPresent = reader.u32(), let glyphCount = reader.u32() else { return nil }
        let count = Int(glyphCount)
        let realizedAdvance = options & 0x4 != 0
        // Bound GlyphCount by the bytes that remain before reserving the array.
        guard count >= 0, count <= reader.remaining / 2 else { return nil }
        var values: [UInt16] = []
        values.reserveCapacity(count)
        for _ in 0 ..< count {
            guard let value = reader.u16() else { return nil }
            values.append(value)
        }
        let positionCount = realizedAdvance ? min(count, 1) : count
        guard let positions = reader.points(count: positionCount, compressed: false) else { return nil }
        var matrix: CGAffineTransform?
        if matrixPresent == 1 {
            guard let m11 = reader.f32(), let m12 = reader.f32(), let m21 = reader.f32(),
                  let m22 = reader.f32(), let dx = reader.f32(), let dy = reader.f32() else { return nil }
            matrix = CGAffineTransform(
                a: CGFloat(m11), b: CGFloat(m12), c: CGFloat(m21),
                d: CGFloat(m22), tx: CGFloat(dx), ty: CGFloat(dy))
        }
        return DriverStringRecord(
            brushId: brushId, options: options,
            values: values, positions: positions, matrix: matrix)
    }

    // MARK: - Alignment (pure)

    /// The device-space drawing origin (the baseline start) for a DrawString run.
    /// `rectDevice` is the LayoutRect mapped to device space (y-DOWN); the text
    /// metrics are in the same device units as the sized font. StringAlignment
    /// ([MS-EMFPLUS] §2.1.1.28: Near 0 / Center 1 / Far 2) places the text
    /// horizontally; LineAlign (the same enumeration, applied vertically, §2.2.1.9)
    /// places the baseline. A zero-width/height LayoutRect collapses min == mid ==
    /// max, so Near draws from the rect's origin corner — GDI+'s point-origin
    /// behaviour for an unbounded (zero-size) layout rectangle.
    static func drawStringOrigin(
        rectDevice: CGRect, lineWidth: CGFloat, ascent: CGFloat, descent: CGFloat,
        horizontal: UInt32, vertical: UInt32
    ) -> CGPoint {
        let x: CGFloat
        switch horizontal {
        case 1: x = rectDevice.midX - lineWidth / 2   // Center
        case 2: x = rectDevice.maxX - lineWidth       // Far
        default: x = rectDevice.minX                  // Near (and any undefined)
        }
        let baseline: CGFloat
        switch vertical {
        case 1: baseline = rectDevice.midY + (ascent - descent) / 2   // Center
        case 2: baseline = rectDevice.maxY - descent                  // Far (bottom)
        default: baseline = rectDevice.minY + ascent                  // Near (top)
        }
        return CGPoint(x: x, y: baseline)
    }
}
