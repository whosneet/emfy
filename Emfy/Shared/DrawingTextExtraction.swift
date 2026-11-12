import CoreGraphics
import EMFEdit
import EMFParse
import EMFRender
import Foundation

// MARK: - Drawing text extraction (F3)
//
// A pure extractor that lifts the text runs of a drawing into sanitised value
// types the rest of F3 consumes: Find, Copy All Text, and Spotlight. It draws
// only from the ONE interpreter — either the renderer's `PlaybackObservation`
// (viewer mode) or the edited `Scene` (edit mode) — and never reinterprets a
// metafile a second time. OCR runs of embedded pictures join the same list with
// `source == .picture`; the extractor itself never touches Vision.
//
// Every string is sanitised: control characters stripped, capped at 32k code
// units per run and 1 MB across the whole file (CLAUDE.md §8 — this text is fed
// to Find, the clipboard and the Spotlight index, all of which Quick Look can
// drive on hostile input).

/// One extracted text run: a sanitised string, its device-space bounds, and the
/// font it was drawn with when that is known. Device space is the scene's own
/// y-DOWN coordinate space (header `rclBounds`); callers map it to the canvas
/// with the same device→target fit the viewer uses.
struct DrawingTextRun: Equatable, Sendable {
    /// Whether the run is text the drawing itself carries, or text recognised
    /// inside an embedded picture (OCR).
    enum Source: Equatable, Sendable {
        case drawing
        case picture
    }

    var text: String
    var boundsDevice: CGRect
    /// Resolved font family, when the source carried one (nil for OCR runs).
    var fontFamily: String?
    /// Font size magnitude in the run's own units (EMF+ em size, or the
    /// magnitude of a GDI logical height). nil when unknown or for OCR runs.
    var fontSize: Double?
    var source: Source
}

enum DrawingTextExtractor {

    /// Per-run cap: a single text record claiming a huge string is truncated
    /// rather than allocated whole downstream (§8).
    static let maxCharactersPerRun = 32_768
    /// Per-file cap across all runs: 1 MB of UTF-16 code units. Once reached,
    /// further runs are dropped.
    static let maxCharactersPerFile = 1_048_576

    // MARK: Sanitisation

    /// Strips control characters (Unicode Cc/Cf, including newlines, tabs and the
    /// NULs Office bakes into padded runs) and truncates to the per-run cap. The
    /// result is single-line printable text safe for a menu, the pasteboard and
    /// the Spotlight index.
    static func sanitize(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(min(raw.unicodeScalars.count, maxCharactersPerRun))
        var count = 0
        for scalar in raw.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) { continue }
            // Count in UTF-16 code units to match the documented 32k/1M caps.
            let width = scalar.value > 0xFFFF ? 2 : 1
            if count + width > maxCharactersPerRun { break }
            scalars.append(scalar)
            count += width
        }
        return String(scalars)
    }

    // MARK: Extraction from the renderer observation (viewer mode)

    /// Lifts text runs from a playback observation. GDI/WMF text lives in `ops`;
    /// EMF+ text lives in `plusEntries` (`.plus`), whose `.gdi` entries mirror
    /// `ops` and are read from there to avoid double counting.
    static func extract(from observation: PlaybackObservation) -> [DrawingTextRun] {
        var runs: [DrawingTextRun] = []
        var total = 0

        func append(_ string: String, bounds: CGRect, family: String?, size: Double?) {
            let clean = sanitize(string)
            guard !clean.isEmpty else { return }
            guard total < maxCharactersPerFile else { return }
            total += clean.utf16.count
            runs.append(DrawingTextRun(text: clean, boundsDevice: bounds, fontFamily: family, fontSize: size, source: .drawing))
        }

        for op in observation.ops where op.kind == .text {
            guard let text = op.text else { continue }
            let size = text.logicalHeight == 0 ? nil : Double(abs(text.logicalHeight))
            append(text.string, bounds: op.deviceGeometry.boundingBoxOrNull, family: emptyToNil(text.fontFamily), size: size)
        }
        for entry in observation.plusEntries {
            guard case .plus(let op) = entry, op.kind == .text, let text = op.text else { continue }
            let size = text.emSize > 0 ? text.emSize : nil
            append(text.string, bounds: op.deviceGeometry.boundingBoxOrNull, family: emptyToNil(text.resolvedFamily), size: size)
        }
        return runs
    }

    // MARK: Extraction from the edited scene (edit mode)

    /// Lifts text runs from a scene. Hidden elements are skipped (they are not on
    /// the canvas), matching the viewer.
    static func extract(from scene: Scene) -> [DrawingTextRun] {
        var runs: [DrawingTextRun] = []
        var total = 0
        for element in scene.elements where element.kind == .text && !element.hidden {
            guard let text = element.text else { continue }
            let clean = sanitize(text.string)
            guard !clean.isEmpty else { continue }
            guard total < maxCharactersPerFile else { break }
            total += clean.utf16.count
            let size: Double? = text.emSize > 0 ? text.emSize : (text.logicalHeight == 0 ? nil : Double(abs(text.logicalHeight)))
            runs.append(DrawingTextRun(
                text: clean,
                boundsDevice: element.boundsDevice,
                fontFamily: emptyToNil(text.fontFamily),
                fontSize: size,
                source: .drawing
            ))
        }
        return runs
    }

    // MARK: Reading order

    /// Sorts runs in reading order: top-to-bottom, then left-to-right. Device
    /// space is y-DOWN, so "top" is the smaller `minY`. Runs whose vertical
    /// centres fall within a row band are treated as the same line and ordered by
    /// `minX`; OCR-vs-drawing source does not affect the sort.
    static func readingOrder(_ runs: [DrawingTextRun]) -> [DrawingTextRun] {
        guard runs.count > 1 else { return runs }
        // Row band: half the median run height, with a 1pt floor so degenerate
        // (zero-height) bounds still cluster deterministically.
        let heights = runs.map { max($0.boundsDevice.height, 0) }.sorted()
        let median = heights[heights.count / 2]
        let band = max(median * 0.5, 1)

        let byTop = runs.enumerated().sorted { a, b in
            let ay = a.element.boundsDevice.midY, by = b.element.boundsDevice.midY
            if abs(ay - by) > band { return ay < by }
            let ax = a.element.boundsDevice.minX, bx = b.element.boundsDevice.minX
            if ax != bx { return ax < bx }
            return a.offset < b.offset   // stable tie-break on original order
        }
        return byTop.map(\.element)
    }

    // MARK: Copy All Text

    /// Every run's text in reading order as plain text, one run per line. OCR
    /// runs are grouped under a "Text in pictures" heading after the drawing
    /// text, matching the Copy All Text spec. Returns an empty string when there
    /// is nothing to copy.
    static func copyAllText(_ runs: [DrawingTextRun]) -> String {
        let drawing = readingOrder(runs.filter { $0.source == .drawing }).map(\.text)
        let picture = readingOrder(runs.filter { $0.source == .picture }).map(\.text)
        var sections: [String] = []
        if !drawing.isEmpty { sections.append(drawing.joined(separator: "\n")) }
        if !picture.isEmpty {
            sections.append((["Text in pictures:"] + picture).joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func emptyToNil(_ s: String) -> String? {
        s.isEmpty ? nil : s
    }
}

private extension CGPath {
    /// The bounding box, or `.null` for an empty path (so an unknown-bounds text
    /// op does not report a spurious zero rect at the origin).
    var boundingBoxOrNull: CGRect {
        isEmpty ? .null : boundingBox
    }
}
