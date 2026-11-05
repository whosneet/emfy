import EMFParse
import EMFRender
import Foundation

/// Plain-language diagnostics shared by the Mac and iOS viewers (C2, owner
/// decision). Each note carries a short plain-English `summary`, shown first, and
/// the existing precise `technicalDetail`, shown under a "Technical details"
/// disclosure. The technical wording is unchanged from what both platforms used
/// before, so nothing regresses; the summaries are new. Australian English,
/// short, plain words.

/// One diagnostic line: the plain-language summary users read, plus the technical
/// detail kept for those who want it.
struct DiagnosticNote: Hashable, Identifiable, Sendable {
    let summary: String
    let technicalDetail: String
    var id: String { summary + "\u{1}" + technicalDetail }
}

// MARK: - Assembled notes

/// Everything a viewer needs to decide the partial-support banner and to fill the
/// "What Emfy couldn't show" section. Built off the main actor from a loaded
/// document and carried back as a value.
struct ViewerDiagnostics: Sendable, Equatable {
    var kind: MetafileRenderer.Prepared.Kind
    var embeddedEMF: MetafileRenderer.Prepared.EmbeddedEMF
    var renderLog: [EMFRenderLog.Entry]
    var parserDiagnostics: [EMFDiagnostic]
    var frontDoorDiagnostics: [MetafileDiagnostic]
    var wasDecompressed: Bool

    /// True when the render log shows EMF+ content that was NOT rendered.
    private var hasUnsupportedEMFPlusContent: Bool {
        renderLog.contains { entry in
            switch entry {
            case .emfPlusUnsupportedRecord, .emfPlusStreamIssue, .emfPlusRecordUndecodable, .emfPlusObjectIssue:
                return true
            default:
                return false
            }
        }
    }

    /// The partial-support headline, or `nil` when nothing needs flagging. The
    /// banner opens the inspector/details for the full list, so it carries no
    /// "see details" suffix. Advisory notes that aren't missing content — header
    /// count/byte mismatches and stock-font fallbacks — never trigger it.
    var partialSupportMessage: String? {
        switch kind {
        case .emf:
            return hasUnsupportedEMFPlusContent
                ? "Some EMF+ content in this file isn't supported or couldn't be read."
                : nil
        case .wmfRecords:
            return missingContentRenderLog.isEmpty
                ? nil
                : "Some content in this file isn't fully supported."
        }
    }

    /// Render-log notes that represent genuinely missing or skipped content.
    /// Excludes stock-font fallbacks (the text is still drawn) — the one
    /// render-log note that isn't missing content (I2 filtering, unchanged).
    private var missingContentRenderLog: [EMFRenderLog.Entry] {
        renderLog.filter { entry in
            if case .stockFontUsed = entry { return false }
            return true
        }
    }

    /// Parser diagnostics that represent genuinely missing content. Excludes the
    /// advisory header record/byte-count mismatches (the walker's own count is
    /// authoritative; nothing is lost) — I2 filtering, unchanged.
    private var missingContentParserDiagnostics: [EMFDiagnostic] {
        parserDiagnostics.filter { entry in
            switch entry {
            case .recordCountMismatch, .byteCountMismatch: return false
            default: return true
            }
        }
    }

    /// Front-door notes (gzip unwrap, signature sniff, a rejected embedded EMF).
    var fileNotes: [DiagnosticNote] {
        var notes: [DiagnosticNote] = []
        if wasDecompressed {
            notes.append(DiagnosticNote(
                summary: "This file was compressed (.emz / .wmz) and was expanded before viewing.",
                technicalDetail: "This file was gzip-compressed (.emz / .wmz) and was expanded before viewing."
            ))
        }
        notes.append(contentsOf: frontDoorDiagnostics.map(\.note))
        if embeddedEMF == .rejected {
            notes.append(DiagnosticNote(
                summary: "This file's built-in high-quality copy couldn't be read, so Emfy drew from the Windows Metafile records instead.",
                technicalDetail: "This file embedded an Enhanced Metafile that couldn't be read, so Emfy drew from the Windows Metafile records instead."
            ))
        }
        return notes
    }

