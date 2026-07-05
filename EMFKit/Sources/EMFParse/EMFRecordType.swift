import Foundation

/// Record-type name lookup for the [MS-EMF] `RecordType` enumeration
/// ([MS-EMF] §2.1.1).
///
/// This is a naming aid for tooling (e.g. `emfy-dump`), not a decode gate:
/// the walker accepts any `iType` and, per the log-and-skip rule, an unknown
/// type is reported by number, never rejected. Only the values verified
/// against the spec's enumeration appear here; 69, 107, and 117 are not
/// defined by [MS-EMF] and are treated as unknown, as is any value outside
/// this table. Names are returned with the `EMR_` prefix.
public enum EMFRecordType {
    /// Verified name for `type`, or `nil` if the value is not a defined
    /// [MS-EMF] record type.
    public static func name(for type: UInt32) -> String? {
        guard let bare = names[type] else { return nil }
        return "EMR_" + bare
    }

    /// Decimal value → bare enumeration name (no `EMR_` prefix), exactly as
    /// verified against [MS-EMF] §2.1.1 (fetched 2026-07-05).
    private static let names: [UInt32: String] = [
        1: "HEADER", 2: "POLYBEZIER", 3: "POLYGON", 4: "POLYLINE",
        5: "POLYBEZIERTO", 6: "POLYLINETO", 7: "POLYPOLYLINE",
        8: "POLYPOLYGON", 9: "SETWINDOWEXTEX", 10: "SETWINDOWORGEX",
        11: "SETVIEWPORTEXTEX", 12: "SETVIEWPORTORGEX", 13: "SETBRUSHORGEX",
        14: "EOF", 15: "SETPIXELV", 16: "SETMAPPERFLAGS", 17: "SETMAPMODE",
        18: "SETBKMODE", 19: "SETPOLYFILLMODE", 20: "SETROP2",
        21: "SETSTRETCHBLTMODE", 22: "SETTEXTALIGN", 23: "SETCOLORADJUSTMENT",
        24: "SETTEXTCOLOR", 25: "SETBKCOLOR", 26: "OFFSETCLIPRGN",
        27: "MOVETOEX", 28: "SETMETARGN", 29: "EXCLUDECLIPRECT",
        30: "INTERSECTCLIPRECT", 31: "SCALEVIEWPORTEXTEX",
        32: "SCALEWINDOWEXTEX", 33: "SAVEDC", 34: "RESTOREDC",
        35: "SETWORLDTRANSFORM", 36: "MODIFYWORLDTRANSFORM", 37: "SELECTOBJECT",
        38: "CREATEPEN", 39: "CREATEBRUSHINDIRECT", 40: "DELETEOBJECT",
        41: "ANGLEARC", 42: "ELLIPSE", 43: "RECTANGLE", 44: "ROUNDRECT",
        45: "ARC", 46: "CHORD", 47: "PIE", 48: "SELECTPALETTE",
        49: "CREATEPALETTE", 50: "SETPALETTEENTRIES", 51: "RESIZEPALETTE",
        52: "REALIZEPALETTE", 53: "EXTFLOODFILL", 54: "LINETO", 55: "ARCTO",
        56: "POLYDRAW", 57: "SETARCDIRECTION", 58: "SETMITERLIMIT",
        59: "BEGINPATH", 60: "ENDPATH", 61: "CLOSEFIGURE", 62: "FILLPATH",
        63: "STROKEANDFILLPATH", 64: "STROKEPATH", 65: "FLATTENPATH",
        66: "WIDENPATH", 67: "SELECTCLIPPATH", 68: "ABORTPATH", 70: "COMMENT",
        71: "FILLRGN", 72: "FRAMERGN", 73: "INVERTRGN", 74: "PAINTRGN",
        75: "EXTSELECTCLIPRGN", 76: "BITBLT", 77: "STRETCHBLT", 78: "MASKBLT",
        79: "PLGBLT", 80: "SETDIBITSTODEVICE", 81: "STRETCHDIBITS",
        82: "EXTCREATEFONTINDIRECTW", 83: "EXTTEXTOUTA", 84: "EXTTEXTOUTW",
        85: "POLYBEZIER16", 86: "POLYGON16", 87: "POLYLINE16",
        88: "POLYBEZIERTO16", 89: "POLYLINETO16", 90: "POLYPOLYLINE16",
        91: "POLYPOLYGON16", 92: "POLYDRAW16", 93: "CREATEMONOBRUSH",
        94: "CREATEDIBPATTERNBRUSHPT", 95: "EXTCREATEPEN", 96: "POLYTEXTOUTA",
        97: "POLYTEXTOUTW", 98: "SETICMMODE", 99: "CREATECOLORSPACE",
        100: "SETCOLORSPACE", 101: "DELETECOLORSPACE", 102: "GLSRECORD",
        103: "GLSBOUNDEDRECORD", 104: "PIXELFORMAT", 105: "DRAWESCAPE",
        106: "EXTESCAPE", 108: "SMALLTEXTOUT", 109: "FORCEUFIMAPPING",
        110: "NAMEDESCAPE", 111: "COLORCORRECTPALETTE", 112: "SETICMPROFILEA",
        113: "SETICMPROFILEW", 114: "ALPHABLEND", 115: "SETLAYOUT",
        116: "TRANSPARENTBLT", 118: "GRADIENTFILL", 119: "SETLINKEDUFIS",
        120: "SETTEXTJUSTIFICATION", 121: "COLORMATCHTOTARGETW",
        122: "CREATECOLORSPACEW",
    ]
}
