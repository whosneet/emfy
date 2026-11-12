import EMFParse
import Foundation

// MARK: - Spec-derived record purposes for "Explain what's missing" (A1c Part 2)
//
// A small static table that gives each record kind the diagnostics can report a
// plain, one-line purpose, so the on-device model can say what a SKIPPED record
// would have drawn (for example "a gradient fill instruction (EMR_GRADIENTFILL)
// was skipped, so smooth colour blends may appear flat") instead of a vague note.
//
// The NAME comes from EMFKit's verified enumerations (EMFRecordType /
// EMFPlusRecordType — [MS-EMF] §2.1.1 / [MS-EMFPLUS] §2.1.1.1). The one-line
// purposes below are derived from the record-structure sections cited in the
// comments; they describe what the record DOES, never the specific drawing's
// content. Unlisted types fall back to a generic purpose so the model still has
// something factual to explain.

enum DrawingRecordPurpose {
    /// A resolved name + one-line purpose for a reported record.
    struct Resolved: Equatable {
        var name: String
        var purpose: String
    }

    /// The name + purpose for an EMF record type id, or `nil` when the type id is
    /// not a defined [MS-EMF] record (the caller then reports it by number).
    static func emf(type: UInt32) -> Resolved? {
        guard let name = EMFRecordType.name(for: type) else { return nil }
        return Resolved(name: name, purpose: emfPurposes[name] ?? genericEMFPurpose)
    }

    /// The name + purpose for an EMF+ record type id. EMF+ names always resolve to
    /// at least a hex label ([MS-EMFPLUS] §2.1.1.1; `displayName`), so this never
    /// returns `nil`.
    static func emfPlus(type: UInt16) -> Resolved {
        let name = EMFPlusRecordType.displayName(for: type)
        return Resolved(name: name, purpose: emfPlusPurposes[name] ?? genericEMFPlusPurpose)
    }

    /// Fallback when a defined EMR name has no specific purpose line.
    static let genericEMFPurpose = "a record Emfy doesn't support yet"
    /// Fallback for an EMF+ record with no specific purpose line.
    static let genericEMFPlusPurpose = "an EMF+ graphics instruction Emfy doesn't support yet"

    // MARK: EMF record purposes ([MS-EMF] §2.3, keyed by the EMR_ name)
    //
    // Only records that are plausibly skipped (not the core geometry/text/bitmap
    // records the renderer already draws) carry a purpose; everything else uses the
    // generic line. One short sentence each, from the §2.3 record structure.
    private static let emfPurposes: [String: String] = [
        // §2.2 / §2.3.4 structural & metadata records — skipping these loses no visible
        // drawing (the renderer logs them as "unimplemented" because they draw nothing).
        "EMR_HEADER": "the metafile header, which describes the drawing but draws nothing itself; skipping it changes nothing you see",   // §2.3.4.2
        "EMR_EOF": "the end-of-metafile marker, which draws nothing; skipping it changes nothing you see",                               // §2.3.4.1
        "EMR_COMMENT": "embedded private or application data, not a visible drawing; skipping it changes nothing you see",               // §2.3.3.4
        // §2.3.5 drawing
        "EMR_GRADIENTFILL": "a gradient fill that blends colours smoothly across triangles or rectangles",   // §2.3.5.12
        "EMR_ANGLEARC": "an arc of a circle drawn from a start angle through a sweep angle",                  // §2.3.5.1
        "EMR_ARC": "an elliptical arc between two points",                                                    // §2.3.5.2
        "EMR_ARCTO": "an elliptical arc that also moves the current point",                                  // §2.3.5.3
        "EMR_CHORD": "a chord: an ellipse section closed by a straight line",                                // §2.3.5.4
        "EMR_PIE": "a pie slice of an ellipse",                                                              // §2.3.5.5
        "EMR_POLYDRAW": "a mixed run of lines and Bézier curves",                                            // §2.3.5.6
        "EMR_POLYDRAW16": "a mixed run of lines and Bézier curves (16-bit points)",                          // §2.3.5.7
        "EMR_EXTFLOODFILL": "a flood fill that spreads colour out from a point",                             // §2.3.5.8
        "EMR_SETPIXELV": "a single coloured pixel",                                                          // §2.3.5.36
        "EMR_SMALLTEXTOUT": "a short run of drawn text",                                                     // §2.3.5.37
        // §2.3.6 bitmap
        "EMR_MASKBLT": "a bitmap copy combined through a mask",                                              // §2.3.1.5
        "EMR_PLGBLT": "a bitmap copied into a parallelogram",                                                // §2.3.1.6
        "EMR_ALPHABLEND": "a bitmap blended with transparency",                                              // §2.3.1.1
        "EMR_TRANSPARENTBLT": "a bitmap copied with one colour treated as transparent",                     // §2.3.1.8
        // §2.3.4 clipping / regions
        "EMR_FILLRGN": "a region filled with a brush",                                                       // §2.3.8.2
        "EMR_FRAMERGN": "a region's border drawn with a brush",                                             // §2.3.8.3
        "EMR_INVERTRGN": "a region's colours inverted",                                                      // §2.3.8.4
        "EMR_PAINTRGN": "a region painted with the current brush",                                          // §2.3.8.5
        // §2.3.10 palette
        "EMR_CREATEPALETTE": "defines a colour palette for the drawing",                                     // §2.3.10.2
        "EMR_SELECTPALETTE": "selects a colour palette",                                                     // §2.3.10.6
        "EMR_SETPALETTEENTRIES": "sets entries in a colour palette",                                        // §2.3.10.7
        "EMR_RESIZEPALETTE": "resizes a colour palette",                                                     // §2.3.10.5
        "EMR_REALIZEPALETTE": "maps the logical palette onto the device",                                   // §2.3.10.4
        // §2.3.9 OpenGL / escapes / colour management
        "EMR_GLSRECORD": "an embedded OpenGL command",                                                       // §2.3.9.1
        "EMR_GLSBOUNDEDRECORD": "an embedded OpenGL command with a bounding box",                            // §2.3.9.2
        "EMR_PIXELFORMAT": "sets the pixel format for OpenGL output",                                        // §2.3.9.3
        "EMR_DRAWESCAPE": "a device-specific drawing escape",                                               // §2.3.6.1
        "EMR_EXTESCAPE": "a device-specific escape command",                                                // §2.3.6.2
        "EMR_NAMEDESCAPE": "a named device-specific escape command",                                        // §2.3.6.3
        "EMR_SETICMMODE": "turns image colour management on or off",                                        // §2.3.5.26
        "EMR_SETICMPROFILEA": "selects an ICC colour profile (ANSI name)",                                  // §2.3.5.27
        "EMR_SETICMPROFILEW": "selects an ICC colour profile",                                              // §2.3.5.28
        "EMR_CREATECOLORSPACE": "defines a colour space",                                                    // §2.3.7.2
        "EMR_CREATECOLORSPACEW": "defines a colour space",                                                   // §2.3.7.3
        "EMR_SETCOLORSPACE": "selects a colour space",                                                       // §2.3.7.5
        "EMR_DELETECOLORSPACE": "deletes a colour space",                                                    // §2.3.7.4
        "EMR_COLORCORRECTPALETTE": "colour-corrects palette entries",                                       // §2.3.7.1
        "EMR_COLORMATCHTOTARGETW": "sets colour matching to a target profile",                              // §2.3.5.5
        // §2.3.11 text/mapping state
        "EMR_SETLAYOUT": "sets left-to-right or right-to-left drawing layout",                              // §2.3.11.17
        "EMR_SETTEXTJUSTIFICATION": "adds extra spacing to justify text",                                   // §2.3.5.34
        "EMR_FORCEUFIMAPPING": "forces a universal font-id mapping",                                        // §2.3.5.9
        "EMR_SETLINKEDUFIS": "sets linked universal font ids",                                              // §2.3.5.29
        "EMR_SETMAPPERFLAGS": "controls how fonts are matched",                                             // §2.3.5.30
        "EMR_POLYTEXTOUTA": "several runs of drawn text (ANSI)",                                             // §2.3.5.32
        "EMR_POLYTEXTOUTW": "several runs of drawn text",                                                    // §2.3.5.33
    ]

