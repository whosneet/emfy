import Foundation
import EMFParse

/// Serialises a decoded `EMFPlusObjectValue` back to its EmfPlusObject payload
/// bytes ([MS-EMFPLUS] §2.2.1), the exact inverse of EMFParse's object decoders
/// (`decodeBrush`, `decodePen`, `decodePath`, …). Each field is emitted in the
/// decoder's read order, so a value the decoder produced re-encodes to an EQUAL
/// payload — byte-identical whenever the source payload was already canonical
/// (no trailing AlignmentPadding and no lossy field; see `isFaithfullyEncodable`).
///
/// The output is the OBJECT PAYLOAD only — the bytes that go in an
/// `EmfPlusObjectDefinition.data` — with no EMF+ record header and no
/// EmfPlusObject continuation framing (that is `EMFPlusCommentWriter`'s job).
public enum EMFPlusObjectEncoder {

    /// Encodes `value` to its object payload bytes, or throws for a value with no
    /// faithful payload form here (a lossily-decoded value; see
    /// `isFaithfullyEncodable`).
    public static func encode(_ value: EMFPlusObjectValue) throws(EMFWriteError) -> [UInt8] {
        switch value {
        case .brush(let brush):
            return try encodeBrush(brush)
        case .pen(let pen):
            return try encodePen(pen)
        case .path(let path):
            return try encodePath(path)
        case .region(let region):
            return try encodeRegion(region)
        case .font(let font):
            return encodeFont(font)
        case .stringFormat(let format):
            return encodeStringFormat(format)
        case .image(let image):
            return encodeImage(image)
        case .imageAttributes(let attributes):
            return encodeImageAttributes(attributes)
        case .undecoded(_, let data):
            // A type this slice does not decode (standalone CustomLineCap, …) is
            // kept verbatim — the write-side analogue of passthrough.
            return [UInt8](data)
        case .malformed(let type, let reason):
            throw .unsupportedPayload(label: "malformed EMF+ object \(type) (\(reason))")
        }
    }

    /// Whether `encode` reproduces `value` as an EQUAL payload a re-decode accepts.
    /// False for the lossy decodes: a `.malformed` object, a path gradient that
    /// stopped mid-decode (`undecodedTail != nil`), and a path whose compressed
    /// i16 points carry a non-integral/out-of-range coordinate (a from-scratch
    /// mistake, never a decoder product). Fonts/StringFormats/ImageAttributes
    /// drop Reserved words (assumed 0), so they re-encode EQUAL but are
    /// byte-identical only when the source Reserved was 0 — the universal case.
    public static func isFaithfullyEncodable(_ value: EMFPlusObjectValue) -> Bool {
        switch value {
        case .malformed:
            return false
        case .brush(let brush):
            if case .pathGradient(let g) = brush.data { return g.undecodedTail == nil }
            return true
        case .pen(let pen):
            if case .pathGradient(let g) = pen.brush.data { return g.undecodedTail == nil }
            return true
        case .path(let path):
            return pathIsEncodable(path)
        default:
            return true
        }
    }

    // MARK: - Brush ([MS-EMFPLUS] §2.2.1.1)

    static func encodeBrush(_ brush: EMFPlusBrush) throws(EMFWriteError) -> [UInt8] {
        var w = ByteWriter()
        w.appendUInt32(brush.version)
        w.appendUInt32(brush.brushType.rawValue)
        switch brush.data {
        case .solid(let color):                                   // §2.2.2.43
            w.appendARGB(color)
        case .hatch(let style, let foreColor, let backColor):     // §2.2.2.20
            w.appendUInt32(style.rawValue)
            w.appendARGB(foreColor)
            w.appendARGB(backColor)
        case .linearGradient(let gradient):                       // §2.2.2.24
            try encodeLinearGradient(gradient, into: &w)
        case .pathGradient(let gradient):                         // §2.2.2.29
            try encodePathGradient(gradient, into: &w)
        case .texture(let raw):                                   // §2.2.2.45
            w.appendData(raw)
        }
        return w.bytes
    }

    /// EmfPlusLinearGradientBrushData ([MS-EMFPLUS] §2.2.2.24 + §2.2.2.25). The
    /// optional TransformMatrix and blend blocks are emitted strictly under the
    /// same BrushData flags the decoder read them with, so the stream round-trips.
    private static func encodeLinearGradient(
        _ g: EMFPlusLinearGradientBrush, into w: inout ByteWriter
    ) throws(EMFWriteError) {
        let flags = g.brushDataFlags
        w.appendUInt32(flags)
        w.appendInt32(g.wrapMode)
        w.appendRectF(g.rect)
        w.appendARGB(g.startColor)
        w.appendARGB(g.endColor)
        w.appendUInt32(g.reserved1)
        w.appendUInt32(g.reserved2)
        if flags & brushTransform != 0, let m = g.transform {
            w.appendTransformMatrix(m)
        }
        try encodeBlend(g.blend, into: &w)
    }