    /// The flattened "What Emfy couldn't show" list — front-door notes, then
    /// parser diagnostics, then render notes. Header count/byte mismatches and
    /// stock-font fallbacks are filtered out (not missing content). Empty when
    /// there is nothing to show (section omitted). Used by the iOS inspector.
    var couldNotShowNotes: [DiagnosticNote] {
        fileNotes
            + missingContentParserDiagnostics.map(\.note)
            + missingContentRenderLog.map(\.note)
    }

    /// Every parser diagnostic, unfiltered, for the Mac's Render Details.
    var allParserNotes: [DiagnosticNote] { parserDiagnostics.map(\.note) }

    /// Every render-log note, unfiltered, for the Mac's Render Details.
    var allRenderNotes: [DiagnosticNote] { renderLog.map(\.note) }
}

/// Appends the occurrence count the way the technical lines always have.
private func occ(_ count: Int) -> String {
    "(\(count) occurrence\(count == 1 ? "" : "s"))"
}

// MARK: - Note providers

extension MetafileDiagnostic {
    var note: DiagnosticNote {
        switch self {
        case .sniff(.placeableChecksumMismatch):
            return DiagnosticNote(
                summary: "The Windows Metafile header checksum didn't match; it's advisory, so Emfy opened the file anyway.",
                technicalDetail: "The placeable Windows Metafile header checksum didn't match; it's advisory, so the file was opened anyway."
            )
        case .gzip(.isizeMismatch):
            return DiagnosticNote(
                summary: "The compressed file's recorded size didn't match; Emfy used the expanded data.",
                technicalDetail: "The compressed wrapper's recorded size didn't match the expanded data; the expanded data was used."
            )
        case .gzip(.trailingBytesAfterMember(let count)):
            return DiagnosticNote(
                summary: "The compressed file had extra bytes after its data; Emfy ignored them.",
                technicalDetail: "The compressed file had \(count) extra byte\(count == 1 ? "" : "s") after its first member; they were ignored."
            )
        }
    }
}

extension EMFDiagnostic {
    var note: DiagnosticNote {
        switch self {
        case .sizeTooSmall(let offset, let size):
            return DiagnosticNote(
                summary: "Emfy stopped reading at a record with an invalid size, keeping everything before it.",
                technicalDetail: "Record at byte \(offset) has an invalid size (\(size)); parsing stopped there."
            )
        case .sizeNotAligned(let offset, let size):
            return DiagnosticNote(
                summary: "Emfy stopped reading at a misaligned record, keeping everything before it.",
                technicalDetail: "Record at byte \(offset) has a size of \(size), which is not four-byte aligned; parsing stopped there."
            )
        case .sizeExceedsRemaining(let offset, let size, let remaining):
            return DiagnosticNote(
                summary: "Emfy stopped reading at a record that claimed more data than the file had, keeping everything before it.",
                technicalDetail: "Record at byte \(offset) claims \(size) bytes, but only \(remaining) remain; parsing stopped there."
            )
        case .truncatedRecordHeader(let offset, let remaining):
            return DiagnosticNote(
                summary: "The file ended in the middle of a record; Emfy kept everything before it.",
                technicalDetail: "Only \(remaining) bytes remain at byte \(offset), which is too short for a record header; parsing stopped there."
            )
        case .missingEOF:
            return DiagnosticNote(
                summary: "The file had no proper end marker.",
                technicalDetail: "The file ended without an EMR_EOF record."
            )
        case .trailingBytesAfterEOF(let count):
            return DiagnosticNote(
                summary: "There were extra bytes after the file's end marker; Emfy ignored them.",
                technicalDetail: "The file contains \(count) trailing bytes after its EMR_EOF record."
            )
        case .recordCountMismatch(let headerSays, let walked):
            return DiagnosticNote(
                summary: "The file's record count didn't match what Emfy found; Emfy used its own count.",
                technicalDetail: "The header claims \(headerSays) records, but Emfy found \(walked); the walked count was used."
            )
        case .byteCountMismatch(let headerSays, let walked):
            return DiagnosticNote(
                summary: "The file's byte count didn't match what Emfy read; Emfy used its own count.",
                technicalDetail: "The header claims \(headerSays) bytes, but Emfy walked \(walked); the walked count was used."
            )
        case .recordCountCapped(let limit):
            return DiagnosticNote(
                summary: "The file had an unusually large number of records; Emfy stopped at its safety limit.",
                technicalDetail: "The \(limit)-record safety limit was reached; later records were skipped."
            )
        }
    }
}