    // MARK: EMF+ record purposes ([MS-EMFPLUS] §2.3, keyed by the EmfPlus name)
    private static let emfPlusPurposes: [String: String] = [
        "EmfPlusFillRects": "fills one or more rectangles",                          // §2.3.4.17
        "EmfPlusDrawRects": "outlines one or more rectangles",                       // §2.3.4.12
        "EmfPlusFillPolygon": "fills a polygon",                                     // §2.3.4.16
        "EmfPlusDrawLines": "draws a connected run of lines",                        // §2.3.4.9
        "EmfPlusFillEllipse": "fills an ellipse",                                    // §2.3.4.14
        "EmfPlusDrawEllipse": "outlines an ellipse",                                 // §2.3.4.7
        "EmfPlusFillPie": "fills a pie slice",                                       // §2.3.4.15
        "EmfPlusDrawPie": "outlines a pie slice",                                    // §2.3.4.11
        "EmfPlusDrawArc": "draws an elliptical arc",                                 // §2.3.4.5
        "EmfPlusFillRegion": "fills a region",                                       // §2.3.4.18
        "EmfPlusFillPath": "fills the inside of a path",                             // §2.3.4.14
        "EmfPlusDrawPath": "strokes the outline of a path",                          // §2.3.4.10
        "EmfPlusFillClosedCurve": "fills a closed cardinal-spline curve",            // §2.3.4.13
        "EmfPlusDrawClosedCurve": "outlines a closed cardinal-spline curve",        // §2.3.4.6
        "EmfPlusDrawCurve": "draws a cardinal-spline curve",                         // §2.3.4.8
        "EmfPlusDrawBeziers": "draws Bézier curves",                                 // §2.3.4.4
        "EmfPlusDrawImage": "draws an image",                                        // §2.3.4.2
        "EmfPlusDrawImagePoints": "draws an image into a parallelogram",             // §2.3.4.3
        "EmfPlusDrawString": "draws a run of text",                                  // §2.3.4.13
        "EmfPlusDrawDriverString": "draws text positioned glyph by glyph",           // §2.3.4.6
        "EmfPlusClear": "clears the drawing to a colour",                            // §2.3.4.1
    ]
}