    /// EmfPlusPathGradientBrushData ([MS-EMFPLUS] §2.2.2.29 + §2.2.2.30). Only the
    /// cleanly-decoded form (`undecodedTail == nil`) is faithful; the partial
    /// recovery form is rejected (`isFaithfullyEncodable` screens it first).
    private static func encodePathGradient(
        _ g: EMFPlusPathGradientBrush, into w: inout ByteWriter
    ) throws(EMFWriteError) {
        guard g.undecodedTail == nil else {
            throw .unsupportedPayload(label: "path-gradient brush decoded partially (undecodedTail)")
        }
        let flags = g.brushDataFlags
        w.appendUInt32(flags)
        w.appendInt32(g.wrapMode)
        w.appendARGB(g.centerColor)
        w.appendPointF(g.centerPoint)
        w.appendUInt32(UInt32(clamping: g.surroundingColors.count))
        for color in g.surroundingColors { w.appendARGB(color) }
        switch g.boundary {
        case .path(let raw):                                      // §2.2.2.6
            w.appendInt32(Int32(clamping: raw.count))
            w.appendData(raw)
        case .points(let points):                                 // §2.2.2.7
            w.appendInt32(Int32(clamping: points.count))
            for point in points { w.appendPointF(point) }
        case nil:
            break
        }
        if flags & brushTransform != 0, let m = g.transform {
            w.appendTransformMatrix(m)
        }
        try encodeBlend(g.blend, into: &w)
        if flags & brushFocusScales != 0, let focus = g.focusScale {
            w.appendUInt32(focus.count)
            w.appendFloat(focus.x)
            w.appendFloat(focus.y)
        }
    }

    /// The optional gradient blend ([MS-EMFPLUS] §2.2.2.4 / §2.2.2.5). The stored
    /// factor arrays are already in stream order (vertical before horizontal when
    /// both are present), so they are emitted in array order.
    private static func encodeBlend(
        _ blend: EMFPlusGradientBlend?, into w: inout ByteWriter
    ) throws(EMFWriteError) {
        switch blend {
        case .presetColors(let colors):                           // §2.2.2.4
            guard colors.positions.count == colors.colors.count else {
                throw .unsupportedPayload(label: "gradient preset colours: position/colour count mismatch")
            }
            w.appendUInt32(UInt32(clamping: colors.positions.count))
            for position in colors.positions { w.appendFloat(position) }
            for color in colors.colors { w.appendARGB(color) }
        case .blendFactors(let arrays):                           // §2.2.2.5
            for array in arrays {
                guard array.positions.count == array.factors.count else {
                    throw .unsupportedPayload(label: "gradient blend factors: position/factor count mismatch")
                }
                w.appendUInt32(UInt32(clamping: array.positions.count))
                for position in array.positions { w.appendFloat(position) }
                for factor in array.factors { w.appendFloat(factor) }
            }
        case nil:
            break
        }
    }

    // MARK: - Pen ([MS-EMFPLUS] §2.2.1.7)

    static func encodePen(_ pen: EMFPlusPen) throws(EMFWriteError) -> [UInt8] {
        var w = ByteWriter()
        w.appendUInt32(pen.version)
        w.appendUInt32(pen.type)
        let d = pen.penData
        w.appendUInt32(d.flags)                                   // §2.2.2.33
        w.appendUInt32(d.unit)
        w.appendFloat(d.width)
        // Optional blocks, strictly in §2.2.2.34 order gated by the §2.1.2.7 flags.
        if d.flags & penTransform != 0, let m = d.transform { w.appendTransformMatrix(m) }
        if d.flags & penStartCap != 0, let v = d.startCap { w.appendInt32(v) }
        if d.flags & penEndCap != 0, let v = d.endCap { w.appendInt32(v) }
        if d.flags & penJoin != 0, let v = d.join { w.appendInt32(v) }
        if d.flags & penMiterLimit != 0, let v = d.miterLimit { w.appendFloat(v) }
        if d.flags & penLineStyle != 0, let v = d.lineStyle { w.appendInt32(v) }
        if d.flags & penDashedLineCap != 0, let v = d.dashedLineCap { w.appendInt32(v) }
        if d.flags & penDashOffset != 0, let v = d.dashOffset { w.appendFloat(v) }
        if d.flags & penDashedLine != 0, let values = d.dashedLine {
            w.appendUInt32(UInt32(clamping: values.count))        // §2.2.2.16 DashedLineDataSize
            for value in values { w.appendFloat(value) }
        }
        if d.flags & penNonCenter != 0, let v = d.penAlignment { w.appendInt32(v) }
        if d.flags & penCompoundLine != 0, let values = d.compoundLine {
            w.appendUInt32(UInt32(clamping: values.count))        // §2.2.2.9 CompoundLineDataSize
            for value in values { w.appendFloat(value) }
        }
        if d.flags & penCustomStartCap != 0, let caps = d.customStartCap {
            w.appendUInt32(UInt32(clamping: caps.count))          // §2.2.2.15 CustomStartCapSize
            w.appendData(caps)
        }
        if d.flags & penCustomEndCap != 0, let caps = d.customEndCap {
            w.appendUInt32(UInt32(clamping: caps.count))          // §2.2.2.11 CustomEndCapSize
            w.appendData(caps)
        }
        // BrushObject: the pen's final field (§2.2.1.7).
        w.appendBytes(try encodeBrush(pen.brush))
        return w.bytes
    }

