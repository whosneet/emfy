import Foundation
import EMFParse

/// A fill/text colour source for an EMF+ drawing record ([MS-EMFPLUS] §2.3.4):
/// either a direct ARGB colour (the record's S flag is set and the BrushId field
/// carries the colour) or an object-table brush index.
public enum EMFPlusBrushSource: Sendable, Equatable {
    case color(EMFPlusARGB)
    case object(UInt8)
}

/// A typed EMF+ record an editor exports, lowered to a single on-wire EMF+ record
/// (Type, Flags, data). The field layouts are the exact inverse of the decoders
/// in EMFRender (`EMFPlusPlayback`, `EMFPlusText`) and EMFParse — each case cites
/// its [MS-EMFPLUS] §2.3 section, and the Flags bit positions (S 0x8000, C 0x4000,
/// L/order/winding 0x2000, ObjectID in the low byte, CombineMode in bits 8–11)
/// are the ones those verified decoders read.
///
/// Object-definition records are NOT here: an EmfPlusObject can need continuation
/// splitting (several records), so it is built through `EMFPlusCommentWriter`.
public enum EMFPlusRecordPayload: Sendable, Equatable {

    // Control ([MS-EMFPLUS] §2.3.3)
    case header(dual: Bool, videoDisplay: Bool, logicalDpiX: UInt32, logicalDpiY: UInt32, version: UInt32 = 0xDBC0_1002)
    case endOfFile
    case getDC
    case comment(data: [UInt8])

    // Drawing ([MS-EMFPLUS] §2.3.4)
    case clear(color: EMFPlusARGB)
    case fillRects(brush: EMFPlusBrushSource, rects: [EMFPlusRectF])
    case drawRects(penID: UInt8, rects: [EMFPlusRectF])
    case fillPolygon(brush: EMFPlusBrushSource, points: [EMFPlusPointF])
    case drawLines(penID: UInt8, points: [EMFPlusPointF], closed: Bool)
    case fillEllipse(brush: EMFPlusBrushSource, rect: EMFPlusRectF)
    case drawEllipse(penID: UInt8, rect: EMFPlusRectF)
    case fillPie(brush: EMFPlusBrushSource, startAngle: Float, sweepAngle: Float, rect: EMFPlusRectF)
    case drawPie(penID: UInt8, startAngle: Float, sweepAngle: Float, rect: EMFPlusRectF)
    case drawArc(penID: UInt8, startAngle: Float, sweepAngle: Float, rect: EMFPlusRectF)
    case fillPath(pathID: UInt8, brush: EMFPlusBrushSource)
    case drawPath(pathID: UInt8, penID: UInt32)
    case drawBeziers(penID: UInt8, points: [EMFPlusPointF])
    case fillClosedCurve(brush: EMFPlusBrushSource, tension: Float, points: [EMFPlusPointF], winding: Bool)
    case drawClosedCurve(penID: UInt8, tension: Float, points: [EMFPlusPointF])
    case drawCurve(penID: UInt8, tension: Float, offset: UInt32, numSegments: UInt32, points: [EMFPlusPointF])
    case drawString(fontID: UInt8, brush: EMFPlusBrushSource, formatID: UInt32, layoutRect: EMFPlusRectF, text: String)
    /// EmfPlusDrawImage ([MS-EMFPLUS] §2.3.4.8). `imageAttributesID` is the
    /// object-table index of an OPTIONAL EmfPlusImageAttributes object; pass `nil`
    /// for no attributes (the common case) — it encodes as `noImageAttributes`.
    /// A non-nil value MUST name a slot that actually holds an EmfPlusImageAttributes
    /// object: pointing it at a brush/pen/etc. makes conformant readers that do not
    /// type-check the slot (e.g. LibreOffice) drop the image.
    case drawImage(imageID: UInt8, imageAttributesID: UInt32?, srcUnit: Int32, srcRect: EMFPlusRectF, destRect: EMFPlusRectF)
    /// EmfPlusDrawImagePoints ([MS-EMFPLUS] §2.3.4.9). `imageAttributesID` as in
    /// `drawImage` — `nil` for no attributes.
    case drawImagePoints(imageID: UInt8, imageAttributesID: UInt32?, srcUnit: Int32, srcRect: EMFPlusRectF, points: [EMFPlusPointF])

    /// The ImageAttributesID value that means "no image attributes". EMF+ object
    /// ids are 6-bit (0…63, [MS-EMFPLUS] §3.1.2 Object Table), so 0xFFFFFFFF is
    /// outside the valid range and every conformant reader resolves it as "no
    /// object" — unlike a 0 that happens to collide with an unrelated object in
    /// slot 0. `drawImage`/`drawImagePoints` emit this when `imageAttributesID`
    /// is `nil`.
    public static let noImageAttributes: UInt32 = 0xFFFF_FFFF

