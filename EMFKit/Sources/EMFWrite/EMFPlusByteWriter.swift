import Foundation
import EMFParse

/// EMF+ structure appends on `ByteWriter`, the write-side inverse of EMFParse's
/// `ByteCursor` / `PlusReader` field reads. Every EMF+ scalar is little-endian
/// ([MS-EMFPLUS] §1.3.2), so these reuse the base little-endian primitives and
/// only arrange the fields of each §2.2.2 structure in on-wire order.
extension ByteWriter {

    /// An EmfPlusARGB ([MS-EMFPLUS] §2.2.2.1): one little-endian u32 whose low
    /// byte is Blue, then Green, Red, Alpha (the exact order `ByteCursor.readARGB`
    /// reconstructs, so a decode→encode is bit-exact).
    mutating func appendARGB(_ color: EMFPlusARGB) {
        var value = UInt32(color.blue)
        value |= UInt32(color.green) << 8
        value |= UInt32(color.red) << 16
        value |= UInt32(color.alpha) << 24
        appendUInt32(value)
    }

    /// An EmfPlusRectF ([MS-EMFPLUS] §2.2.2.39): X, Y, Width, Height as f32.
    mutating func appendRectF(_ rect: EMFPlusRectF) {
        appendFloat(rect.x)
        appendFloat(rect.y)
        appendFloat(rect.width)
        appendFloat(rect.height)
    }

    /// An EmfPlusPointF ([MS-EMFPLUS] §2.2.2.36): X, Y as f32.
    mutating func appendPointF(_ point: EMFPlusPointF) {
        appendFloat(point.x)
        appendFloat(point.y)
    }

    /// An EmfPlusTransformMatrix ([MS-EMFPLUS] §2.2.2.47): m11, m12, m21, m22,
    /// dx, dy as f32, the order `ByteCursor.readTransformMatrix` reads.
    mutating func appendTransformMatrix(_ m: EMFPlusTransformMatrix) {
        appendFloat(m.m11)
        appendFloat(m.m12)
        appendFloat(m.m21)
        appendFloat(m.m22)
        appendFloat(m.dx)
        appendFloat(m.dy)
    }
}