    // MARK: - Path ([MS-EMFPLUS] §2.2.1.6)

    static func encodePath(_ path: EMFPlusPath) throws(EMFWriteError) -> [UInt8] {
        guard pathIsEncodable(path) else {
            throw .unsupportedPayload(label: "EMF+ path: compressed point not representable as Int16")
        }
        var w = ByteWriter()
        w.appendUInt32(path.version)
        w.appendUInt32(path.pointCount)
        w.appendUInt32(path.flags)
        if path.usesAbsoluteInt16Points {
            // §2.2.2.35 EmfPlusPoint: X (i16), Y (i16), packed two per DWORD. The
            // decode widened these to Float losslessly, so Int16(exactly:) recovers
            // the original (`pathIsEncodable` already guaranteed it).
            for point in path.points {
                let x = UInt16(bitPattern: Int16(point.x))
                let y = UInt16(bitPattern: Int16(point.y))
                w.appendUInt32(UInt32(x) | (UInt32(y) << 16))
            }
        } else {
            for point in path.points { w.appendPointF(EMFPlusPointF(x: point.x, y: point.y)) }
        }
        w.appendBytes(path.pointTypes)                            // §2.2.2.31, one byte per point
        return w.bytes
    }

    /// True when a path's points can be serialised faithfully: an uncompressed
    /// path always can; a compressed (i16) path only when every coordinate is an
    /// integer in the Int16 range (which every DECODED compressed path satisfies).
    private static func pathIsEncodable(_ path: EMFPlusPath) -> Bool {
        guard path.usesAbsoluteInt16Points else { return true }
        for point in path.points where Int16(exactly: point.x) == nil || Int16(exactly: point.y) == nil {
            return false
        }
        return true
    }

    // MARK: - Font ([MS-EMFPLUS] §2.2.1.3)

    /// Reserved is not retained by the decoder; it is written as 0 (its value in
    /// every real font). A FamilyName with a lone surrogate was lossily decoded to
    /// U+FFFD and will not round-trip bit-exactly — not a decoder concern for a
    /// well-formed font.
    static func encodeFont(_ font: EMFPlusFont) -> [UInt8] {
        var w = ByteWriter()
        w.appendUInt32(font.version)
        w.appendFloat(font.emSize)
        w.appendUInt32(font.sizeUnit)
        w.appendInt32(font.styleFlags)
        w.appendUInt32(0)                                         // Reserved (§2.2.1.3)
        let units = Array(font.familyName.utf16)
        w.appendUInt32(UInt32(clamping: units.count))            // Length (characters)
        for unit in units { w.appendUInt16(unit) }
        return w.bytes
    }

    // MARK: - Image ([MS-EMFPLUS] §2.2.1.4)

    static func encodeImage(_ image: EMFPlusImage) -> [UInt8] {
        var w = ByteWriter()
        w.appendUInt32(image.version)
        switch image.content {
        case .bitmap(let header, let data):                       // §2.2.2.2
            w.appendUInt32(0x0000_0001)                           // ImageDataTypeBitmap
            w.appendInt32(header.width)
            w.appendInt32(header.height)
            w.appendInt32(header.stride)
            w.appendUInt32(header.pixelFormat)
            w.appendUInt32(header.bitmapDataType)
            w.appendData(data)
        case .metafile(let header, let data):                     // §2.2.2.27
            w.appendUInt32(0x0000_0002)                           // ImageDataTypeMetafile
            w.appendUInt32(header.metafileType)
            w.appendUInt32(header.metafileDataSize)
            w.appendData(data)
        }
        return w.bytes
    }

