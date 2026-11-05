import Foundation
import Testing
import EMFParse
import EMFWrite

/// Per-object round trip for EMF+ objects: a hand-built EmfPlusObject payload
/// decodes (via `EMFPlusObjectDefinition.decodedValue`) to a typed value that
/// `EMFPlusObjectEncoder` re-encodes byte-identically — a decode→encode fixed
/// point, for every brush/pen/path/font/image/string-format/region variant the
/// EMFParse decoders produce.
@Suite("EMF+ object round trip (decode → encode is byte-identical)")
struct EMFPlusObjectRoundTripTests {

    // MARK: - Fixture helpers

    /// An EmfPlusARGB (§2.2.2.1): one little-endian u32, low byte Blue.
    static func argb(_ a: UInt8, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] {
        var w = LE(); w.u32(UInt32(b) | UInt32(g) << 8 | UInt32(r) << 16 | UInt32(a) << 24)
        return w.bytes
    }
    static func rectF(_ x: Float, _ y: Float, _ w: Float, _ h: Float) -> [UInt8] {
        var b = LE(); b.f32(x); b.f32(y); b.f32(w); b.f32(h); return b.bytes
    }
    static func pointF(_ x: Float, _ y: Float) -> [UInt8] {
        var b = LE(); b.f32(x); b.f32(y); return b.bytes
    }
    static func matrix() -> [UInt8] {
        var b = LE(); for v in [Float(1), 0, 0, 1, 7, 9] { b.f32(v) }; return b.bytes
    }

