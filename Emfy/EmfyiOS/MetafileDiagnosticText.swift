import EMFParse
import EMFRender
import Foundation

/// Plain-English diagnostics text for the iOS viewer. The `userMessage` strings
/// are copied verbatim from the Mac app's `EMFDocumentView.swift` so the same
/// diagnostic reads identically on both platforms (the brief: reuse the Mac
/// wording, don't invent new phrasing). The Mac keeps its own `private` copies;
/// those extensions can't be shared without touching the Mac target, so the
/// strings are duplicated here rather than extracted — see the builder report.

// MARK: - Assembled notes

/// Everything the iOS viewer needs to decide the partial-support banner and to
/// fill the inspector's "What Emfy couldn't show" section. Built off the main
/// actor from a loaded document and carried back as a value.
struct ViewerDiagnostics: Sendable, Equatable {
    var kind: MetafileRenderer.Prepared.Kind
    var embeddedEMF: MetafileRenderer.Prepared.EmbeddedEMF
    var renderLog: [EMFRenderLog.Entry]
    var parserDiagnostics: [EMFDiagnostic]
    var frontDoorDiagnostics: [MetafileDiagnostic]
    var wasDecompressed: Bool

    /// True when the render log shows EMF+ content that was NOT rendered — the
    /// same signal the Mac uses (audit M7).
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

    /// The partial-support headline, or `nil` when nothing needs flagging. Same
    /// condition as the Mac notice; the iOS banner drops the Mac's trailing
    /// "— see Render Details." because a Details button opens the inspector.
    /// Advisory notes that aren't missing content — header count/byte mismatches
    /// and stock-font fallbacks — never trigger it (they are filtered out).
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
    /// Excludes stock-font fallbacks (a stock font got a system substitute, the
    /// text is still drawn) — the one render-log note the review flags as "not
    /// missing content".
    private var missingContentRenderLog: [EMFRenderLog.Entry] {
        renderLog.filter { entry in
            if case .stockFontUsed = entry { return false }
            return true
        }
    }

    /// Parser diagnostics that represent genuinely missing content. Excludes the
    /// advisory header record/byte-count mismatches (the walker's own count is
    /// authoritative; nothing is lost).
    private var missingContentParserDiagnostics: [EMFDiagnostic] {
        parserDiagnostics.filter { entry in
            switch entry {
            case .recordCountMismatch, .byteCountMismatch: return false
            default: return true
            }
        }
    }

    /// Front-door notes (gzip unwrap, signature sniff, a rejected embedded EMF),
    /// worded exactly as the Mac's `frontDoorNotes`.
    private var frontDoorNotes: [String] {
        var notes: [String] = []
        if wasDecompressed {
            notes.append("This file was gzip-compressed (.emz / .wmz) and was expanded before viewing.")
        }
        notes.append(contentsOf: frontDoorDiagnostics.map(\.userMessage))
        if embeddedEMF == .rejected {
            notes.append("This file embedded an Enhanced Metafile that couldn't be read, so Emfy drew from the Windows Metafile records instead.")
        }
        return notes
    }

    /// The flattened "What Emfy couldn't show" list — front-door notes, then
    /// parser diagnostics, then render notes — using the Mac wording. Header
    /// count/byte mismatches and stock-font fallbacks are filtered out (not
    /// missing content). Empty when there is nothing to show (section omitted).
    var couldNotShowNotes: [String] {
        frontDoorNotes
            + missingContentParserDiagnostics.map(\.userMessage)
            + missingContentRenderLog.map(\.userMessage)
    }
}

// MARK: - Verbatim Mac wording (copied from EMFDocumentView.swift)

extension MetafileDiagnostic {
    var userMessage: String {
        switch self {
        case .sniff(.placeableChecksumMismatch):
            return "The placeable Windows Metafile header checksum didn't match; it's advisory, so the file was opened anyway."
        case .gzip(.isizeMismatch):
            return "The compressed wrapper's recorded size didn't match the expanded data; the expanded data was used."
        case .gzip(.trailingBytesAfterMember(let count)):
            return "The compressed file had \(count) extra byte\(count == 1 ? "" : "s") after its first member; they were ignored."
        }
    }
}

extension EMFDiagnostic {
    var userMessage: String {
        switch self {
        case .sizeTooSmall(let offset, let size):
            return "Record at byte \(offset) has an invalid size (\(size)); parsing stopped there."
        case .sizeNotAligned(let offset, let size):
            return "Record at byte \(offset) has a size of \(size), which is not four-byte aligned; parsing stopped there."
        case .sizeExceedsRemaining(let offset, let size, let remaining):
            return "Record at byte \(offset) claims \(size) bytes, but only \(remaining) remain; parsing stopped there."
        case .truncatedRecordHeader(let offset, let remaining):
            return "Only \(remaining) bytes remain at byte \(offset), which is too short for a record header; parsing stopped there."
        case .missingEOF:
            return "The file ended without an EMR_EOF record."
        case .trailingBytesAfterEOF(let count):
            return "The file contains \(count) trailing bytes after its EMR_EOF record."
        case .recordCountMismatch(let headerSays, let walked):
            return "The header claims \(headerSays) records, but Emfy found \(walked); the walked count was used."
        case .byteCountMismatch(let headerSays, let walked):
            return "The header claims \(headerSays) bytes, but Emfy walked \(walked); the walked count was used."
        case .recordCountCapped(let limit):
            return "The \(limit)-record safety limit was reached; later records were skipped."
        }
    }
}