    /// EmfPlusImageAttributes ([MS-EMFPLUS] §2.2.1.5). Reserved1/Reserved2 are not
    /// retained by the decoder; both are written as 0.
    static func encodeImageAttributes(_ a: EMFPlusImageAttributes) -> [UInt8] {
        var w = ByteWriter()
        w.appendUInt32(a.version)
        w.appendUInt32(0)                                         // Reserved1
        w.appendUInt32(a.wrapMode)
        w.appendARGB(a.clampColor)
        w.appendInt32(a.objectClamp)
        w.appendUInt32(0)                                         // Reserved2
        return w.bytes
    }

    // MARK: - StringFormat ([MS-EMFPLUS] §2.2.1.9)

    static func encodeStringFormat(_ f: EMFPlusStringFormat) -> [UInt8] {
        var w = ByteWriter()
        w.appendUInt32(f.version)
        w.appendUInt32(f.stringFormatFlags)
        w.appendUInt32(f.language)
        w.appendUInt32(f.stringAlignment)
        w.appendUInt32(f.lineAlign)
        w.appendUInt32(f.digitSubstitution)
        w.appendUInt32(f.digitLanguage)
        w.appendFloat(f.firstTabOffset)
        w.appendInt32(f.hotkeyPrefix)
        w.appendFloat(f.leadingMargin)
        w.appendFloat(f.trailingMargin)
        w.appendFloat(f.tracking)
        w.appendUInt32(f.trimming)
        w.appendInt32(Int32(clamping: f.tabStops.count))         // §2.2.2.44 TabStopCount
        w.appendInt32(Int32(clamping: f.characterRanges.count))  // RangeCount
        for stop in f.tabStops { w.appendFloat(stop) }
        for range in f.characterRanges {
            w.appendInt32(range.first)
            w.appendInt32(range.length)
        }
        return w.bytes
    }

    // MARK: - Region ([MS-EMFPLUS] §2.2.1.8)

    static func encodeRegion(_ region: EMFPlusRegion) throws(EMFWriteError) -> [UInt8] {
        var w = ByteWriter()
        w.appendUInt32(region.version)
        w.appendUInt32(region.declaredNodeCount)                  // advisory, kept verbatim
        try encodeRegionNode(region.root, into: &w)
        return w.bytes
    }

    /// One EmfPlusRegionNode ([MS-EMFPLUS] §2.2.2.40), recursing into combine nodes.
    private static func encodeRegionNode(
        _ node: EMFPlusRegionNode, into w: inout ByteWriter
    ) throws(EMFWriteError) {
        switch node {
        case .rect(let rect):
            w.appendUInt32(0x1000_0000)                           // RegionNodeDataTypeRect
            w.appendRectF(rect)
        case .path(let path):                                     // §2.2.2.42
            let bytes = try encodePath(path)
            w.appendUInt32(0x1000_0001)                           // RegionNodeDataTypePath
            w.appendInt32(Int32(clamping: bytes.count))           // RegionNodePathLength
            w.appendBytes(bytes)
        case .empty:
            w.appendUInt32(0x1000_0002)                           // RegionNodeDataTypeEmpty
        case .infinite:
            w.appendUInt32(0x1000_0003)                           // RegionNodeDataTypeInfinite
        case .combine(let operation, let left, let right):        // §2.2.2.41
            w.appendUInt32(operation.rawValue)
            try encodeRegionNode(left, into: &w)
            try encodeRegionNode(right, into: &w)
        }
    }

    // MARK: - Flag masks (mirror EMFParse's private decoder masks)

    // BrushData flags ([MS-EMFPLUS] §2.1.2.1).
    private static let brushTransform: UInt32 = 0x0000_0002
    private static let brushFocusScales: UInt32 = 0x0000_0040
    // PenData flags ([MS-EMFPLUS] §2.1.2.7).
    private static let penTransform: UInt32 = 0x0000_0001
    private static let penStartCap: UInt32 = 0x0000_0002
    private static let penEndCap: UInt32 = 0x0000_0004
    private static let penJoin: UInt32 = 0x0000_0008
    private static let penMiterLimit: UInt32 = 0x0000_0010
    private static let penLineStyle: UInt32 = 0x0000_0020
    private static let penDashedLineCap: UInt32 = 0x0000_0040
    private static let penDashOffset: UInt32 = 0x0000_0080
    private static let penDashedLine: UInt32 = 0x0000_0100
    private static let penNonCenter: UInt32 = 0x0000_0200
    private static let penCompoundLine: UInt32 = 0x0000_0400
    private static let penCustomStartCap: UInt32 = 0x0000_0800
    private static let penCustomEndCap: UInt32 = 0x0000_1000
}