extension EMFRenderLog.Entry {
    var note: DiagnosticNote {
        switch self {
        case .unimplementedRecord(let type, let count):
            return DiagnosticNote(
                summary: "\(count) drawing instruction\(count == 1 ? "" : "s") of a kind Emfy doesn't support yet \(count == 1 ? "was" : "were") skipped.",
                technicalDetail: "Skipped unsupported record type \(type) \(occ(count))."
            )
        case .malformedRecord(let type):
            return DiagnosticNote(
                summary: "A damaged drawing instruction was skipped.",
                technicalDetail: "Skipped malformed record type \(type)."
            )
        case .unsupportedROP2(let rawMode, let count):
            return DiagnosticNote(
                summary: "\(count) drawing operation\(count == 1 ? "" : "s") used normal drawing instead of an unsupported blend mode.",
                technicalDetail: "Used normal copy drawing for unsupported ROP2 mode \(rawMode) \(occ(count))."
            )
        case .unsupportedBrushStyle(let rawStyle):
            return DiagnosticNote(
                summary: "An unsupported fill style was drawn as a solid colour.",
                technicalDetail: "Used a solid fallback for unsupported brush style \(rawStyle)."
            )
        case .unsupportedPenStyle(let rawStyle):
            return DiagnosticNote(
                summary: "An unsupported line style was drawn as a solid line.",
                technicalDetail: "Used a solid fallback for unsupported pen style \(rawStyle)."
            )
        case .zeroExtentMapping:
            return DiagnosticNote(
                summary: "The file set a zero-sized drawing area, so Emfy kept the previous one.",
                technicalDetail: "Kept the current mapping because the file contains a zero-sized extent."
            )
        case .unsupportedClipMode(let record, let rawMode):
            return DiagnosticNote(
                summary: "An unsupported clipping option was skipped.",
                technicalDetail: "Skipped unsupported clipping mode \(rawMode) in record type \(record)."
            )
        case .noCurrentPath(let record):
            return DiagnosticNote(
                summary: "A path operation was skipped because no path had been started.",
                technicalDetail: "Skipped record type \(record) because it had no current path."
            )
        case .nestedBeginPath:
            return DiagnosticNote(
                summary: "A new path was started before the previous one finished; the unfinished path was dropped.",
                technicalDetail: "Started a new path after a nested path begin; the unfinished path was discarded."
            )
        case .unknownEnumValue(let record, let rawValue):
            return DiagnosticNote(
                summary: "An unrecognised option in the file was ignored.",
                technicalDetail: "Ignored unknown value \(rawValue) in record type \(record)."
            )
        case .malformedBezier(let pointCount):
            return DiagnosticNote(
                summary: "A curve with a bad point count was partly drawn.",
                technicalDetail: "Rendered the valid part of a Bezier record with an invalid \(pointCount)-point count."
            )
        case .invalidObjectIndex(let index):
            return DiagnosticNote(
                summary: "A reference to an unavailable drawing object was ignored.",
                technicalDetail: "Ignored unavailable graphics object index \(index)."
            )
        case .objectTableFull(let index):
            return DiagnosticNote(
                summary: "A drawing object was ignored because Emfy's object table was full.",
                technicalDetail: "Ignored graphics object index \(index) because the object table is full."
            )
        case .unsupportedStockObject(let rawValue):
            return DiagnosticNote(
                summary: "An unsupported built-in drawing object was ignored.",
                technicalDetail: "Ignored unsupported stock graphics object \(rawValue)."
            )
        case .restoreDCUnbalanced(let savedDC):
            return DiagnosticNote(
                summary: "A request to restore a drawing state had no matching saved state.",
                technicalDetail: "Could not restore graphics state \(savedDC) because no matching saved state exists."
            )
        case .saveDCStackOverflow:
            return DiagnosticNote(
                summary: "A drawing-state save was skipped because the safety limit was reached.",
                technicalDetail: "Skipped a graphics-state save because the safety limit was reached."
            )
        case .unsupportedWorldTransformMode(let rawMode):
            return DiagnosticNote(
                summary: "An unsupported transform option was ignored.",
                technicalDetail: "Ignored unsupported world-transform mode \(rawMode)."
            )
        case .canvasClamped(let requestedWidth, let requestedHeight, let renderedWidth, let renderedHeight):
            return DiagnosticNote(
                summary: "The picture was rendered at a smaller size to stay within Emfy's safety limit.",
                technicalDetail: "Rendered at \(renderedWidth) × \(renderedHeight) instead of \(requestedWidth) × \(requestedHeight) to stay within the image safety limit."
            )
        case .fontSubstituted(let requested, let used, let count):
            // A blank face name must read naturally, not "unavailable font  (…)".
            let requestedPhrase = requested.isEmpty ? "an unnamed unavailable font" : "unavailable font \(requested)"
            return DiagnosticNote(
                summary: "A font the file asked for wasn't available, so Emfy used \(used) instead \(occ(count)).",
                technicalDetail: "Used \(used) instead of \(requestedPhrase) \(occ(count))."
            )
        case .stockFontUsed(let rawValue, let count):
            return DiagnosticNote(
                summary: "A built-in font was shown with a system substitute \(occ(count)).",
                technicalDetail: "Used a system fallback for stock font \(rawValue) \(occ(count))."
            )
        case .glyphIndexTextSkipped(let count):
            return DiagnosticNote(
                summary: "\(count) run\(count == 1 ? "" : "s") of text couldn't be matched to a font and \(count == 1 ? "was" : "were") skipped.",
                technicalDetail: "Skipped \(count) glyph-index text run\(count == 1 ? "" : "s") that could not be mapped to a macOS font."
            )
        case .unsupportedDIB(let reason, let count):
            return DiagnosticNote(
                summary: "\(count) embedded image\(count == 1 ? "" : "s") in an unsupported format \(count == 1 ? "was" : "were") skipped.",
                technicalDetail: "Skipped unsupported embedded bitmap\(reason.map { ": \($0.userMessage)" } ?? "") \(occ(count))."
            )
        case .unsupportedRasterOp(let rasterOperation, let count):
            return DiagnosticNote(
                summary: "\(count) image blend operation\(count == 1 ? "" : "s") used a best-effort fallback.",
                technicalDetail: "Used a best-effort fallback for raster operation \(rasterOperation) \(occ(count))."
            )
        case .xformSrcIgnored(let count):
            return DiagnosticNote(
                summary: "A source-image transform was ignored \(occ(count)).",
                technicalDetail: "Ignored a source bitmap transform \(occ(count))."
            )
        case .dibDownsampled(let count, let worstNativePixels, let worstDecodedPixels):
            return DiagnosticNote(
                summary: "\(count) large image\(count == 1 ? "" : "s") \(count == 1 ? "was" : "were") decoded at a lower resolution to fit; no visible detail was lost.",
                technicalDetail: "Decoded an embedded bitmap below its full resolution to fit the destination; no visible detail was lost (largest: \(worstNativePixels) → \(worstDecodedPixels) pixels, \(occ(count)))."
            )
        case .emfPlusUnsupportedRecord(let type, let count):
            return DiagnosticNote(
                summary: "\(count) EMF+ drawing instruction\(count == 1 ? "" : "s") Emfy doesn't support \(count == 1 ? "was" : "were") skipped.",
                technicalDetail: "Skipped unsupported EMF+ record type \(String(format: "0x%04X", type)) \(occ(count))."
            )
        case .emfPlusApproximated(let feature, let count):
            return DiagnosticNote(
                summary: "\(count) EMF+ effect\(count == 1 ? "" : "s") \(count == 1 ? "was" : "were") drawn in a simplified way (\(feature.userDescription)).",
                technicalDetail: "Approximated EMF+ \(feature.userDescription) \(occ(count))."
            )
        case .emfPlusStreamIssue(let kind, let count):
            return DiagnosticNote(
                summary: "Part of the EMF+ data couldn't be fully read \(occ(count)).",
                technicalDetail: "Couldn't fully read the EMF+ data — \(kind.userDescription) \(occ(count))."
            )
        case .emfPlusRecordUndecodable(let type, let count):
            return DiagnosticNote(
                summary: "\(count) unreadable EMF+ drawing instruction\(count == 1 ? "" : "s") \(count == 1 ? "was" : "were") skipped.",
                technicalDetail: "Skipped an unreadable EMF+ drawing record of type \(String(format: "0x%04X", type)) \(occ(count))."
            )
        case .emfPlusObjectIssue(let kind, let count):
            return DiagnosticNote(
                summary: "An EMF+ drawing object problem was handled \(occ(count)).",
                technicalDetail: "\(kind.userDescription) \(occ(count))."
            )
        case .emfPlusSaveStackCapped(let count):
            return DiagnosticNote(
                summary: "Some deeply nested EMF+ states were dropped at the safety limit \(occ(count)).",
                technicalDetail: "Reached the EMF+ save/container nesting limit; deeper saves were dropped \(occ(count))."
            )
        }
    }
}

