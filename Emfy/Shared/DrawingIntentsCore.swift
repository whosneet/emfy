import AppIntents
import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import UniformTypeIdentifiers

// MARK: - App Intents: convert, read text, inspect (F4a)
//
// Three on-device intents that take a `DrawingEntity` (a remembered file) OR an
// `IntentFile` (any .emf / .emz / .wmf / .wmz the user hands in), and return a
// converted file, the drawing's text, or a structured info summary. The heavy
// parse/render/OCR runs off the main actor through the same EMFKit front door and
// F1/F3 cores the viewer uses, so there is no second interpreter and no network.
//
// Hostile input is the default case, not an edge (CLAUDE.md §8): every producer
// validates through `OpenedMetafile.open` / `MetafileRenderer.prepare` and turns a
// non-metafile or a failed conversion into a typed `AppIntentDrawingError` with a
// friendly message — never a crash and never a silent empty result.
//
// The Open intent (which needs the app's window coordinator) and the
// `AppShortcutsProvider` live in their own files; the Apple Intelligence surface
// (IndexedEntity / assistant schemas) is F4b and layers on without changing these.

/// The typed failure every intent surfaces to Shortcuts/Siri. Conforming to
/// `CustomLocalizedStringResourceConvertible` gives each case a plain-English
/// message the automation shows in place of a crash.
enum AppIntentDrawingError: Error, CustomLocalizedStringResourceConvertible {
    case noInput
    case notFound
    case couldNotRead
    case notAMetafile
    case conversionFailed
    case outputTooLarge

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noInput: "Choose a drawing or a file for Emfy to use."
        case .notFound: "That drawing isn’t in Emfy’s recent files anymore."
        case .couldNotRead: "Emfy couldn’t read that drawing. The file may be offline, moved or damaged."
        case .notAMetafile: "That isn’t an EMF, EMZ, WMF or WMZ drawing Emfy can read."
        case .conversionFailed: "Emfy couldn’t convert that drawing."
        case .outputTooLarge: "The converted file is too large to return."
        }
    }
}

/// The output format for Convert Drawing, as an `AppEnum` so Shortcuts shows a
/// PNG/PDF/SVG picker. Maps to the F1 `BatchOutputFormat` rather than conforming
/// that core type to App Intents, so the Quick Look extensions never link
/// AppIntents.
enum DrawingExportFormat: String, AppEnum {
    // Explicit raw values (SI-M): the raw string is the stable identifier persisted in
    // a saved shortcut, so it must not drift if a case is ever renamed in code.
    case png = "png"
    case pdf = "pdf"
    case svg = "svg"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Export Format"
    static let caseDisplayRepresentations: [DrawingExportFormat: DisplayRepresentation] = [
        .png: "PNG",
        .pdf: "PDF",
        .svg: "SVG",
    ]

    var batch: BatchOutputFormat {
        switch self {
        case .png: .png
        case .pdf: .pdf
        case .svg: .svg
        }
    }

    var pathExtension: String { rawValue }

    var utType: UTType {
        switch self {
        case .png: .png
        case .pdf: .pdf
        case .svg: .svg
        }
    }
}

/// The structured result of Get Drawing Info: typed facts plus a model-friendly
/// summary string. Pure and `Sendable`, so the intent formats it off-main and the
/// tests assert on the typed fields directly.
struct DrawingInfo: Sendable, Equatable {
    /// The full format name ("Enhanced Metafile").
    var format: String
    /// The physical page size in millimetres, from the EMF header frame
    /// ([MS-EMF] §2.2.9, hundredths of a millimetre). `nil` for WMF, whose
    /// physical size isn't cleanly expressible here.
    var pageSizeMM: CGSize?
    /// The drawing's record count (the walker's own count).
    var recordCount: Int
    /// Whether the drawing carries any text runs.
    var hasText: Bool
    /// Whether the drawing embeds any pictures.
    var hasPictures: Bool

    var summary: String {
        var lines = ["Format: \(format)"]
        if let pageSizeMM {
            lines.append("Page size: \(Self.mm(pageSizeMM.width)) × \(Self.mm(pageSizeMM.height)) mm")
        }
        lines.append("Records: \(recordCount)")
        lines.append("Contains text: \(hasText ? "yes" : "no")")
        lines.append("Contains pictures: \(hasPictures ? "yes" : "no")")
        return lines.joined(separator: "\n")
    }