extension EMFRenderLog.Entry {
    var userMessage: String {
        switch self {
        case .unimplementedRecord(let type, let count):
            return "Skipped unsupported record type \(type) (\(count) occurrence\(count == 1 ? "" : "s"))."
        case .malformedRecord(let type):
            return "Skipped malformed record type \(type)."
        case .unsupportedROP2(let rawMode, let count):
            return "Used normal copy drawing for unsupported ROP2 mode \(rawMode) (\(count) occurrence\(count == 1 ? "" : "s"))."
        case .unsupportedBrushStyle(let rawStyle):
            return "Used a solid fallback for unsupported brush style \(rawStyle)."
        case .unsupportedPenStyle(let rawStyle):
            return "Used a solid fallback for unsupported pen style \(rawStyle)."
        case .zeroExtentMapping:
            return "Kept the current mapping because the file contains a zero-sized extent."
        case .unsupportedClipMode(let record, let rawMode):
            return "Skipped unsupported clipping mode \(rawMode) in record type \(record)."
        case .noCurrentPath(let record):
            return "Skipped record type \(record) because it had no current path."
        case .nestedBeginPath:
            return "Started a new path after a nested path begin; the unfinished path was discarded."
        case .unknownEnumValue(let record, let rawValue):
            return "Ignored unknown value \(rawValue) in record type \(record)."
        case .malformedBezier(let pointCount):
            return "Rendered the valid part of a Bezier record with an invalid \(pointCount)-point count."
        case .invalidObjectIndex(let index):
            return "Ignored unavailable graphics object index \(index)."
        case .objectTableFull(let index):
            return "Ignored graphics object index \(index) because the object table is full."
        case .unsupportedStockObject(let rawValue):
            return "Ignored unsupported stock graphics object \(rawValue)."
        case .restoreDCUnbalanced(let savedDC):
            return "Could not restore graphics state \(savedDC) because no matching saved state exists."
        case .saveDCStackOverflow:
            return "Skipped a graphics-state save because the safety limit was reached."
        case .unsupportedWorldTransformMode(let rawMode):
            return "Ignored unsupported world-transform mode \(rawMode)."
        case .canvasClamped(let requestedWidth, let requestedHeight, let renderedWidth, let renderedHeight):
            return "Rendered at \(renderedWidth) × \(renderedHeight) instead of \(requestedWidth) × \(requestedHeight) to stay within the image safety limit."
        case .fontSubstituted(let requested, let used, let count):
            return "Used \(used) instead of unavailable font \(requested) (\(count) occurrence\(count == 1 ? "" : "s"))."
        case .stockFontUsed(let rawValue, let count):
            return "Used a system fallback for stock font \(rawValue) (\(count) occurrence\(count == 1 ? "" : "s"))."
        case .glyphIndexTextSkipped(let count):
            return "Skipped \(count) glyph-index text run\(count == 1 ? "" : "s") that could not be mapped to a macOS font."
        case .unsupportedDIB(let reason, let count):
            return "Skipped unsupported embedded bitmap\(reason.map { ": \($0.userMessage)" } ?? "") (\(count) occurrence\(count == 1 ? "" : "s"))."
        case .unsupportedRasterOp(let rasterOperation, let count):
            return "Used a best-effort fallback for raster operation \(rasterOperation) (\(count) occurrence\(count == 1 ? "" : "s"))."
        case .xformSrcIgnored(let count):
            return "Ignored a source bitmap transform (\(count) occurrence\(count == 1 ? "" : "s"))."
        case .dibDownsampled(let count, let worstNativePixels, let worstDecodedPixels):
            return "Decoded an embedded bitmap below its full resolution to fit the destination; no visible detail was lost (largest: \(worstNativePixels) → \(worstDecodedPixels) pixels, \(count) occurrence\(count == 1 ? "" : "s"))."
        case .emfPlusUnsupportedRecord(let type, let count):
            return "Skipped unsupported EMF+ record type \(String(format: "0x%04X", type)) (\(count) occurrence\(count == 1 ? "" : "s"))."
        case .emfPlusApproximated(let feature, let count):
            return "Approximated EMF+ \(feature.userDescription) (\(count) occurrence\(count == 1 ? "" : "s"))."
        case .emfPlusStreamIssue(let kind, let count):
            return "Couldn't fully read the EMF+ data — \(kind.userDescription) (\(count) occurrence\(count == 1 ? "" : "s"))."
        case .emfPlusRecordUndecodable(let type, let count):
            return "Skipped an unreadable EMF+ drawing record of type \(String(format: "0x%04X", type)) (\(count) occurrence\(count == 1 ? "" : "s"))."
        case .emfPlusObjectIssue(let kind, let count):
            return "\(kind.userDescription) (\(count) occurrence\(count == 1 ? "" : "s"))."
        case .emfPlusSaveStackCapped(let count):
            return "Reached the EMF+ save/container nesting limit; deeper saves were dropped (\(count) occurrence\(count == 1 ? "" : "s"))."
        }
    }
}