// MARK: - Technical-detail building blocks (used inside the lines above)

extension EMFPlusApproximation {
    var userDescription: String {
        switch self {
        case .hatchBrush: return "hatch fill as a solid color"
        case .pathGradientBrush: return "path-gradient fill as its center color"
        case .textureBrush: return "texture fill (skipped)"
        case .penNonSolidBrush: return "gradient/pattern pen stroke as a solid color"
        case .penCap: return "line cap as a round cap"
        case .penMiterLimit: return "an invalid pen miter limit as the default"
        case .clipCombineMode: return "clip combination as an intersection"
        case .regionCombine: return "region combination as a union"
        case .offsetClip: return "clip offset (left unchanged)"
        case .pageUnit: return "page unit as pixels"
        case .compositingMode: return "compositing as source-over"
        case .container: return "graphics container as a save/restore"
        case .linearGradientWrapMode: return "gradient tiling as a clamped fill"
        case .gradientGamma: return "gamma-corrected gradient as a linear blend"
        case .curveSegmentRange: return "partial curve range (drew the whole curve)"
        case .imageBitmapPixelFormat(let format): return "image pixel format \(String(format: "0x%08X", format)) (unsupported; image skipped)"
        case .imageInvalid: return "an invalid or oversized bitmap image (skipped)"
        case .imageCompressed: return "a compressed image that could not be decoded (skipped)"
        case .imageMetafile: return "a metafile image (nested playback unsupported; skipped)"
        case .imageSrcUnit: return "a non-pixel image source unit as pixels"
        case .imageAttributes: return "image attributes wrap mode (not applied)"
        case .imageDownsampled: return "a large bitmap image decoded at a reduced resolution"
        case .imageOversized: return "a compressed image too large for this view (skipped)"
        case .imageEffect: return "an image effect (drawn without it)"
        case .stringFormatSimplified: return "advanced text formatting as a single left-to-right line"
        case .pathDashSegment: return "per-segment path dashing as a solid path"
        }
    }
}