    private static func mm(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

// MARK: - Shared producers

/// The shared loader every intent uses: it turns an entity or an incoming file into
/// bytes, then into the converted output, the text, or the info. One place keeps the
/// validation, the caps and the friendly errors consistent.
enum AppIntentDrawing {
    /// A conversion result above this never returns — a bound on what an automation
    /// can pull out of one drawing (§8).
    static let maxOutputBytes = 100 * 1024 * 1024

    /// Resolves the input to bytes plus a display name, preferring a chosen drawing,
    /// then an incoming file. Reads the main-actor store for an entity; a file's
    /// bytes are already in hand.
    @MainActor
    static func bytes(entity: DrawingEntity?, file: IntentFile?) async throws -> (data: Data, name: String) {
        if let entity {
            let store = RecentsStore.shared
            await store.loadIfNeeded()
            // Private mode hides the whole library from automation (SI-L): re-check it here
            // too, so a stale entity id handed straight to an intent can't bypass the query's
            // Private-mode filter. Session-private entries stay hidden even with Private off.
            guard !store.isPrivate,
                  let entry = store.entry(id: entity.id), !store.isSessionPrivate(entity.id) else {
                throw AppIntentDrawingError.notFound
            }
            do {
                return (try await store.resolveData(for: entry), entry.displayName)
            } catch {
                throw AppIntentDrawingError.couldNotRead
            }
        }
        if let file {
            let data = file.data
            guard !data.isEmpty else { throw AppIntentDrawingError.couldNotRead }
            return (data, file.filename)
        }
        throw AppIntentDrawingError.noInput
    }

    /// Converts `data` to `format` through the F1 batch renderer (same bytes the
    /// viewer's export produces), clamping the PNG scale and capping the output.
    static func convert(_ data: Data, format: DrawingExportFormat, scale: Int) throws -> Data {
        let clampedScale = min(max(scale, 1), 4)
        switch BatchRenderer.produce(
            bytes: data, format: format.batch,
            pngScale: clampedScale, background: .white, options: .default
        ) {
        case .converted(let output):
            guard output.count <= maxOutputBytes else { throw AppIntentDrawingError.outputTooLarge }
            return output
        case .unparseable:
            throw AppIntentDrawingError.notAMetafile
        case .failed:
            throw AppIntentDrawingError.conversionFailed
        }
    }

    /// Reads the drawing's text in Copy All Text reading order — the "Use
    /// Model"-friendly output. Picture OCR joins when asked, within its own budget
    /// (`DrawingOCRService`). A parseable drawing with no text returns an empty
    /// string; a non-metafile throws.
    static func text(from data: Data, includePictures: Bool) async throws -> String {
        guard let opened = try? OpenedMetafile.open(data),
              let prepared = MetafileRenderer.prepare(opened) else {
            throw AppIntentDrawingError.notAMetafile
        }
        let observation = MetafileRenderer.observe(prepared)
        var runs = DrawingTextExtractor.extract(from: observation)
        if includePictures {
            let pictures = DrawingPictureEnumerator.pictures(from: observation)
            runs += await DrawingOCRService.shared.recognize(pictures: pictures)
        }
        return DrawingTextExtractor.copyAllText(runs)
    }

    /// Inspects the drawing: format, physical page size, record count, and whether
    /// it carries text or pictures. Throws for a non-metafile.
    static func info(from data: Data, fileName: String) throws -> DrawingInfo {
        guard let opened = try? OpenedMetafile.open(data),
              let prepared = MetafileRenderer.prepare(opened) else {
            throw AppIntentDrawingError.notAMetafile
        }
        let observation = MetafileRenderer.observe(prepared)
        let textRuns = DrawingTextExtractor.extract(from: observation)
        let pictures = DrawingPictureEnumerator.pictures(from: observation)
        let recordCount = prepared.recordKinds.reduce(0) { $0 + $1.count }
        return DrawingInfo(
            format: MetafileFormatLabel.names(for: fileName).full,
            pageSizeMM: pageSizeMM(opened: opened),
            recordCount: recordCount,
            hasText: !textRuns.isEmpty,
            hasPictures: !pictures.isEmpty
        )
    }

    /// The EMF document's physical page size in millimetres from the header frame
    /// ([MS-EMF] §2.2.9, inclusive-inclusive, hundredths of a millimetre). `nil`
    /// for WMF or a degenerate frame. Internal so the A1 AI context can reuse it.
    static func pageSizeMM(opened: OpenedMetafile) -> CGSize? {
        guard opened.format == .emf, let file = try? EMFFile.parse(opened.data) else { return nil }
        let frame = file.header.frame
        let widthUnits = Int64(frame.right) - Int64(frame.left) + 1
        let heightUnits = Int64(frame.bottom) - Int64(frame.top) + 1
        guard widthUnits > 0, heightUnits > 0 else { return nil }
        let width = Double(widthUnits) / 100.0
        let height = Double(heightUnits) / 100.0
        guard width.isFinite, height.isFinite, width >= 0.1, height >= 0.1 else { return nil }
        return CGSize(width: width, height: height)
    }
}

// MARK: - Convert Drawing

struct ConvertDrawingIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Drawing"
    static let description = IntentDescription(
        "Convert an EMF, EMZ, WMF or WMZ drawing to PNG, PDF or SVG.",
        categoryName: "Drawings"
    )

    @Parameter(title: "Drawing")
    var drawing: DrawingEntity?

    @Parameter(title: "File")
    var file: IntentFile?

    @Parameter(title: "Format", default: .png)
    var format: DrawingExportFormat

    @Parameter(title: "PNG Scale", default: 2)
    var scale: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$drawing) to \(\.$format)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        // Ask Shortcuts to supply a value rather than failing with a generic error (SI-M).
        guard drawing != nil || file != nil else { throw $drawing.needsValueError() }
        let input = try await AppIntentDrawing.bytes(entity: drawing, file: file)
        let chosenFormat = format
        let chosenScale = scale
        let output = try await Task.detached(priority: .userInitiated) {
            try AppIntentDrawing.convert(input.data, format: chosenFormat, scale: chosenScale)
        }.value
        let stem = (input.name as NSString).deletingPathExtension
        let result = IntentFile(
            data: output,
            filename: "\(stem).\(chosenFormat.pathExtension)",
            type: chosenFormat.utType
        )
        return .result(value: result)
    }
}