extension EMFPlusApproximation {
    var userDescription: String {
        switch self {
        case .hatchBrush:
            return "hatch fill as a solid color"
        case .pathGradientBrush:
            return "path-gradient fill as its center color"
        case .textureBrush:
            return "texture fill (skipped)"
        case .penNonSolidBrush:
            return "gradient/pattern pen stroke as a solid color"
        case .penCap:
            return "line cap as a round cap"
        case .penMiterLimit:
            return "an invalid pen miter limit as the default"
        case .clipCombineMode:
            return "clip combination as an intersection"
        case .regionCombine:
            return "region combination as a union"
        case .offsetClip:
            return "clip offset (left unchanged)"
        case .pageUnit:
            return "page unit as pixels"
        case .compositingMode:
            return "compositing as source-over"
        case .container:
            return "graphics container as a save/restore"
        case .linearGradientWrapMode:
            return "gradient tiling as a clamped fill"
        case .gradientGamma:
            return "gamma-corrected gradient as a linear blend"
        case .curveSegmentRange:
            return "partial curve range (drew the whole curve)"
        case .imageBitmapPixelFormat(let format):
            return "image pixel format \(String(format: "0x%08X", format)) (unsupported; image skipped)"
        case .imageInvalid:
            return "an invalid or oversized bitmap image (skipped)"
        case .imageCompressed:
            return "a compressed image that could not be decoded (skipped)"
        case .imageMetafile:
            return "a metafile image (nested playback unsupported; skipped)"
        case .imageSrcUnit:
            return "a non-pixel image source unit as pixels"
        case .imageAttributes:
            return "image attributes wrap mode (not applied)"
        case .imageDownsampled:
            return "a large bitmap image decoded at a reduced resolution"
        case .imageOversized:
            return "a compressed image too large for this view (skipped)"
        case .imageEffect:
            return "an image effect (drawn without it)"
        case .stringFormatSimplified:
            return "advanced text formatting as a single left-to-right line"
        case .pathDashSegment:
            return "per-segment path dashing as a solid path"
        }
    }
}

extension EMFPlusStreamIssueKind {
    var userDescription: String {
        switch self {
        case .commentDataSizeClamped:
            return "an EMF+ comment's declared size ran past its record"
        case .recordSizeTooSmall:
            return "an EMF+ record size below the header minimum"
        case .recordSizeNotAligned:
            return "an unaligned EMF+ record size"
        case .recordDataSizeExceedsSize:
            return "an EMF+ record's data size exceeded its record size"
        case .recordDataTruncated:
            return "a truncated EMF+ record running past the stream"
        case .recordSizeExcessPadding:
            return "an over-long EMF+ record size that hid the records after it"
        case .trailingBytes:
            return "leftover bytes after the last EMF+ record"
        case .headerRecordMissing:
            return "a missing EMF+ header record"
        case .headerUnexpectedSize:
            return "an unexpected EMF+ header size"
        case .headerUnexpectedDataSize:
            return "an unexpected EMF+ header data size"
        case .recordCountCapped:
            return "too many EMF+ records (the safety cap was reached)"
        }
    }
}

extension EMFPlusObjectIssueKind {
    var userDescription: String {
        switch self {
        case .missingReference:
            return "A drawing record referenced an EMF+ object that wasn't available"
        case .invalidID:
            return "An EMF+ object used an out-of-range table slot and was dropped"
        case .undecodable:
            return "An EMF+ object definition couldn't be decoded"
        }
    }
}

extension DIBUnsupportedReason {
    var userMessage: String {
        switch self {
        case .compression(let compression):
            return "compression \(compression.userMessage)"
        case .bitCount(let bitCount):
            return "\(bitCount)-bit color depth"
        case .paletteUsage(let paletteUsage):
            return "palette usage \(paletteUsage)"
        }
    }
}

extension BitmapCompression {
    var userMessage: String {
        switch self {
        case .rgb:
            return "BI_RGB"
        case .rle8:
            return "RLE8"
        case .rle4:
            return "RLE4"
        case .bitfields:
            return "bitfields"
        case .jpeg:
            return "JPEG"
        case .png:
            return "PNG"
        case .other(let rawValue):
            return "unknown format \(rawValue)"
        }
    }
}