    // State — save / container ([MS-EMFPLUS] §2.3.7)
    case save(stackIndex: UInt32)
    case restore(stackIndex: UInt32)
    case beginContainer(destRect: EMFPlusRectF, srcRect: EMFPlusRectF, stackIndex: UInt32, pageUnit: UInt8)
    case beginContainerNoParams(stackIndex: UInt32)
    case endContainer(stackIndex: UInt32)

    // Transforms ([MS-EMFPLUS] §2.3.9)
    case setWorldTransform(EMFPlusTransformMatrix)
    case resetWorldTransform
    case multiplyWorldTransform(EMFPlusTransformMatrix, postMultiply: Bool)
    case translateWorldTransform(dx: Float, dy: Float, postMultiply: Bool)
    case scaleWorldTransform(sx: Float, sy: Float, postMultiply: Bool)
    case rotateWorldTransform(angleDegrees: Float, postMultiply: Bool)
    case setPageTransform(scale: Float, pageUnit: UInt8)

    // Property ([MS-EMFPLUS] §2.3.6) — value in Flags, no data.
    case setAntiAliasMode(on: Bool, smoothingMode: UInt8)
    case setTextRenderingHint(hint: UInt8)
    case setCompositingMode(mode: UInt8)
    case setCompositingQuality(quality: UInt8)
    case setInterpolationMode(mode: UInt8)
    case setPixelOffsetMode(mode: UInt8)

    // Clipping ([MS-EMFPLUS] §2.3.1)
    case resetClip
    case setClipRect(rect: EMFPlusRectF, combineMode: UInt8)
    case setClipPath(pathID: UInt8, combineMode: UInt8)
    case setClipRegion(regionID: UInt8, combineMode: UInt8)
    case offsetClip(dx: Float, dy: Float)

    // MARK: - Lowering