// MARK: - Get Text from Drawing

struct GetTextFromDrawingIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Text from Drawing"
    static let description = IntentDescription(
        "Read the text in a drawing, in reading order — ready to pass to a model.",
        categoryName: "Drawings"
    )

    @Parameter(title: "Drawing")
    var drawing: DrawingEntity?

    @Parameter(title: "File")
    var file: IntentFile?

    @Parameter(title: "Include Text in Pictures", default: true)
    var includePictures: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Get text from \(\.$drawing)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // Ask Shortcuts to supply a value rather than failing with a generic error (SI-M).
        guard drawing != nil || file != nil else { throw $drawing.needsValueError() }
        let input = try await AppIntentDrawing.bytes(entity: drawing, file: file)
        let includePics = includePictures
        let text = try await Task.detached(priority: .userInitiated) {
            try await AppIntentDrawing.text(from: input.data, includePictures: includePics)
        }.value
        // A short result dialog (SI-L), so Siri/Shortcuts confirm the outcome without reading
        // back the whole (possibly long) extracted text — that stays the returned value.
        let dialog: IntentDialog = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? IntentDialog("No text found in \(input.name).")
            : IntentDialog("Found \(text.count) characters of text in \(input.name).")
        return .result(value: text, dialog: dialog)
    }
}

// MARK: - Get Drawing Info

struct GetDrawingInfoIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Drawing Info"
    static let description = IntentDescription(
        "Get a drawing’s format, page size, record count, and whether it has text or pictures.",
        categoryName: "Drawings"
    )

    @Parameter(title: "Drawing")
    var drawing: DrawingEntity?

    @Parameter(title: "File")
    var file: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Get info about \(\.$drawing)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // Ask Shortcuts to supply a value rather than failing with a generic error (SI-M).
        guard drawing != nil || file != nil else { throw $drawing.needsValueError() }
        let input = try await AppIntentDrawing.bytes(entity: drawing, file: file)
        let name = input.name
        let info = try await Task.detached(priority: .userInitiated) {
            try AppIntentDrawing.info(from: input.data, fileName: name)
        }.value
        return .result(value: info.summary)
    }
}
