import Foundation

/// Record-type name lookup and drawing classification for the [MS-EMFPLUS]
/// `RecordType` enumeration ([MS-EMFPLUS] §2.1.1.1).
///
/// Mirrors `EMFRecordType`: a naming aid for tooling (e.g. `emfy-dump`), not a
/// decode gate. The stream walker (`EMFFile.emfPlusStream()`) accepts any
/// 16-bit type and, per the log-and-skip rule, reports an unknown value by its
/// hex representation rather than rejecting it. Only the values verified against
/// the spec enumeration — the contiguous range 0x4001 (EmfPlusHeader) …
/// 0x403A (EmfPlusSetTSClip) — appear here. Names are returned with the
/// `EmfPlus` prefix, exactly as the spec spells them.
public enum EMFPlusRecordType {
    /// Verified name for `type` (e.g. `"EmfPlusHeader"`), or `nil` if the value
    /// is not a defined [MS-EMFPLUS] §2.1.1.1 record type.
    public static func name(for type: UInt16) -> String? {
        guard let bare = names[type] else { return nil }
        return "EmfPlus" + bare
    }

    /// A label that always resolves: the verified name, or the raw value as
    /// four-digit hex (`"0x4099"`) for an unknown type. This is the form
    /// tooling prints for every record ([MS-EMFPLUS] §2.1.1.1; log-and-skip).
    public static func displayName(for type: UInt16) -> String {
        name(for: type) ?? String(format: "0x%04X", type)
    }

    /// True when `type` is an EMF+ *drawing* record — one that specifies
    /// graphics output per the spec's formal categorisation, [MS-EMFPLUS]
    /// §2.3.4 "Drawing Record Types" (see also the §2.3 category table:
    /// "Drawing record types … Specify graphics output"). That group is the
    /// contiguous block 0x4009…0x401C (EmfPlusClear … EmfPlusDrawString) plus
    /// 0x4036 EmfPlusDrawDriverString — exactly the twenty-one records defined
    /// in §2.3.4.1–2.3.4.21.
    ///
    /// DIVERGENCE FROM `EMFPlusPresence` (deliberate; v1 left unchanged):
    /// `EMFPlusPresence.isEMFPlusDrawingRecord` additionally treats 0x4037
    /// EmfPlusStrokeFillPath as drawing. 0x4037 is enumerated in §2.1.1.1 — and
    /// its description there ("closes any open figures in a path, strokes the
    /// outline of the path … and fills its interior") is a drawing operation —
    /// but it is NOT a member of the formal §2.3.4 group and has no §2.3
    /// record-structure section at all (it is enumerated-but-unspecified). This
    /// classifier follows the formal §2.3.4 grouping and excludes 0x4037; v1's
    /// broader, semantics-based inclusion is intentionally not mirrored here,
    /// and `EMFPlusPresence` is not modified.
    public static func isDrawing(_ type: UInt16) -> Bool {
        (0x4009 ... 0x401C).contains(type) || type == 0x4036
    }

    /// Value → bare enumeration name (no `EmfPlus` prefix), verified against
    /// [MS-EMFPLUS] §2.1.1.1 (docs/MS-EMFPLUS.pdf, v20240423). 0x4036 uses the
    /// §2.3.4.6 spelling "DrawDriverString"; the §2.1.1.1 enumerant spells it
    /// "DrawDriverstring" (lowercase s) — a documented spec inconsistency.
    private static let names: [UInt16: String] = [
        0x4001: "Header", 0x4002: "EndOfFile", 0x4003: "Comment",
        0x4004: "GetDC", 0x4005: "MultiFormatStart",
        0x4006: "MultiFormatSection", 0x4007: "MultiFormatEnd",
        0x4008: "Object", 0x4009: "Clear", 0x400A: "FillRects",
        0x400B: "DrawRects", 0x400C: "FillPolygon", 0x400D: "DrawLines",
        0x400E: "FillEllipse", 0x400F: "DrawEllipse", 0x4010: "FillPie",
        0x4011: "DrawPie", 0x4012: "DrawArc", 0x4013: "FillRegion",
        0x4014: "FillPath", 0x4015: "DrawPath", 0x4016: "FillClosedCurve",
        0x4017: "DrawClosedCurve", 0x4018: "DrawCurve", 0x4019: "DrawBeziers",
        0x401A: "DrawImage", 0x401B: "DrawImagePoints", 0x401C: "DrawString",
        0x401D: "SetRenderingOrigin", 0x401E: "SetAntiAliasMode",
        0x401F: "SetTextRenderingHint", 0x4020: "SetTextContrast",
        0x4021: "SetInterpolationMode", 0x4022: "SetPixelOffsetMode",
        0x4023: "SetCompositingMode", 0x4024: "SetCompositingQuality",
        0x4025: "Save", 0x4026: "Restore", 0x4027: "BeginContainer",
        0x4028: "BeginContainerNoParams", 0x4029: "EndContainer",
        0x402A: "SetWorldTransform", 0x402B: "ResetWorldTransform",
        0x402C: "MultiplyWorldTransform", 0x402D: "TranslateWorldTransform",
        0x402E: "ScaleWorldTransform", 0x402F: "RotateWorldTransform",
        0x4030: "SetPageTransform", 0x4031: "ResetClip", 0x4032: "SetClipRect",
        0x4033: "SetClipPath", 0x4034: "SetClipRegion", 0x4035: "OffsetClip",
        0x4036: "DrawDriverString", 0x4037: "StrokeFillPath",
        0x4038: "SerializableObject", 0x4039: "SetTSGraphics",
        0x403A: "SetTSClip",
    ]
}