    /// This record's on-wire Type, Flags and data bytes (no 12-byte header or
    /// padding — `EMFPlusCommentWriter.frame` adds those).
    public func lowered() -> (type: UInt16, flags: UInt16, data: [UInt8]) {
        switch self {

        // MARK: Control
        case let .header(dual, video, dpiX, dpiY, version):          // §2.3.3.3
            var w = ByteWriter()
            w.appendUInt32(version)
            w.appendUInt32(video ? 0x0000_0001 : 0)                   // EmfPlusFlags V bit
            w.appendUInt32(dpiX)
            w.appendUInt32(dpiY)
            return (0x4001, dual ? 0x0001 : 0, w.bytes)
        case .endOfFile:                                             // §2.3.3.1
            return (0x4002, 0, [])
        case .getDC:                                                // §2.3.3.2
            return (0x4004, 0, [])
        case .comment(let data):                                    // §2.3.3
            return (0x4003, 0, data)

        // MARK: Drawing
        case .clear(let color):                                     // §2.3.4.1
            var w = ByteWriter(); w.appendARGB(color)
            return (0x4009, 0, w.bytes)

        case let .fillRects(brush, rects):                          // §2.3.4 FillRects
            var w = ByteWriter()
            let flags = appendBrushId(brush, into: &w)
            w.appendUInt32(UInt32(clamping: rects.count))
            for rect in rects { w.appendRectF(rect) }
            return (0x400A, flags, w.bytes)

        case let .drawRects(penID, rects):                          // §2.3.4 DrawRects
            var w = ByteWriter()
            w.appendUInt32(UInt32(clamping: rects.count))
            for rect in rects { w.appendRectF(rect) }
            return (0x400B, UInt16(penID), w.bytes)

        case let .fillPolygon(brush, points):                       // §2.3.4 FillPolygon
            var w = ByteWriter()
            let flags = appendBrushId(brush, into: &w)
            w.appendUInt32(UInt32(clamping: points.count))
            for point in points { w.appendPointF(point) }
            return (0x400C, flags, w.bytes)

        case let .drawLines(penID, points, closed):                 // §2.3.4 DrawLines
            var w = ByteWriter()
            w.appendUInt32(UInt32(clamping: points.count))
            for point in points { w.appendPointF(point) }
            return (0x400D, UInt16(penID) | (closed ? 0x2000 : 0), w.bytes)

        case let .fillEllipse(brush, rect):                         // §2.3.4 FillEllipse
            var w = ByteWriter()
            let flags = appendBrushId(brush, into: &w)
            w.appendRectF(rect)
            return (0x400E, flags, w.bytes)

        case let .drawEllipse(penID, rect):                         // §2.3.4 DrawEllipse
            var w = ByteWriter(); w.appendRectF(rect)
            return (0x400F, UInt16(penID), w.bytes)

        case let .fillPie(brush, start, sweep, rect):               // §2.3.4 FillPie
            var w = ByteWriter()
            let flags = appendBrushId(brush, into: &w)
            w.appendFloat(start); w.appendFloat(sweep); w.appendRectF(rect)
            return (0x4010, flags, w.bytes)

        case let .drawPie(penID, start, sweep, rect):               // §2.3.4 DrawPie
            var w = ByteWriter()
            w.appendFloat(start); w.appendFloat(sweep); w.appendRectF(rect)
            return (0x4011, UInt16(penID), w.bytes)

        case let .drawArc(penID, start, sweep, rect):               // §2.3.4 DrawArc
            var w = ByteWriter()
            w.appendFloat(start); w.appendFloat(sweep); w.appendRectF(rect)
            return (0x4012, UInt16(penID), w.bytes)

        case let .fillPath(pathID, brush):                          // §2.3.4 FillPath
            var w = ByteWriter()
            let s = appendBrushId(brush, into: &w)
            return (0x4014, UInt16(pathID) | s, w.bytes)

        case let .drawPath(pathID, penID):                          // §2.3.4 DrawPath
            var w = ByteWriter(); w.appendUInt32(penID)
            return (0x4015, UInt16(pathID), w.bytes)

        case let .drawBeziers(penID, points):                       // §2.3.4 DrawBeziers
            var w = ByteWriter()
            w.appendUInt32(UInt32(clamping: points.count))
            for point in points { w.appendPointF(point) }
            return (0x4019, UInt16(penID), w.bytes)

        case let .fillClosedCurve(brush, tension, points, winding):  // §2.3.4 FillClosedCurve
            var w = ByteWriter()
            let s = appendBrushId(brush, into: &w)
            w.appendFloat(tension)
            w.appendUInt32(UInt32(clamping: points.count))
            for point in points { w.appendPointF(point) }
            return (0x4016, s | (winding ? 0x2000 : 0), w.bytes)

        case let .drawClosedCurve(penID, tension, points):          // §2.3.4 DrawClosedCurve
            var w = ByteWriter()
            w.appendFloat(tension)
            w.appendUInt32(UInt32(clamping: points.count))
            for point in points { w.appendPointF(point) }
            return (0x4017, UInt16(penID), w.bytes)

        case let .drawCurve(penID, tension, offset, numSegments, points):  // §2.3.4.5 DrawCurve
            var w = ByteWriter()
            w.appendFloat(tension)
            w.appendUInt32(offset)
            w.appendUInt32(numSegments)
            w.appendUInt32(UInt32(clamping: points.count))
            for point in points { w.appendPointF(point) }
            return (0x4018, UInt16(penID), w.bytes)

        case let .drawString(fontID, brush, formatID, layoutRect, text):  // §2.3.4.14
            var w = ByteWriter()
            let s = appendBrushId(brush, into: &w)
            w.appendUInt32(formatID)
            let units = Array(text.utf16)
            w.appendUInt32(UInt32(clamping: units.count))
            w.appendRectF(layoutRect)
            for unit in units { w.appendUInt16(unit) }
            return (0x401C, UInt16(fontID) | s, w.bytes)

        case let .drawImage(imageID, attributesID, srcUnit, srcRect, destRect):  // §2.3.4.8
            var w = ByteWriter()
            w.appendUInt32(attributesID ?? Self.noImageAttributes)
            w.appendInt32(srcUnit)
            w.appendRectF(srcRect)
            w.appendRectF(destRect)
            return (0x401A, UInt16(imageID), w.bytes)

        case let .drawImagePoints(imageID, attributesID, srcUnit, srcRect, points):  // §2.3.4.9
            var w = ByteWriter()
            w.appendUInt32(attributesID ?? Self.noImageAttributes)
            w.appendInt32(srcUnit)
            w.appendRectF(srcRect)
            w.appendUInt32(UInt32(clamping: points.count))
            for point in points { w.appendPointF(point) }
            return (0x401B, UInt16(imageID), w.bytes)

        // MARK: Save / container (§2.3.7). Layouts are the inverse of EMFRender's
        // verified decoders (EMFPlusPlayback firstU32 / beginContainer).
        case .save(let index):
            return (0x4025, 0, u32Bytes(index))
        case .restore(let index):
            return (0x4026, 0, u32Bytes(index))
        case let .beginContainer(dest, src, index, pageUnit):
            var w = ByteWriter()
            w.appendRectF(dest); w.appendRectF(src); w.appendUInt32(index)
            return (0x4027, UInt16(pageUnit), w.bytes)
        case .beginContainerNoParams(let index):
            return (0x4028, 0, u32Bytes(index))
        case .endContainer(let index):
            return (0x4029, 0, u32Bytes(index))

        // MARK: Transforms (§2.3.9). The A/order flag (0x2000) and the field
        // layouts invert EMFRender's verified decoders (EMFPlusPlayback
        // set/multiply/translate/scale/rotate/setPageTransform).
        case .setWorldTransform(let m):
            var w = ByteWriter(); w.appendTransformMatrix(m)
            return (0x402A, 0, w.bytes)
        case .resetWorldTransform:
            return (0x402B, 0, [])
        case let .multiplyWorldTransform(m, post):
            var w = ByteWriter(); w.appendTransformMatrix(m)
            return (0x402C, post ? 0x2000 : 0, w.bytes)
        case let .translateWorldTransform(dx, dy, post):
            var w = ByteWriter(); w.appendFloat(dx); w.appendFloat(dy)
            return (0x402D, post ? 0x2000 : 0, w.bytes)
        case let .scaleWorldTransform(sx, sy, post):
            var w = ByteWriter(); w.appendFloat(sx); w.appendFloat(sy)
            return (0x402E, post ? 0x2000 : 0, w.bytes)
        case let .rotateWorldTransform(angle, post):
            var w = ByteWriter(); w.appendFloat(angle)
            return (0x402F, post ? 0x2000 : 0, w.bytes)
        case let .setPageTransform(scale, pageUnit):
            var w = ByteWriter(); w.appendFloat(scale)
            return (0x4030, UInt16(pageUnit), w.bytes)

        // MARK: Property (§2.3.6) — value in Flags, no data. SetAntiAliasMode's
        // bit 0 is the antialias flag EMFPlusPlayback reads; SmoothingMode is
        // placed in the high bits (arbitrated, matters only for from-scratch
        // builds — real files round-trip these records via raw passthrough).
        case let .setAntiAliasMode(on, smoothing):
            return (0x401E, UInt16(smoothing & 0x7F) << 1 | (on ? 1 : 0), [])
        case .setTextRenderingHint(let hint):
            return (0x401F, UInt16(hint), [])
        case .setCompositingMode(let mode):
            return (0x4023, UInt16(mode), [])
        case .setCompositingQuality(let quality):
            return (0x4024, UInt16(quality), [])
        case .setInterpolationMode(let mode):
            return (0x4021, UInt16(mode), [])
        case .setPixelOffsetMode(let mode):
            return (0x4022, UInt16(mode), [])

        // MARK: Clipping (§2.3.1). CombineMode in Flags bits 8–11 and the
        // ObjectID low byte invert EMFPlusPlayback's setClip* decoders.
        case .resetClip:
            return (0x4031, 0, [])
        case let .setClipRect(rect, mode):
            var w = ByteWriter(); w.appendRectF(rect)
            return (0x4032, UInt16(mode & 0x0F) << 8, w.bytes)
        case let .setClipPath(pathID, mode):
            return (0x4033, UInt16(pathID) | UInt16(mode & 0x0F) << 8, [])
        case let .setClipRegion(regionID, mode):
            return (0x4034, UInt16(regionID) | UInt16(mode & 0x0F) << 8, [])
        case let .offsetClip(dx, dy):
            var w = ByteWriter(); w.appendFloat(dx); w.appendFloat(dy)
            return (0x4035, 0, w.bytes)
        }
    }

    /// This record's framed wire bytes (header + data + padding).
    public func framed() -> [UInt8] {
        let r = lowered()
        return EMFPlusCommentWriter.frame(type: r.type, flags: r.flags, data: r.data)
    }

    // MARK: - Helpers

    /// Writes the BrushId field and returns the S flag (0x8000 when the brush is a
    /// direct colour, clear for an object-table index) — the shared encoding of a
    /// fill record's brush ([MS-EMFPLUS] §2.3.4).
    private func appendBrushId(_ brush: EMFPlusBrushSource, into w: inout ByteWriter) -> UInt16 {
        switch brush {
        case .color(let argb):
            w.appendARGB(argb)
            return 0x8000
        case .object(let id):
            w.appendUInt32(UInt32(id))
            return 0
        }
    }

    private func u32Bytes(_ value: UInt32) -> [UInt8] {
        var w = ByteWriter(); w.appendUInt32(value); return w.bytes
    }
}
