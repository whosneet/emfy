import Foundation

/// Record-type name lookup for the [MS-WMF] `RecordType` enumeration
/// ([MS-WMF] §2.1.1.1).
///
/// A naming aid for tooling (e.g. `emfy-dump`), not a decode gate: the walker
/// accepts any `RecordFunction`, and per the log-and-skip rule an unknown
/// function is reported by number, never rejected. Only the values verified
/// against the spec's enumeration appear here; any other value is treated as
/// unknown. Names are returned with the `META_` prefix.
///
/// The 16-bit `RecordFunction` field's low-order byte MUST match the low-order
/// byte of one of these values ([MS-WMF] §2.3); the high-order byte encodes the
/// record's WORD count class. The full 16-bit value is looked up here.
public enum WMFRecordType {
    /// Verified name for `function`, or `nil` if the value is not a defined
    /// [MS-WMF] record type.
    public static func name(for function: UInt16) -> String? {
        guard let bare = names[function] else { return nil }
        return "META_" + bare
    }

    /// 16-bit RecordFunction value → bare enumeration name (no `META_` prefix),
    /// exactly as verified against [MS-WMF] §2.1.1.1 (v20240423).
    private static let names: [UInt16: String] = [
        0x0000: "EOF",
        0x001E: "SAVEDC",
        0x0035: "REALIZEPALETTE",
        0x0037: "SETPALENTRIES",
        0x00F7: "CREATEPALETTE",
        0x0102: "SETBKMODE",
        0x0103: "SETMAPMODE",
        0x0104: "SETROP2",
        0x0105: "SETRELABS",
        0x0106: "SETPOLYFILLMODE",
        0x0107: "SETSTRETCHBLTMODE",
        0x0108: "SETTEXTCHAREXTRA",
        0x0127: "RESTOREDC",
        0x0139: "RESIZEPALETTE",
        0x0142: "DIBCREATEPATTERNBRUSH",
        0x0149: "SETLAYOUT",
        0x012A: "INVERTREGION",
        0x012B: "PAINTREGION",
        0x012C: "SELECTCLIPREGION",
        0x012D: "SELECTOBJECT",
        0x012E: "SETTEXTALIGN",
        0x01F0: "DELETEOBJECT",
        0x01F9: "CREATEPATTERNBRUSH",
        0x0201: "SETBKCOLOR",
        0x0209: "SETTEXTCOLOR",
        0x020A: "SETTEXTJUSTIFICATION",
        0x020B: "SETWINDOWORG",
        0x020C: "SETWINDOWEXT",
        0x020D: "SETVIEWPORTORG",
        0x020E: "SETVIEWPORTEXT",
        0x020F: "OFFSETWINDOWORG",
        0x0211: "OFFSETVIEWPORTORG",
        0x0213: "LINETO",
        0x0214: "MOVETO",
        0x0220: "OFFSETCLIPRGN",
        0x0228: "FILLREGION",
        0x0231: "SETMAPPERFLAGS",
        0x0234: "SELECTPALETTE",
        0x02FA: "CREATEPENINDIRECT",
        0x02FB: "CREATEFONTINDIRECT",
        0x02FC: "CREATEBRUSHINDIRECT",
        0x0324: "POLYGON",
        0x0325: "POLYLINE",
        0x0410: "SCALEWINDOWEXT",
        0x0412: "SCALEVIEWPORTEXT",
        0x0415: "EXCLUDECLIPRECT",
        0x0416: "INTERSECTCLIPRECT",
        0x0418: "ELLIPSE",
        0x0419: "FLOODFILL",
        0x041B: "RECTANGLE",
        0x041F: "SETPIXEL",
        0x0429: "FRAMEREGION",
        0x0436: "ANIMATEPALETTE",
        0x0521: "TEXTOUT",
        0x0538: "POLYPOLYGON",
        0x0548: "EXTFLOODFILL",
        0x061C: "ROUNDRECT",
        0x061D: "PATBLT",
        0x0626: "ESCAPE",
        0x06FF: "CREATEREGION",
        0x0817: "ARC",
        0x081A: "PIE",
        0x0830: "CHORD",
        0x0922: "BITBLT",
        0x0940: "DIBBITBLT",
        0x0A32: "EXTTEXTOUT",
        0x0B23: "STRETCHBLT",
        0x0B41: "DIBSTRETCHBLT",
        0x0D33: "SETDIBTODEV",
        0x0F43: "STRETCHDIB",
    ]
}