extension EMFPlusStreamIssueKind {
    var userDescription: String {
        switch self {
        case .commentDataSizeClamped: return "an EMF+ comment's declared size ran past its record"
        case .recordSizeTooSmall: return "an EMF+ record size below the header minimum"
        case .recordSizeNotAligned: return "an unaligned EMF+ record size"
        case .recordDataSizeExceedsSize: return "an EMF+ record's data size exceeded its record size"
        case .recordDataTruncated: return "a truncated EMF+ record running past the stream"
        case .recordSizeExcessPadding: return "an over-long EMF+ record size that hid the records after it"
        case .trailingBytes: return "leftover bytes after the last EMF+ record"
        case .headerRecordMissing: return "a missing EMF+ header record"
        case .headerUnexpectedSize: return "an unexpected EMF+ header size"
        case .headerUnexpectedDataSize: return "an unexpected EMF+ header data size"
        case .recordCountCapped: return "too many EMF+ records (the safety cap was reached)"
        }
    }
}

extension EMFPlusObjectIssueKind {
    var userDescription: String {
        switch self {
        case .missingReference: return "A drawing record referenced an EMF+ object that wasn't available"
        case .invalidID: return "An EMF+ object used an out-of-range table slot and was dropped"
        case .undecodable: return "An EMF+ object definition couldn't be decoded"
        }
    }
}

extension DIBUnsupportedReason {
    var userMessage: String {
        switch self {
        case .compression(let compression): return "compression \(compression.userMessage)"
        case .bitCount(let bitCount): return "\(bitCount)-bit color depth"
        case .paletteUsage(let paletteUsage): return "palette usage \(paletteUsage)"
        }
    }
}

extension BitmapCompression {
    var userMessage: String {
        switch self {
        case .rgb: return "BI_RGB"
        case .rle8: return "RLE8"
        case .rle4: return "RLE4"
        case .bitfields: return "bitfields"
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .other(let rawValue): return "unknown format \(rawValue)"
        }
    }
}