    /// Decodes `payload` as an object of `type`, asserts the value is faithful, and
    /// that re-encoding reproduces `payload` exactly.
    func roundTrip(
        _ type: EMFPlusObjectType,
        _ payload: [UInt8],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let def = EMFPlusObjectDefinition(objectID: 0, objectType: type, data: Data(payload))
        let value = def.decodedValue()
        #expect(
            EMFPlusObjectEncoder.isFaithfullyEncodable(value),
            "not faithfully encodable: \(value)", sourceLocation: sourceLocation)
        let encoded = try EMFPlusObjectEncoder.encode(value)
        #expect(
            encoded == payload,
            "re-encoded bytes differ (\(encoded.count) vs \(payload.count))",
            sourceLocation: sourceLocation)
    }

    // MARK: - Brush (§2.2.1.1)

    @Test func solidBrush() throws {
        var b = LE(); b.u32(1); b.u32(0); b.raw(Self.argb(255, 10, 20, 30))
        try roundTrip(.brush, b.bytes)
    }

    @Test func hatchBrush() throws {
        var b = LE(); b.u32(1); b.u32(1)
        b.u32(2)                                   // HatchStyle forwardDiagonal
        b.raw(Self.argb(255, 1, 2, 3))             // ForeColor
        b.raw(Self.argb(255, 4, 5, 6))             // BackColor
        try roundTrip(.brush, b.bytes)
    }

    @Test func linearGradientPlain() throws {
        var b = LE(); b.u32(1); b.u32(4)
        b.u32(0)                                   // BrushDataFlags
        b.i32(1)                                   // WrapMode
        b.raw(Self.rectF(0, 0, 100, 50))
        b.raw(Self.argb(255, 255, 0, 0))           // StartColor
        b.raw(Self.argb(255, 0, 0, 255))           // EndColor
        b.u32(0); b.u32(0)                         // Reserved1/2
        try roundTrip(.brush, b.bytes)
    }

    @Test func linearGradientTransformAndPresetColors() throws {
        var b = LE(); b.u32(1); b.u32(4)
        b.u32(0x02 | 0x04)                         // Transform | PresetColors
        b.i32(0)
        b.raw(Self.rectF(1, 2, 3, 4))
        b.raw(Self.argb(255, 0, 0, 0))
        b.raw(Self.argb(255, 255, 255, 255))
        b.u32(0); b.u32(0)
        b.raw(Self.matrix())                       // TransformMatrix
        b.u32(2)                                   // PresetColors count
        b.f32(0); b.f32(1)                         // positions
        b.raw(Self.argb(255, 10, 10, 10))
        b.raw(Self.argb(255, 20, 20, 20))
        try roundTrip(.brush, b.bytes)
    }

    @Test func linearGradientBlendFactorsVThenH() throws {
        var b = LE(); b.u32(1); b.u32(4)
        b.u32(0x08 | 0x10)                         // BlendFactorsH | BlendFactorsV
        b.i32(0)
        b.raw(Self.rectF(0, 0, 10, 10))
        b.raw(Self.argb(255, 1, 1, 1))
        b.raw(Self.argb(255, 2, 2, 2))
        b.u32(0); b.u32(0)
        // Vertical array first (count 2), then horizontal (count 3).
        b.u32(2); b.f32(0); b.f32(1); b.f32(0.2); b.f32(0.8)
        b.u32(3); b.f32(0); b.f32(0.5); b.f32(1); b.f32(0.1); b.f32(0.5); b.f32(0.9)
        try roundTrip(.brush, b.bytes)
    }

    @Test func textureBrush() throws {
        var b = LE(); b.u32(1); b.u32(2)
        b.raw([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02])   // opaque BrushData tail
        try roundTrip(.brush, b.bytes)
    }

    @Test func pathGradientPointsBoundary() throws {
        var b = LE(); b.u32(1); b.u32(3)
        b.u32(0)                                   // flags (no path/transform/blend/focus)
        b.i32(1)                                   // WrapMode
        b.raw(Self.argb(255, 128, 128, 128))       // CenterColor
        b.raw(Self.pointF(50, 50))                 // CenterPoint
        b.u32(2)                                   // SurroundingColorCount
        b.raw(Self.argb(255, 1, 2, 3))
        b.raw(Self.argb(255, 4, 5, 6))
        b.i32(3)                                   // boundary point count
        b.raw(Self.pointF(0, 0)); b.raw(Self.pointF(100, 0)); b.raw(Self.pointF(50, 100))
        try roundTrip(.brush, b.bytes)
    }

    // MARK: - Pen (§2.2.1.7)

    @Test func penStartCapAndMiterLimitWithSolidBrush() throws {
        var b = LE(); b.u32(1); b.u32(0)           // Version, Type
        b.u32(0x02 | 0x10)                         // StartCap | MiterLimit
        b.u32(0)                                   // PenUnit
        b.f32(2.5)                                 // PenWidth
        b.i32(1)                                   // StartCap
        b.f32(10)                                  // MiterLimit
        // Trailing BrushObject (solid).
        b.u32(1); b.u32(0); b.raw(Self.argb(255, 9, 8, 7))
        try roundTrip(.pen, b.bytes)
    }

    @Test func penDashedLineAndCustomStartCap() throws {
        var b = LE(); b.u32(1); b.u32(0)
        b.u32(0x100 | 0x800)                       // DashedLine | CustomStartCap
        b.u32(0)
        b.f32(1)
        b.u32(3); b.f32(1); b.f32(2); b.f32(1)     // DashedLineData: count 3
        b.u32(5); b.raw([0xAA, 0xBB, 0xCC, 0xDD, 0xEE])  // CustomStartCap: size 5 + bytes
        b.u32(1); b.u32(0); b.raw(Self.argb(255, 0, 0, 0))   // BrushObject
        try roundTrip(.pen, b.bytes)
    }

    // MARK: - Path (§2.2.1.6)

    @Test func pathFloatPoints() throws {
        var b = LE(); b.u32(2); b.u32(3); b.u32(0)
        b.raw(Self.pointF(0, 0)); b.raw(Self.pointF(10, 0)); b.raw(Self.pointF(10, 10))
        b.raw([0x00, 0x01, 0x01])                  // PathPointTypes
        try roundTrip(.path, b.bytes)
    }

    @Test func pathCompressedInt16Points() throws {
        var b = LE(); b.u32(2); b.u32(2); b.u32(0x4000)   // C flag → i16 points
        b.i16(-5); b.i16(7)                        // point 0
        b.i16(100); b.i16(-200)                    // point 1
        b.raw([0x00, 0x01])
        try roundTrip(.path, b.bytes)
    }

    // MARK: - Font (§2.2.1.3)

    @Test func font() throws {
        var b = LE(); b.u32(1); b.f32(12); b.u32(0); b.i32(0x3)   // version, emSize, sizeUnit, style
        b.u32(0)                                   // Reserved
        b.u32(5); b.utf16("Arial")                 // Length + FamilyName
        try roundTrip(.font, b.bytes)
    }

    // MARK: - Image (§2.2.1.4)

    @Test func imageBitmap() throws {
        var b = LE(); b.u32(1); b.u32(1)           // Version, ImageDataTypeBitmap
        b.i32(4); b.i32(2); b.i32(16); b.u32(0x26200A); b.u32(0)  // width/height/stride/pixelFormat/type
        b.raw([UInt8](repeating: 0x5A, count: 32)) // raw bitmap bytes
        try roundTrip(.image, b.bytes)
    }

    @Test func imageMetafile() throws {
        var b = LE(); b.u32(1); b.u32(2)           // Version, ImageDataTypeMetafile
        b.u32(1); b.u32(8)                         // MetafileType, MetafileDataSize
        b.raw([1, 2, 3, 4, 5, 6, 7, 8])
        try roundTrip(.image, b.bytes)
    }

    @Test func imageAttributes() throws {
        var b = LE(); b.u32(1); b.u32(0); b.u32(2) // Version, Reserved1, WrapMode
        b.raw(Self.argb(255, 7, 7, 7))             // ClampColor
        b.i32(1); b.u32(0)                         // ObjectClamp, Reserved2
        try roundTrip(.imageAttributes, b.bytes)
    }

    // MARK: - StringFormat (§2.2.1.9)

    @Test func stringFormatWithTabsAndRanges() throws {
        var b = LE(); b.u32(1)                     // Version
        b.u32(0); b.u32(0); b.u32(1); b.u32(2)     // flags, language, alignment, lineAlign
        b.u32(0); b.u32(0)                         // digitSubstitution, digitLanguage
        b.f32(0)                                   // firstTabOffset
        b.i32(0)                                   // hotkeyPrefix
        b.f32(1); b.f32(2); b.f32(1)               // leadingMargin, trailingMargin, tracking
        b.u32(0)                                   // trimming
        b.i32(2); b.i32(1)                         // TabStopCount, RangeCount
        b.f32(10); b.f32(20)                       // TabStops
        b.i32(0); b.i32(5)                         // CharRange
        try roundTrip(.stringFormat, b.bytes)
    }

    // MARK: - Region (§2.2.1.8)

    @Test func regionCombineTree() throws {
        var b = LE(); b.u32(1); b.u32(3)           // Version, RegionNodeCount
        b.u32(0x01)                                // combine: And
        b.u32(0x10000000); b.raw(Self.rectF(0, 0, 50, 50))   // left: rect
        b.u32(0x10000000); b.raw(Self.rectF(25, 25, 50, 50)) // right: rect
        try roundTrip(.region, b.bytes)
    }

    @Test func regionEmptyAndInfinite() throws {
        var b = LE(); b.u32(1); b.u32(1)
        b.u32(0x10000002)                          // Empty
        try roundTrip(.region, b.bytes)

        var c = LE(); c.u32(1); c.u32(1)
        c.u32(0x10000003)                          // Infinite
        try roundTrip(.region, c.bytes)
    }

    @Test func regionWithPathNode() throws {
        // A region whose single node is a path (§2.2.2.42): length-prefixed
        // EmfPlusPath. The nested path must re-encode byte-identically.
        var path = LE(); path.u32(2); path.u32(3); path.u32(0)
        path.raw(Self.pointF(0, 0)); path.raw(Self.pointF(10, 0)); path.raw(Self.pointF(10, 10))
        path.raw([0x00, 0x01, 0x01])
        var b = LE(); b.u32(1); b.u32(1)
        b.u32(0x10000001)                          // RegionNodeDataTypePath
        b.i32(Int32(path.count))                   // RegionNodePathLength
        b.raw(path.bytes)
        try roundTrip(.region, b.bytes)
    }
}
