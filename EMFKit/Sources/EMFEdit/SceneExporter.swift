import CoreGraphics
import EMFParse
import EMFRender
import EMFWrite
import Foundation
import WMFParse

/// The output format `SceneExporter` writes.
public enum ExportFormat: Sendable, Equatable {
    /// Enhanced Metafile (EMF+ with a GDI fallback once E1b2 lands; GDI-only here).
    case emf
    /// Gzip-compressed EMF (.emz).
    case emz
    /// Windows Metafile (placeable).
    case wmf
    /// Gzip-compressed WMF (.wmz).
    case wmz

    /// EMF or EMZ.
    public var isEMFFamily: Bool { self == .emf || self == .emz }
    /// Whether the result is gzip-wrapped.
    public var isCompressed: Bool { self == .emz || self == .wmz }
}

/// A fidelity loss the export could not avoid — the honest record of what a GDI
/// or WMF container cannot hold (docs/v3-plan §11.1). E1b2 writes alpha and
/// gradients as EMF+ instead.
public enum ExportWarning: Sendable, Equatable {
    /// Sub-1 opacity was dropped (GDI has no alpha). `elementID` names the element.
    case opacityDropped(elementID: Int)
    /// A gradient fill was approximated by its representative solid colour.
    case gradientFlattened(elementID: Int)
    /// A text run carried characters outside Latin-1, lossy in a WMF 8-bit string.
    case textNotLatin1(elementID: Int)
    /// An image could not be re-encoded (no retained/supported DIB) and was dropped.
    case imageDropped(elementID: Int)
    /// A rotated/sheared image destination (a parallelogram) was written to a GDI
    /// or WMF container, which can only STRETCHDIBITS into an axis-aligned rect, so
    /// the rotation was dropped to the bounding box. EMF+ keeps it via
    /// EmfPlusDrawImagePoints.
    case imageRotated(elementID: Int)
    /// The element's exact kind could not be re-emitted (a rotated rect, or a
    /// kind whose parameters the scene does not retain — ROUNDRECT, ARC/PIE/CHORD,
    /// or a curve in WMF), so it was written as a path bracket / flattened polygon.
    case kindFallback(elementID: Int, kind: ElementKind)
    /// A WMF whose drawing comes from an embedded EMF was edited: the edit lands
    /// in the re-embedded EMF, but the plain WMF records are unchanged, so a
    /// WMF-only reader shows the ORIGINAL drawing.
    case embeddedEMFOnly
    /// A DUAL EMF+ file was edited: the EMF+ half carries the edit, and a fresh
    /// GDI block is added for each edited/new element, but the file's ORIGINAL GDI
    /// fallback could not be paired to the edited elements and is kept, so a
    /// GDI-mode reader may show stale content beneath the edit (slice E1b2a).
    case fallbackMayBeStale
    /// A cross-container EMF→WMF export scaled the whole drawing down so its
    /// coordinates fit WMF's signed 16-bit fields ([MS-WMF] §2.2.2.15/.16), at
    /// some loss of precision (slice E1b2c). Document-level: a wide-extent EMF.
    case coordinatesScaled
    /// A text run under a non-axis-aligned world transform (rotation or shear
    /// beyond a LOGFONT escapement) was written to a GDI/WMF container, which
    /// carries only an escapement angle, so the general matrix was dropped.
    case textRotationDropped(elementID: Int)
    /// An element the target container cannot represent at all — an EMF+-only
    /// feature (a passthrough/unsupported EMF+ record) or a GDI raster op — was
    /// dropped from a cross-container export (slice E1b2c). Its content is lost.
    case contentDropped(elementID: Int)
    /// A scene with a non-trivial layer structure was exported to WMF/WMZ, which has
    /// no record Emfy uses to persist layers (unlike EMF's private EMR_COMMENT
    /// markers), so every layer was flattened into one (design §1 / review fix 3).
    /// Document-level — not tied to one element.
    case layersFlattened
    /// An element the target container could not re-synthesise faithfully — a
    /// passthrough/unsupported EMF+ record, a WMF raster/ROP blit, a non-Latin-1
    /// text run (WMF strings are 8-bit), or an EMF+ text run — was RASTERISED: it
    /// was drawn alone into a bitmap at its device bounds and emitted as an image
    /// record (EMR_STRETCHDIBITS / META_STRETCHDIB) so it still looks right, at the
    /// cost of editability and a resample (slice E1b2c2).
    case contentRasterized(elementID: Int)
}

/// A user-facing grouping of `ExportWarning`s, so the app can show one short list
/// ("3 shapes approximated", "opacity dropped on 2 images") instead of raw cases.
public enum ExportWarningCategory: String, Sendable, CaseIterable {
    /// `opacityDropped` — alpha a GDI/WMF container cannot hold.
    case opacity
    /// `gradientFlattened` — a gradient reduced to a solid.
    case gradient
    /// `textNotLatin1`, `textRotationDropped` — text the container narrows.
    case text
    /// `imageDropped`, `imageRotated` — an image dropped or axis-aligned.
    case image
    /// `kindFallback` — a shape re-emitted as an approximating path/polygon.
    case shapeApproximated
    /// `coordinatesScaled` — the drawing scaled to fit 16-bit coordinates.
    case coordinates
    /// `contentDropped` — an element the container cannot represent at all.
    case droppedContent
    /// `contentRasterized` — an element re-emitted as a bitmap to keep its look.
    case rasterized
    /// `embeddedEMFOnly`, `fallbackMayBeStale` — a down-level reader may see
    /// pre-edit content.
    case downlevelStale
    /// `layersFlattened` — a layered scene collapsed to one layer for a WMF export.
    case layers
}

/// The bytes a `SceneExporter` produced, plus any fidelity warnings.
public struct ExportResult: Sendable, Equatable {
    public let data: Data
    public let warnings: [ExportWarning]

    public init(data: Data, warnings: [ExportWarning]) {
        self.data = data
        self.warnings = warnings
    }
}

/// Export tuning.
public struct ExportOptions: Sendable, Equatable {
    /// Force a GDI-only EMF even when an edit needs a feature GDI cannot express
    /// (sub-1 opacity or a gradient). By default (false) a GDI-only EMF that
    /// gains such a feature is written as a DUAL EMF+ file (slice E1b2b): the
    /// EMF+ half carries the edit faithfully and a GDI approximation serves
    /// down-level readers, so NO `opacityDropped`/`gradientFlattened` warning is
    /// raised. Set true to keep a flat GDI EMF (the E1b1 behaviour) with the
    /// feature flattened and the warning emitted.
    public var forceGDIOnly: Bool
    /// When an EMF/EMZ scene is exported to WMF/WMZ, embed a complete copy of the
    /// current scene's EMF export into the WMF (as WMFC escape records, [MS-WMF]
    /// §2.3.6.25), so a reader that understands it (Emfy included) recovers full
    /// fidelity while a plain-WMF reader draws the synthesised GDI records. On by
    /// default (owner decision, docs/v3-plan §11.1); set false for a plain WMF.
    public var embedEMFInWMF: Bool

    public init(forceGDIOnly: Bool = false, embedEMFInWMF: Bool = true) {
        self.forceGDIOnly = forceGDIOnly
        self.embedEMFInWMF = embedEMFInWMF
    }
}

/// Why an export failed (always typed — never a trap, §8).
public enum SceneExportError: Error, Sendable, Equatable {
    /// The scene genuinely cannot be written to the requested format (reserved for
    /// a case neither container can represent). Cross-container EMF↔WMF export is
    /// supported as of slice E1b2c, so this is no longer thrown for it.
    case unsupported(reason: String)
    /// The retained source bytes no longer parse (should not happen for an
    /// imported scene; defensive).
    case unreadableSource
    /// The EMF serialiser refused the synthesised document.
    case emfWriteFailed(EMFWriteError)
    /// The WMF serialiser refused the synthesised document (e.g. a device
    /// coordinate overflowed the 16-bit field).
    case wmfWriteFailed(WMFWriteError)
}

/// Writes an edited `Scene` back to a metafile (E1b1: GDI- and WMF-sourced
/// scenes). An UNCHANGED scene re-emits its source verbatim (byte-identical to
/// E0). An edited GDI EMF (and an edited plain WMF) is written as a lossless
/// OVERLAY — every unedited record is kept, only edited/new elements are
/// synthesised in place: in the EMF's device space for EMF, in the WMF's own
/// logical space for WMF (its scene provenance maps through the translated
/// program's per-payload source index back to source WMF records). A WMF whose
/// scene came from an embedded EMF overlays that EMF and re-embeds it.
/// Cross-container conversion and editing EMF+ are E1b2 (a typed `unsupported`
/// error here).
public enum SceneExporter {

    /// Record types that carry an object-table handle in their first body field
    /// ([MS-EMF] §2.3.7/§2.3.8), used to place synthesised objects above the
    /// file's highest handle. Mirrors `EMFDocumentWriter.handleFieldTypes`.
    private static let handleFieldTypes: Set<UInt32> = [37, 38, 39, 40, 49, 82, 93, 94, 95, 99, 122]

    /// EMR_EOF type id ([MS-EMF] §2.1.1).
    private static let eofType: UInt32 = 14
    /// EMR_COMMENT type id ([MS-EMF] §2.1.1).
    private static let emrCommentType: UInt32 = 70
    /// "EMF+" little-endian ([MS-EMF] §2.3.3.4 CommentIdentifier).
    private static let emfPlusCommentIdentifier: UInt32 = 0x2B46_4D45
    /// The 20-byte canonical EMR_EOF ([MS-EMF] §2.3.4.1): Type 14, Size 20,
    /// nPalEntries 0, offPalEntries 0x10, SizeLast 20 — the terminator GDI writes
    /// and `EMFDocumentWriter.encodeEOF` produces. Appended only when the source
    /// lacks an EOF (see `overlayEMF`).
    private static let canonicalEMFEOF: [UInt8] = [
        14, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0, 0x10, 0, 0, 0, 20, 0, 0, 0,
    ]

    public static func export(_ scene: Scene, as format: ExportFormat) throws(SceneExportError) -> ExportResult {
        try export(scene, as: format, options: ExportOptions())
    }

    public static func export(_ scene: Scene, as format: ExportFormat, options: ExportOptions) throws(SceneExportError) -> ExportResult {
        let sourceIsEMF = scene.source.format == .emf
        // WMF/WMZ has no record Emfy uses to persist layers, so a layered scene is
        // flattened to one layer with a document-level warning (review fix 3).
        let wmfLayersFlattened: [ExportWarning] = (!format.isEMFFamily && scene.hasNonTrivialLayers) ? [.layersFlattened] : []

        // Cross-container (EMF scene → WMF, or WMF scene → EMF): full synthesis in
        // the target container, with a de-duplicated limitations report (slice
        // E1b2c). Handles unedited and edited scenes alike (an unedited WMF with a
        // current embedded EMF re-emits that EMF losslessly).
        if sourceIsEMF != format.isEMFFamily {
            let result: (Data, [ExportWarning])
            if sourceIsEMF {
                do { result = try exportEMFSceneAsWMF(scene, options: options) }
                catch let error as SceneExportError { throw error }
                catch let error as WMFWriteError { throw .wmfWriteFailed(error) }
                catch let error as EMFWriteError { throw .emfWriteFailed(error) }
                catch { throw .unreadableSource }
            } else {
                do { result = try exportWMFSceneAsEMF(scene, options: options) }
                catch let error as SceneExportError { throw error }
                catch let error as EMFWriteError { throw .emfWriteFailed(error) }
                catch { throw .unreadableSource }
            }
            return ExportResult(data: finalize(result.0, format), warnings: dedupe(result.1 + wmfLayersFlattened))
        }

        // Coverage-based `isEdited` cannot see an EMF+ delete — every EMF+ element's
        // provenance is the shared EMR_COMMENT index, so removing one leaves the
        // covered set unchanged. An EMF+ EMF scene therefore ALWAYS routes through
        // the overlay, which re-detects the delete and falls back to a byte-identical
        // re-emit when nothing actually changed.
        let emfPlusEMF = format.isEMFFamily && scene.source.format == .emf && scene.source.renderPath == .emfPlus
        // A non-trivial layer structure must be (re)written as markers even when no
        // element changed — a rename or a reorder leaves `isEdited` false — so such a
        // scene routes through the overlay rather than a verbatim re-emit (E3d).
        if !isEdited(scene), !emfPlusEMF, !scene.hasNonTrivialLayers {
            let data = try reEmitUnchanged(scene)
            return ExportResult(data: finalize(data, format), warnings: [])
        }

        if format.isEMFFamily {
            let file: EMFFile
            do { file = try EMFFile.parse(scene.source.data) } catch { throw .unreadableSource }
            if scene.source.renderPath == .emfPlus {
                let result: (Data, [ExportWarning])
                do { result = try overlayEMFPlus(file, scene, source: scene.source.data) }
                catch let error as SceneExportError { throw error }
                catch let error as EMFWriteError { throw .emfWriteFailed(error) }
                catch { throw .unreadableSource }
                return ExportResult(data: finalize(result.0, format), warnings: result.1)
            }
            // A GDI-only EMF whose edit needs opacity or a gradient is upgraded to a
            // DUAL EMF+ file (slice E1b2b): the EMF+ half carries the edit faithfully,
            // a GDI approximation serves down-level readers. `forceGDIOnly` keeps the
            // flat GDI EMF (E1b1), flattening the feature with a warning.
            if !options.forceGDIOnly, needsEMFPlus(scene) {
                let result: (Data, [ExportWarning])
                do { result = try overlayGDIAsDual(file, scene, source: scene.source.data) }
                catch let error as SceneExportError { throw error }
                catch let error as EMFWriteError { throw .emfWriteFailed(error) }
                catch { throw .unreadableSource }
                return ExportResult(data: finalize(result.0, format), warnings: result.1)
            }
            let result: (Data, [ExportWarning])
            do { result = try overlayEMF(file, scene, source: scene.source.data) }
            catch { throw .emfWriteFailed(error) }
            return ExportResult(data: finalize(result.0, format), warnings: result.1)
        }
        let (data, warnings) = try exportEditedWMF(scene)
        return ExportResult(data: finalize(data, format), warnings: dedupe(warnings + wmfLayersFlattened))
    }

    // MARK: - GDI → dual upgrade detection (slice E1b2b)

    /// True when an edited or new element of `scene` needs a feature a GDI (EMF)
    /// container cannot express — sub-1 opacity, a sub-1 paint alpha, or a gradient
    /// fill — so the GDI EMF export must upgrade to a dual EMF+ file to carry it
    /// faithfully ([MS-EMFPLUS] §1.3.1). Only edited/new elements are considered:
    /// unedited content re-emits its original GDI records verbatim.
    static func needsEMFPlus(_ scene: Scene) -> Bool {
        for element in scene.elements where element.provenance.edited || element.provenance.sourceRecordIndices.isEmpty {
            if elementNeedsEMFPlus(element) { return true }
        }
        return false
    }

    /// Whether one element carries a feature GDI cannot express: element opacity
    /// below 1, a gradient fill, or a fill/stroke/text colour with alpha below 1.
    /// An IMAGE's opacity now DOES drive a dual upgrade — slice E1b2c bakes it into
    /// the EMF+ bitmap's PNG alpha, so the EMF+ half blends while the GDI fallback
    /// stays opaque with an `opacityDropped` report.
    static func elementNeedsEMFPlus(_ element: Element) -> Bool {
        guard !element.hidden else { return false }
        if element.style.opacity < 1 { return true }
        if let fill = element.style.fill {
            if fill.gradient != nil { return true }
            if fill.color.alpha < 1 { return true }
        }
        if let stroke = element.style.stroke, stroke.color.alpha < 1 { return true }
        if let text = element.text, text.color.alpha < 1 { return true }
        return false
    }

    // MARK: - Warning de-duplication and summary (slice E1b2c)

    /// Removes duplicate warnings, preserving first-occurrence order — the caller
    /// gets one complete list it can show the user.
    static func dedupe(_ warnings: [ExportWarning]) -> [ExportWarning] {
        var unique: [ExportWarning] = []
        for warning in warnings where !unique.contains(warning) { unique.append(warning) }
        return unique
    }

    /// Groups a warning list into user-facing categories, each with the count of
    /// distinct warnings it holds — so the app shows one short line per category
    /// instead of raw cases. Input is de-duplicated first.
    public static func summarize(_ warnings: [ExportWarning]) -> [ExportWarningCategory: Int] {
        var counts: [ExportWarningCategory: Int] = [:]
        for warning in dedupe(warnings) { counts[category(of: warning), default: 0] += 1 }
        return counts
    }

    private static func category(of warning: ExportWarning) -> ExportWarningCategory {
        switch warning {
        case .opacityDropped: return .opacity
        case .gradientFlattened: return .gradient
        case .textNotLatin1, .textRotationDropped: return .text
        case .imageDropped, .imageRotated: return .image
        case .kindFallback: return .shapeApproximated
        case .coordinatesScaled: return .coordinates
        case .contentDropped: return .droppedContent
        case .contentRasterized: return .rasterized
        case .embeddedEMFOnly, .fallbackMayBeStale: return .downlevelStale
        case .layersFlattened: return .layers
        }
    }

    // MARK: - Cross-container rasterisation decision (slice E1b2c2)

    /// True when a cross-container export cannot re-synthesise `element` faithfully,
    /// so it is RASTERISED (drawn alone into a bitmap, emitted as an image record)
    /// rather than dropped: a passthrough (an unsupported EMF+ record, a WMF raster/
    /// ROP blit, glyph-index text), a non-Latin-1 text run (WMF strings are 8-bit),
    /// an EMF+ text run (sized by an em size no GDI/WMF field holds), or a rotated/
    /// sheared image (a parallelogram a STRETCHDIBITS axis-aligned rect cannot hold).
    static func shouldRasterize(_ element: Element) -> Bool {
        guard !element.hidden, element.kind != .group else { return false }
        switch element.kind {
        case .passthrough:
            return true
        case .text:
            guard let text = element.text else { return false }
            if text.isEMFPlus { return true }
            return text.string.unicodeScalars.contains { $0.value > 0xFF }
        case .image:
            return element.image?.destCornersDevice != nil
        default:
            return false
        }
    }

    /// True when `element` carries a SOURCE (unedited) gradient fill. WMF has no
    /// gradient record, so such a shape in a plain-WMF export is RASTERISED (stored as
    /// an image) rather than flattened to one representative solid (slice E1b2d item
    /// 6); a solid-fill shape stays vector. Gradients only reach the scene from an
    /// EMF+ source, so an unedited gradient always lifts from the EMF+ stream the
    /// rasteriser can replay. An EDITED gradient (one added onto a shape) is NOT
    /// rasterised — the rasteriser replays the source draw, which does not carry the
    /// edit — so it keeps the flatten-to-solid path and its `gradientFlattened` report.
    static func elementHasGradientFill(_ element: Element) -> Bool {
        guard !element.hidden, element.kind != .group else { return false }
        guard !element.provenance.edited, !element.provenance.sourceRecordIndices.isEmpty else { return false }
        return element.style.fill?.gradient != nil
    }

    /// The EMF→WMF rasterisation predicate: the cross-container cases `shouldRasterize`
    /// covers, PLUS a gradient fill WMF cannot express vectorially. EMF targets are
    /// unaffected (EMF+ carries the gradient), so this is WMF-export-only.
    static func shouldRasterizeForWMF(_ element: Element) -> Bool {
        shouldRasterize(element) || elementHasGradientFill(element)
    }

    /// The warning raised when `element` is rasterised: a rotated image keeps
    /// `imageRotated` (the rotation was the reason), everything else is the generic
    /// `contentRasterized` (the element became a bitmap — for a gradient fill, the
    /// "gradient stored as an image" outcome, summarised under `.rasterized`).
    private static func rasterWarning(for element: Element) -> ExportWarning {
        if element.kind == .image, element.image?.destCornersDevice != nil {
            return .imageRotated(elementID: element.id)
        }
        return .contentRasterized(elementID: element.id)
    }

    // MARK: - Cross-container: EMF scene → WMF (full synthesis, slice E1b2c)

    /// Writes an EMF (or EMF+/dual) scene to a placeable WMF by full synthesis: a
    /// `WMFDocumentBuilder` program whose placeable BoundingBox is the scene page
    /// mapped into a 16-bit-safe logical space ([MS-WMF] §2.3.2.3), with every
    /// visible element drawn through the shared WMF synthesis in z-order. Coordinate
    /// scale: the logical grid is supersampled to its Int16-safe maximum so sub-pixel
    /// device positions survive integer rounding (`wmfLogicalMapping`); the Inch and
    /// viewport scale it back onto a device canvas the size of the EMF page. A drawing
    /// already too large for Int16 is scaled DOWN uniformly (`coordinatesScaled`). The current
    /// scene's EMF export is embedded by default so a reader that understands it
    /// recovers full fidelity (`embedEMFInWMF`).
    private static func exportEMFSceneAsWMF(_ scene: Scene, options: ExportOptions) throws -> (Data, [ExportWarning]) {
        let map = wmfLogicalMapping(scene)
        var warnings: [ExportWarning] = []
        if map.scaled { warnings.append(.coordinatesScaled) }

        var embeddedEMF: Data?
        if options.embedEMFInWMF {
            // The CURRENT edited scene's EMF/dual export, not the stale source.
            embeddedEMF = (try? export(scene, as: .emf)).map(\.data)
        }
        let builder = WMFDocumentBuilder(boundingBox: map.bb, unitsPerInch: map.inch, embeddedEMF: embeddedEMF)

        // Observe the source once if any element must be rasterised (passthrough,
        // non-Latin-1 or EMF+ text, a rotated image, or a gradient fill WMF cannot
        // express — item 6). The batched EMF+ page covers exactly those elements.
        let rasterSource = scene.elements.contains(where: shouldRasterizeForWMF)
            ? SceneRasterize.Source.make(scene, rasterize: shouldRasterizeForWMF) : nil

        for element in scene.elements where !element.hidden {
            guard element.kind != .group else { continue }
            if shouldRasterizeForWMF(element) {
                if let source = rasterSource,
                   let raster = SceneRasterize.raster(element, scene: scene, source: source),
                   let dib = SceneImageCoding.dib(from: raster.image) {
                    let destLogical = raster.deviceRect.applying(map.deviceToLogical)
                    let records = SceneSynthesis.wmfImageRecords(dib: dib, destLogical: destLogical, winOrg: map.winOrg, winExt: map.winExt)
                    for record in records { try builder.append(record) }
                    warnings.append(rasterWarning(for: element))
                } else {
                    warnings.append(.contentDropped(elementID: element.id))
                }
                continue
            }
            let mapped = mapElementToWMFLogical(element, map.deviceToLogical)
            // A fresh slot model per block (each block creates and deletes its own
            // objects), matching the builder's own lowest-free allocation.
            var table = SlotTable()
            let needs = SceneSynthesis.wmfSlotNeeds(for: mapped)
            let penSlot = needs.pen ? table.allocate() : 0
            let brushSlot = needs.brush ? table.allocate() : 0
            let fontSlot = needs.font ? table.allocate() : 0
            let records = SceneSynthesis.wmfBlock(
                for: mapped, winOrg: map.winOrg, winExt: map.winExt,
                penSlot: penSlot, brushSlot: brushSlot, fontSlot: fontSlot, emitDx: true,
                clip: wmfClipRect(mapped.clipDevice), warnings: &warnings)
            for record in records { try builder.append(record) }
        }
        return (try builder.finish(), warnings)
    }

    /// The device→WMF-logical mapping for a full EMF→WMF synthesis: anchor the page
    /// min corner at logical origin, scale by `s`, and derive the placeable
    /// BoundingBox/Inch and the block window so a WMF reader maps the logical coords
    /// back onto a device canvas the size of the EMF page.
    ///
    /// `s = limit / maxExtent` SUPERSAMPLES the integer-only WMF logical grid up to
    /// its Int16-safe maximum (slice E1b2d item 3): a device coordinate like 10.5
    /// — which the old 1:1 grid rounded to 11, shifting a thin cosmetic line by a
    /// whole pixel at render scale — now lands on a fine logical grid (~`s` units per
    /// device pixel) the viewport maps back with sub-pixel accuracy, so the WMF and
    /// the source EMF rasterise onto the SAME pixels. This was the real cause of the
    /// 1–2% vector-fixture residual and the ~48% thin-line outlier (idx 216): integer
    /// rounding of sub-pixel device coordinates, NOT any systematic offset. The scale
    /// is Int16-safe because every drawn quantity (geometry, pen width, font height,
    /// Dx) fits within the page extent, and `maxExtent ≥ page`, so each `× s ≤ limit`;
    /// `SceneNumeric` saturates the absurd font-larger-than-the-page case. When the
    /// drawing already overflows Int16 (`maxExtent > limit`) `s < 1` DOWNSCALES, the
    /// lossy case that keeps the `coordinatesScaled` warning.
    private static func wmfLogicalMapping(_ scene: Scene)
        -> (deviceToLogical: CGAffineTransform, bb: WMFRect16, inch: UInt16, winOrg: PointL, winExt: SizeL, scaled: Bool) {
        let page = scene.pageBoundsDevice
        let anchorX = page.minX.isFinite ? page.minX : 0
        let anchorY = page.minY.isFinite ? page.minY : 0
        let w = max(1, page.width.isFinite ? page.width : 1)
        let h = max(1, page.height.isFinite ? page.height : 1)

        // The coordinate magnitude the records must hold, relative to the anchor.
        // Use each element's UNCLIPPED device extent (the synthesis emits geometry
        // before the clip), so a shape extending far outside a small clip is still
        // scaled to fit — `boundsDevice` is clip-intersected and would under-measure.
        var maxExtent = max(w, h)
        for element in scene.elements where !element.hidden && element.kind != .group {
            var box = element.geometryDevice.boundingBox
            if let image = element.image {
                box = box.isNull ? image.destRectDevice : box.union(image.destRectDevice)
            }
            if let text = element.text {
                let ref = CGPoint(x: text.referenceLogical.x, y: text.referenceLogical.y).applying(element.transform)
                if ref.x.isFinite, ref.y.isFinite {
                    box = box.isNull ? CGRect(origin: ref, size: .zero) : box.union(CGRect(origin: ref, size: .zero))
                }
            }
            guard !box.isNull else { continue }
            for v in [abs(box.minX - anchorX), abs(box.maxX - anchorX), abs(box.minY - anchorY), abs(box.maxY - anchorY)]
            where v.isFinite { maxExtent = max(maxExtent, v) }
        }
        // 30000 leaves headroom under Int16's 32767 for pen widths and rounding.
        // Supersample the logical grid up to that limit by an INTEGER factor `k` so
        // sub-pixel device coordinates survive integer rounding. An integer factor
        // keeps the WMF reader's canvas derivation EXACT — bb = k·page, inch = 96·k,
        // and the reader's `round(bb / inch · 96)` = `round(page)` with the k
        // cancelling, so the WMF canvas equals the EMF page to the pixel (a fractional
        // factor's bb/inch double-rounding could shift it by one, breaking a detailed
        // file's size match). `k` is capped so `inch = 96·k` stays within the UInt16
        // Inch field (k ≤ 682) — an uncapped k on a tiny page overflowed Inch and
        // corrupted the derived canvas. A lower cap of 15 (Inch ≤ 1440, the DPI common
        // WMF readers favour) was measured and REJECTED: it lost real fidelity on the
        // committed fixtures (gate-p4-text 0.323%→1.091%, over the 0.5% budget;
        // gate-p3-shapes 0.000%→0.140%; gate-p4-image 0.000%→0.118%), because small
        // text/detail pages need a fine logical grid to keep baselines on-pixel. The
        // placeable BoundingBox/Inch keep the physical size k-invariant for a correct
        // reader (verified in LibreOffice), so the larger Inch is interop-safe here.
        // When the page itself overflows Int16 (k < 1) fall back to a fractional
        // downscale `s < 1`, the lossy `coordinatesScaled` case.
        let limit = 30_000.0
        let kMax = 65_535.0 / 96   // 682: keeps inch = 96·k within the UInt16 Inch field
        let kFloor = (maxExtent.isFinite && maxExtent > 0) ? floor(limit / maxExtent) : 1
        let s = kFloor >= 1 ? min(kFloor, kMax.rounded(.down))
            : (maxExtent.isFinite && maxExtent > 0 ? limit / maxExtent : 1.0)

        let deviceToLogical = CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: -anchorX * s, ty: -anchorY * s)
        let bbW = max(1, Int((w * s).rounded()))
        let bbH = max(1, Int((h * s).rounded()))
        let bb = WMFRect16(left: 0, top: 0, right: Int16(clamping: bbW), bottom: Int16(clamping: bbH))
        let inch = UInt16(clamping: max(1, Int((s * 96).rounded())))
        return (deviceToLogical, bb, inch,
                PointL(x: 0, y: 0), SizeL(cx: Int32(bbW), cy: Int32(bbH)), s < 1)
    }

    /// A copy of `element` mapped into WMF-logical space: geometry and image
    /// destination go through `deviceToLogical`; the element transform is
    /// post-composed with it, so the synthesis (which reads the transform for pen
    /// width, font height and the text reference) produces logical records at
    /// logical sizes. The text reference point stays in its pre-transform space —
    /// the composed transform now carries it to WMF-logical.
    /// The INTERSECTCLIPRECT bounds (WMF-logical) for an element's clip, or nil when
    /// it has none. The clip's bounding box is exact for the common axis-aligned rect
    /// clip; for a non-rect clip it bounds the draw to the clip's extent (a strict
    /// improvement over drawing the full unclipped geometry).
    private static func wmfClipRect(_ clip: ScenePath?) -> RectL? {
        guard let clip, !clip.isEmpty else { return nil }
        let b = clip.boundingBox
        guard !b.isNull, b.width.isFinite, b.height.isFinite else { return nil }
        // Clamp to the Int16-safe WMF coordinate range (`wmfLogicalMapping` keeps the
        // geometry under 30000): an EMF+ "reset clip" is a huge sentinel rect (±10^7)
        // that never clips the in-range geometry, so clamping it is a no-op clip and
        // avoids a `coordinateOutOfRange` write failure ([MS-WMF] §2.2.2.15/.16).
        func clamp(_ v: Double) -> Int32 { Int32(max(-30000, min(30000, v.rounded()))) }
        let left = clamp(b.minX), top = clamp(b.minY), right = clamp(b.maxX), bottom = clamp(b.maxY)
        guard right > left, bottom > top else { return nil }
        return RectL(left: left, top: top, right: right, bottom: bottom)
    }

    private static func mapElementToWMFLogical(_ element: Element, _ deviceToLogical: CGAffineTransform) -> Element {
        var mapped = element
        mapped.geometryDevice = element.geometryDevice.applying(deviceToLogical)
        mapped.transform = element.transform.concatenating(deviceToLogical)
        if let clip = element.clipDevice { mapped.clipDevice = clip.applying(deviceToLogical) }
        if var image = mapped.image {
            image.destRectDevice = image.destRectDevice.applying(deviceToLogical).standardized
            if let corners = image.destCornersDevice {
                image.destCornersDevice = corners.map { $0.applying(deviceToLogical) }
            }
            mapped.image = image
        }
        return mapped
    }

    // MARK: - Cross-container: WMF scene → EMF (full synthesis, slice E1b2c)

    /// Writes a WMF (or WMZ) scene to an EMF by full synthesis. The lossless route
    /// wins when the source WMF embeds a current, parseable EMF (no edits): that EMF
    /// is re-emitted directly. Otherwise every visible element is synthesised into a
    /// from-scratch EMF (device-space blocks, an EMR_HEADER whose bounds/frame come
    /// from the scene page). An edited/new element that needs opacity or a gradient
    /// upgrades the output to a dual EMF+ file by reusing E1b2b's GDI→dual overlay
    /// over the synthesised GDI EMF.
    private static func exportWMFSceneAsEMF(_ scene: Scene, options: ExportOptions) throws -> (Data, [ExportWarning]) {
        if !isEdited(scene), let emf = losslessEmbeddedEMF(scene) {
            return (try EMFDocumentWriter.reEmit(try EMFFile.parse(emf), source: emf), [])
        }
        let (gdiData, warnings, indexMap) = try synthesizeGDIEMF(scene)
        // forceGDIOnly keeps the flat GDI EMF (opacity/gradient flattened with a
        // report); otherwise an edit needing opacity or a gradient upgrades to dual.
        guard !options.forceGDIOnly, needsEMFPlus(scene) else { return (gdiData, warnings) }
        let file = try EMFFile.parse(gdiData)
        let synthetic = makeSyntheticEMFScene(scene, file: file, indexMap: indexMap, source: gdiData)
        return try overlayGDIAsDual(file, synthetic, source: gdiData)
    }

    /// The source WMF's embedded EMF ([MS-WMF] §2.3.6.25), when it reassembles into
    /// a parseable EMF; nil otherwise. Used for the lossless WMF→EMF route.
    private static func losslessEmbeddedEMF(_ scene: Scene) -> Data? {
        guard scene.source.format == .wmf || scene.source.format == .placeableWMF,
              let wmf = try? WMFFile.parse(scene.source.data),
              case .reassembled(let emf) = WMFEmbeddedEMF.reassemble(wmf),
              (try? EMFFile.parse(emf)) != nil
        else { return nil }
        return emf
    }

    /// Synthesises a from-scratch GDI EMF from `scene` (every visible element a
    /// self-contained device-space block), returning the bytes, the fidelity
    /// warnings, and a map from element id to the 1-based record indices its block
    /// occupies (for the dual upgrade's synthetic provenance).
    private static func synthesizeGDIEMF(_ scene: Scene) throws -> (Data, [ExportWarning], [Int: [Int]]) {
        let metrics = wmfSceneEMFMetrics(scene.pageBoundsDevice)
        let builder = EMFDocumentBuilder(bounds: metrics.bounds, frame: metrics.frame,
                                         device: metrics.device, millimeters: metrics.millimeters)
        var warnings: [ExportWarning] = []
        var indexMap: [Int: [Int]] = [:]
        var cursor = 1   // record 0 is the EMR_HEADER
        let rasterSource = scene.elements.contains(where: shouldRasterize) ? SceneRasterize.Source.make(scene) : nil
        for element in scene.elements where !element.hidden {
            guard element.kind != .group else { continue }
            if shouldRasterize(element) {
                if let source = rasterSource,
                   let raster = SceneRasterize.raster(element, scene: scene, source: source),
                   let dib = SceneImageCoding.dib(from: raster.image) {
                    let payloads = SceneSynthesis.emfImageRecords(dib: dib, destDevice: raster.deviceRect)
                    var indices: [Int] = []
                    for payload in payloads { try builder.append(payload); indices.append(cursor); cursor += 1 }
                    indexMap[element.id] = indices
                    warnings.append(rasterWarning(for: element))
                } else {
                    warnings.append(.contentDropped(elementID: element.id))
                }
                continue
            }
            var blockWarnings: [ExportWarning] = []
            let payloads = SceneSynthesis.emfBlock(for: element, baseHandle: 1, warnings: &blockWarnings)
            guard !payloads.isEmpty else { continue }
            var indices: [Int] = []
            for payload in payloads { try builder.append(payload); indices.append(cursor); cursor += 1 }
            indexMap[element.id] = indices
            warnings.append(contentsOf: blockWarnings)
        }
        return (try builder.finish(), warnings, indexMap)
    }

    /// A synthetic EMF scene over the freshly synthesised GDI EMF: each element
    /// keeps its original style (so an alpha/gradient edit still drives the EMF+
    /// block) but takes provenance into its synthesised records, marked `edited`
    /// exactly when it needs EMF+. Fed to `overlayGDIAsDual` so the alpha/gradient
    /// elements become EMF+ blocks and the rest replay their GDI records in GetDC.
    private static func makeSyntheticEMFScene(_ original: Scene, file: EMFFile, indexMap: [Int: [Int]], source: Data) -> Scene {
        var elements: [Element] = []
        var drawing = Set<Int>()
        for element in original.elements where !element.hidden {
            guard let indices = indexMap[element.id], !indices.isEmpty else { continue }
            var copy = element
            copy.provenance = Provenance(sourceRecordIndices: indices, edited: elementNeedsEMFPlus(element))
            elements.append(copy)
            drawing.formUnion(indices)
        }
        var structural = Set<Int>([0])
        let last = file.records.count - 1
        if last > 0 { structural.insert(last) }
        let partition = ScenePartition(structural: structural, state: [], drawing: drawing,
                                       passthrough: [], fallback: [], unitCount: file.records.count)
        let src = SceneSource(data: source, format: .emf, wasCompressed: false,
                              renderPath: .gdi, unitCount: file.records.count)
        return Scene(pageBoundsDevice: original.pageBoundsDevice,
                     layers: [Layer(id: 0, name: "synth", elements: elements)],
                     partition: partition, source: src)
    }

    /// The EMR_HEADER metrics for a WMF→EMF synthesis: bounds from the scene device
    /// page (inclusive), and the physical frame / reference millimetres at 96 DPI —
    /// the DPI a WMF device canvas is built at (WMFTranslator), so the physical size
    /// matches the source WMF's placeable DPI ([MS-EMF] §2.2.9, [MS-WMF] §2.3.2.3).
    private static func wmfSceneEMFMetrics(_ page: CGRect) -> (bounds: RectL, frame: RectL, device: SizeL, millimeters: SizeL) {
        let ox = SceneNumeric.int32(page.minX)
        let oy = SceneNumeric.int32(page.minY)
        let w = max(1, SceneNumeric.int32(page.width))
        let h = max(1, SceneNumeric.int32(page.height))
        let bounds = RectL(left: ox, top: oy, right: ox &+ w &- 1, bottom: oy &+ h &- 1)
        let frame = RectL(left: 0, top: 0,
                          right: SceneNumeric.int32(Double(w) * 2540.0 / 96.0),
                          bottom: SceneNumeric.int32(Double(h) * 2540.0 / 96.0))
        let device = SizeL(cx: w, cy: h)
        let millimeters = SizeL(cx: SceneNumeric.int32(Double(w) * 25.4 / 96.0),
                                cy: SceneNumeric.int32(Double(h) * 25.4 / 96.0))
        return (bounds, frame, device, millimeters)
    }

    // MARK: - Change detection

    /// A scene is edited when any element is marked edited, a new element was
    /// inserted (no provenance), or a source content record is no longer owned
    /// by any element (a deletion).
    static func isEdited(_ scene: Scene) -> Bool {
        var covered = Set<Int>()
        for element in scene.elements {
            if element.provenance.edited { return true }
            if element.provenance.sourceRecordIndices.isEmpty { return true }   // new
            covered.formUnion(element.provenance.sourceRecordIndices)
        }
        let content = scene.partition.drawing.union(scene.partition.passthrough)
        return covered != content
    }

    // MARK: - Unchanged: re-emit verbatim (E0)

    private static func reEmitUnchanged(_ scene: Scene) throws(SceneExportError) -> Data {
        switch scene.source.format {
        case .emf:
            let file: EMFFile
            do { file = try EMFFile.parse(scene.source.data) } catch { throw .unreadableSource }
            do { return try EMFDocumentWriter.reEmit(file, source: scene.source.data) }
            catch { throw .emfWriteFailed(error) }
        case .wmf, .placeableWMF:
            let file: WMFFile
            do { file = try WMFFile.parse(scene.source.data) } catch { throw .unreadableSource }
            do { return try WMFDocumentWriter.reEmit(file, source: scene.source.data) }
            catch { throw .wmfWriteFailed(error) }
        }
    }

    // MARK: - Edited GDI EMF: lossless overlay (original header preserved)

    /// The EMF overlay: every unedited record is kept byte-verbatim; an edited
    /// element's records are replaced in place by a synthesised kind-matched
    /// block; new elements are inserted at their z-position. The ORIGINAL header
    /// is preserved (only Bytes/Records/Handles patched, like `reEmit`), so
    /// pixel-format and extension fields survive.
    private static func overlayEMF(_ file: EMFFile, _ scene: Scene, source: Data) throws(EMFWriteError) -> (Data, [ExportWarning]) {
        guard !file.records.isEmpty else { throw .sourceRecordOutOfBounds(recordOffset: 0, recordSize: 0) }
        let bytes = [UInt8](source)
        var headerBytes = try rawOrThrow(bytes, file.records[0])

        var ownerByIndex: [Int: Element] = [:]
        for element in scene.elements where !element.provenance.sourceRecordIndices.isEmpty {
            for index in element.provenance.sourceRecordIndices { ownerByIndex[index] = element }
        }
        let content = scene.partition.drawing.union(scene.partition.passthrough)
        let firstContent = content.min()
        let baseHandle = maxTableIndex(file.records, bytes) + 1
        let insertions = planInsertions(scene)

        var body: [[UInt8]] = []
        var warnings: [ExportWarning] = []
        // Emfy layer markers (E3d): fresh begin/end markers bracket each layer's
        // emitted drawing content, in z-order. No-op for a trivial single layer,
        // so existing exports stay byte-identical.
        var markers = LayerMarkerEmitter(scene)

        // Mirror reEmit: re-emit every record[1…] (the EOF keeps its position);
        // drop deleted elements, replace edited ones, insert new ones at z.
        // A contentless source (a blank document: header + EOF only) has no
        // first-content anchor, so the new elements insert right BEFORE the EOF —
        // never after the terminator, which would make the parser stop short of
        // them (E3a new-document path).
        var startInserted = false
        for i in 1 ..< file.records.count {
            // Drop the source's OWN Emfy layer markers — fresh ones are injected
            // around the current layer structure, so a re-save never duplicates them.
            if scene.layerMarkerIndices.contains(i) { continue }
            let record = file.records[i]
            if i == firstContent || (firstContent == nil && !startInserted && record.type == eofType) {
                try appendEMFBlocks(insertions.atStart, baseHandle, &body, &warnings, &markers)
                startInserted = true
            }

            if content.contains(i) {
                if let owner = ownerByIndex[i] {
                    if owner.provenance.edited {
                        if i == owner.provenance.sourceRecordIndices.max() {
                            try appendEMFBlocks([owner], baseHandle, &body, &warnings, &markers)
                        }
                    } else {
                        markers.enter(owner, into: &body)
                        body.append(try rawOrThrow(bytes, record))
                    }
                }   // deleted → drop
            } else {
                if record.type == eofType { markers.close(into: &body) }   // close markers before the terminator
                body.append(try rawOrThrow(bytes, record))   // structural / state / EOF
            }
            if let after = insertions.afterRecord[i] { try appendEMFBlocks(after, baseHandle, &body, &warnings, &markers) }
        }
        // A contentless source with no EOF record at all: insert before the
        // canonical EOF the guarantee below appends.
        if firstContent == nil, !startInserted { try appendEMFBlocks(insertions.atStart, baseHandle, &body, &warnings, &markers) }
        markers.close(into: &body)   // idempotent: closes any still-open markers before the EOF guarantee

        // Guarantee a terminating EMR_EOF. The lossless overlay keeps the source's
        // own EOF record in place (it is structural, re-emitted verbatim above), but
        // some real-world files are malformed and carry no EOF at all — an edited
        // file we rewrite must still be well-formed, exactly as the WMF overlay
        // always appends its META_EOF. (Unchanged exports go through reEmit and are
        // left byte-identical, EOF or not.)
        if file.records.last?.type != eofType { body.append(canonicalEMFEOF) }

        let bodyTotal = body.reduce(0) { $0 + $1.count }
        let totalBytes = headerBytes.count + bodyTotal
        guard totalBytes <= Int(UInt32.max) else { throw .fileTooLarge(byteLength: totalBytes) }
        let recordCount = UInt32(clamping: 1 + body.count)
        let computedHandles = try handleCount(body)
        let handles = max(file.header.handles, computedHandles)

        patchU32(&headerBytes, 48, UInt32(totalBytes))
        patchU32(&headerBytes, 52, recordCount)
        patchU16(&headerBytes, 56, handles)

        var out = [UInt8]()
        out.reserveCapacity(totalBytes)
        out.append(contentsOf: headerBytes)
        for chunk in body { out.append(contentsOf: chunk) }
        return (Data(out), warnings)
    }

    private static func appendEMFBlocks(_ elements: [Element], _ baseHandle: UInt32, _ body: inout [[UInt8]], _ warnings: inout [ExportWarning], _ markers: inout LayerMarkerEmitter) throws(EMFWriteError) {
        for element in elements where !element.hidden {
            markers.enter(element, into: &body)
            for payload in SceneSynthesis.emfBlock(for: element, baseHandle: baseHandle, warnings: &warnings) {
                body.append([UInt8](try EMFRecordEncoder.encode(payload)))
            }
        }
    }

    /// Interleaves Emfy layer-begin/end markers (`EMFLayerMarker`) into the overlay
    /// body as drawing content is emitted, so each layer's records sit between its
    /// own markers in z-order (E3d, design §1). Active only when the scene carries a
    /// non-trivial layer structure; otherwise every call is a no-op and the overlay
    /// output is byte-identical to the pre-E3d path, so the existing suite is
    /// unaffected. Empty layers (leading, trailing, or between populated ones) still
    /// get a begin/end pair, so an empty layer round-trips too.
    ///
    /// This assumes the overlay emits drawing content in the scene's layer (z) order
    /// — true for new documents and ordinary edits. A file whose unedited source
    /// records are emitted out of layer order (a reordered, never-edited import) can
    /// produce non-contiguous markers; the layer names/attributes still round-trip.
    struct LayerMarkerEmitter {
        private let enabled: Bool
        private let layers: [Layer]
        private let layerOf: [Int: Int]
        private var lastLayer = -1
        private var closed = false

        init(_ scene: Scene) {
            enabled = scene.hasNonTrivialLayers
            layers = scene.layers
            var map: [Int: Int] = [:]
            for (order, layer) in scene.layers.enumerated() {
                for element in layer.elements { map[element.id] = order }
            }
            layerOf = map
        }

        private func beginMarker(_ order: Int, into body: inout [[UInt8]]) {
            let layer = layers[order]
            body.append(EMFLayerMarker.begin(name: layer.name, hidden: layer.hidden, locked: layer.locked))
        }

        /// Opens the marker for `element`'s layer before its records are appended,
        /// closing the previous layer and emitting any skipped empty layers first.
        mutating func enter(_ element: Element, into body: inout [[UInt8]]) {
            guard enabled, let target = layerOf[element.id], target != lastLayer, target >= 0 else { return }
            if lastLayer >= 0 { body.append(EMFLayerMarker.end()) }
            var k = max(0, lastLayer + 1)
            while k < target { beginMarker(k, into: &body); body.append(EMFLayerMarker.end()); k += 1 }
            beginMarker(target, into: &body)
            lastLayer = target
        }

        /// Closes the open layer and emits a begin/end pair for every trailing empty
        /// layer. Idempotent — safe to call before the EOF and again at the tail.
        mutating func close(into body: inout [[UInt8]]) {
            guard enabled, !closed else { return }
            closed = true
            if lastLayer >= 0 { body.append(EMFLayerMarker.end()) }
            var k = max(0, lastLayer + 1)
            while k < layers.count { beginMarker(k, into: &body); body.append(EMFLayerMarker.end()); k += 1 }
            lastLayer = layers.count
        }
    }

    // MARK: - GDI → dual: an edit needs opacity or a gradient (slice E1b2b)

    /// Upgrades an edited GDI-only EMF to a DUAL EMF+ file so an edit GDI cannot
    /// express — sub-1 opacity or a gradient — is carried faithfully
    /// ([MS-EMFPLUS] §1.3.1). The output is one EMF container:
    ///
    /// - the ORIGINAL header, patched (Bytes/Records/Handles) like `overlayEMF`;
    /// - an EmfPlusHeader comment with the Dual flag (§2.3.3.3), opening the EMF+
    ///   stream;
    /// - the EMF+ half. Every UNEDITED element's original GDI records play verbatim
    ///   inside an EmfPlusGetDC window (§2.3.3.2, §1.3.1), so an EMF+ reader draws
    ///   them pixel-for-pixel — the "original GDI as fallback" and "lossless EMF+
    ///   replay" collapse into the SAME records. Each EDITED/new element is a
    ///   synthesised EmfPlusSave…Restore block (`SceneEMFPlusSynthesis`, identity
    ///   world, 1:1-pixel page) emitted AT its z-position; a non-GetDC EMF+ record
    ///   closes the preceding window, so the block draws in z-order.
    /// - the GDI half. Each edited/new element's best GDI approximation
    ///   (`SceneSynthesis`, the opaque/flattened draw) is emitted OUTSIDE any GetDC
    ///   window right after its EMF+ block — an EMF+ reader skips it (window closed),
    ///   a GDI-only reader draws it. Unedited GDI records (shared with the EMF+ half)
    ///   provide the rest, so a GDI reader never draws an element twice and an EMF+
    ///   reader never draws the GDI approximation.
    ///
    /// The edit is carried faithfully, so NO `opacityDropped`/`gradientFlattened`
    /// warning is raised (the GDI approximation's own such warnings are discarded);
    /// genuine synthesis limitations (kindFallback, imageDropped, a degenerate
    /// gradient) still surface from the EMF+ block.
    private static func overlayGDIAsDual(_ file: EMFFile, _ scene: Scene, source: Data) throws -> (Data, [ExportWarning]) {
        guard !file.records.isEmpty else { throw SceneExportError.unreadableSource }
        let bytes = [UInt8](source)
        var headerBytes = try rawOrThrow(bytes, file.records[0])

        var ownerByIndex: [Int: Element] = [:]
        for element in scene.elements where !element.provenance.sourceRecordIndices.isEmpty {
            for index in element.provenance.sourceRecordIndices { ownerByIndex[index] = element }
        }
        let content = scene.partition.drawing.union(scene.partition.passthrough)
        let firstContent = content.min()
        let baseHandle = maxTableIndex(file.records, bytes) + 1
        let insertions = planInsertions(scene)

        var warnings: [ExportWarning] = []
        var body: [[UInt8]] = []
        // The pending run of framed EMF+ record bytes awaiting a comment flush, and
        // whether a GetDC window is logically open for the GDI records that follow.
        var plusRun: [UInt8] = []
        var windowOpen = false
        var saveIndex: UInt32 = 0x7F00_0000

        func flushPlus() {
            guard !plusRun.isEmpty else { return }
            body.append(contentsOf: splitRecords(EMFPlusCommentWriter.packComments(streamBytes: plusRun)))
            plusRun.removeAll(keepingCapacity: true)
        }
        /// Appends one verbatim GDI record, physically AFTER the pending EMF+ comment
        /// (flushed first), so a reader sees it inside the window the comment opened.
        func emitGDIRaw(_ raw: [UInt8]) {
            flushPlus()
            body.append(raw)
        }
        /// Ensures a GetDC window is open for the verbatim GDI records that follow.
        func openWindow() {
            if !windowOpen {
                plusRun.append(contentsOf: EMFPlusRecordPayload.getDC.framed())
                windowOpen = true
            }
        }
        /// The EMF+ synthesis of an edited/new element (a Save…Restore block whose
        /// objects take free slots 0…63; each block is self-contained so slots reset).
        func emitPlusSynth(_ element: Element) {
            var nextSlot: UInt8 = 0
            func allocate() -> UInt8? { guard nextSlot < 64 else { return nil }; let s = nextSlot; nextSlot &+= 1; return s }
            let idx = saveIndex; saveIndex &+= 1
            guard let emits = SceneEMFPlusSynthesis.block(for: element, saveIndex: idx, allocate: allocate, warnings: &warnings) else { return }
            for emit in emits {
                switch emit {
                case .record(let payload):
                    plusRun.append(contentsOf: payload.framed())
                case .object(let id, let type, let value):
                    guard let payload = try? EMFPlusObjectEncoder.encode(value) else { continue }
                    for rec in EMFPlusCommentWriter.objectRecords(objectID: id, objectType: type, payload: payload) {
                        plusRun.append(contentsOf: rec)
                    }
                }
            }
        }
        /// Emits an edited/new element: its EMF+ block (closes the window), then its
        /// GDI approximation OUTSIDE the window (an EMF+ reader skips it).
        func emitEdited(_ element: Element) throws(EMFWriteError) {
            guard !element.hidden else { return }
            emitPlusSynth(element)
            windowOpen = false       // a non-GetDC EMF+ record closes the window in the reader
            flushPlus()              // close the comment so the GDI approximation sits outside it
            var dropped: [ExportWarning] = []
            for payload in SceneSynthesis.emfBlock(for: element, baseHandle: baseHandle, warnings: &dropped) {
                body.append([UInt8](try EMFRecordEncoder.encode(payload)))
            }
        }

        // The EMF+ stream opens with the Dual header (§2.3.3.3). DPI is 96 — only
        // physical-unit EMF+ fonts use it, and GDI-origin text is sized in world
        // units (scaled by the re-established world transform), so 96 never applies.
        plusRun.append(contentsOf: EMFPlusRecordPayload
            .header(dual: true, videoDisplay: true, logicalDpiX: 96, logicalDpiY: 96).framed())

        // Mirror `overlayEMF`'s walk: every record[1…] except EOF; verbatim unedited
        // content/state inside a GetDC window; an edited element replaced in place by
        // its dual block; new elements inserted at z; deleted elements dropped. The
        // source's OWN EMF+ comments are dropped — a GDI-rendered dual file (its EMF+
        // stream is just header/GetDC/state/EndOfFile around GDI draws) is rebuilt
        // with our fresh EMF+ stream, so we never duplicate the header or EndOfFile.
        for i in 1 ..< file.records.count {
            let record = file.records[i]
            if record.type == eofType { continue }   // EOF appended last, after EndOfFile
            let isSourcePlusComment = record.type == emrCommentType && isEMFPlusComment(bytes, record)
            if i == firstContent {
                for element in insertions.atStart { try emitEdited(element) }
            }
            if isSourcePlusComment {
                // Replaced by our EMF+ stream — drop it (its GDI draws are re-wrapped).
            } else if content.contains(i) {
                if let owner = ownerByIndex[i] {
                    if owner.provenance.edited {
                        if i == owner.provenance.sourceRecordIndices.max() { try emitEdited(owner) }
                    } else {
                        openWindow()
                        emitGDIRaw(try rawOrThrow(bytes, record))
                    }
                }   // content with no owner → deleted → drop
            } else {
                openWindow()
                emitGDIRaw(try rawOrThrow(bytes, record))   // structural (non-EOF) / state / non-EMF+ comment
            }
            if let after = insertions.afterRecord[i] { for element in after { try emitEdited(element) } }
        }
        if firstContent == nil { for element in insertions.atStart { try emitEdited(element) } }

        // Close the EMF+ stream (§2.3.3.1), then the terminating EMR_EOF.
        plusRun.append(contentsOf: EMFPlusRecordPayload.endOfFile.framed())
        flushPlus()
        if let last = file.records.last, last.type == eofType {
            body.append(try rawOrThrow(bytes, last))
        } else {
            body.append(canonicalEMFEOF)
        }

        let bodyTotal = body.reduce(0) { $0 + $1.count }
        let totalBytes = headerBytes.count + bodyTotal
        guard totalBytes <= Int(UInt32.max) else { throw EMFWriteError.fileTooLarge(byteLength: totalBytes) }
        let recordCount = UInt32(clamping: 1 + body.count)
        let handles = max(file.header.handles, try handleCount(body))
        patchU32(&headerBytes, 48, UInt32(totalBytes))
        patchU32(&headerBytes, 52, recordCount)
        patchU16(&headerBytes, 56, handles)

        var out = [UInt8]()
        out.reserveCapacity(totalBytes)
        out.append(contentsOf: headerBytes)
        for chunk in body { out.append(contentsOf: chunk) }
        return (Data(out), warnings)
    }

    // MARK: - Edited EMF+ (and dual): EMF+ overlay (slice E1b2a)

    /// The EMF+ overlay. The EMF+ record stream is rebuilt: unedited records
    /// (object/state/control and the drawing records of unedited elements) are
    /// kept verbatim; a deleted element's drawing record is dropped; an edited
    /// element's record is replaced in place by a synthesised EmfPlusSave…Restore
    /// block (identity world, 1:1-pixel page) whose objects take free slots, each
    /// reused slot's prior definition re-emitted after the block (slot restore);
    /// new elements insert at their z-position. The stream is re-packed into the
    /// EMR_COMMENT_EMFPLUS carriers at the positions of the originals; GDI records
    /// stay in place. In a DUAL file an edited GDI element inside a GetDC window is
    /// replaced in place by a GDI block, and every edited/new element also gets a
    /// fresh GDI block right after its EMF+ comment (outside GetDC, so EMF+ readers
    /// skip it); the original GDI fallback is kept with a `fallbackMayBeStale`
    /// warning ([MS-EMFPLUS] §1.3.1, §2.3.3/§2.3.5/§2.3.7).
    private static func overlayEMFPlus(_ file: EMFFile, _ scene: Scene, source: Data) throws -> (Data, [ExportWarning]) {
        guard !file.records.isEmpty else { throw SceneExportError.unreadableSource }
        let bytes = [UInt8](source)
        let plusStream = file.emfPlusStream()
        let isDual = plusStream.header?.isDual ?? false

        // Re-observe: the lifted entries are 1:1 with the ORIGINAL import, so entry
        // index == element id. Maps each original element to its EMF+ stream drawing
        // record (`.plus`) or its GetDC-window GDI record(s) (`.gdi`).
        guard let opened = try? OpenedMetafile.open(source),
              let prepared = MetafileRenderer.prepare(opened) else { throw SceneExportError.unreadableSource }
        let entries = MetafileRenderer.observe(prepared).plusEntries
        var streamIndexToID: [Int: Int] = [:]
        var gdiRecordToID: [Int: Int] = [:]
        for (id, entry) in entries.enumerated() {
            switch entry {
            case .plus(let op): streamIndexToID[op.streamIndex] = id
            case .gdi(let op): for r in op.recordIndices { gdiRecordToID[r] = id }
            }
        }
        var presentByID: [Int: Element] = [:]
        for element in scene.elements where !element.provenance.sourceRecordIndices.isEmpty {
            presentByID[element.id] = element
        }
        let insertions = planPlusInsertions(scene, entries: entries)
        let baseHandle = maxTableIndex(file.records, bytes) + 1

        var warnings: [ExportWarning] = []
        var changed = false
        var defs = PlusObjectDefs()
        var saveIndex: UInt32 = 0x7F00_0000
        var streamByComment: [Int: [UInt8]] = [:]
        var fallbackByComment: [Int: [[UInt8]]] = [:]
        var editedOrDeletedComments: Set<Int> = []
        let sourceComments = Set(plusStream.records.map(\.sourceRecordIndex))
        let sortedComments = sourceComments.sorted()

        func emitSynth(_ element: Element, comment: Int) {
            guard !element.hidden else { return }
            defs.flush()
            let defined = defs.definedSlots
            let order = (0 ... 63).map { UInt8($0) }.sorted { a, b in
                let da = defined.contains(a), db = defined.contains(b)
                return da != db ? !da : a < b    // undefined slots first (no restore)
            }
            var cursor = 0
            var reused: [UInt8] = []
            func allocate() -> UInt8? {
                guard cursor < order.count else { return nil }
                let slot = order[cursor]; cursor += 1
                if defined.contains(slot) { reused.append(slot) }
                return slot
            }
            let idx = saveIndex; saveIndex &+= 1
            guard let emits = SceneEMFPlusSynthesis.block(for: element, saveIndex: idx, allocate: allocate, warnings: &warnings) else { return }
            var framed: [UInt8] = []
            for emit in emits {
                switch emit {
                case .record(let payload):
                    framed.append(contentsOf: payload.framed())
                case .object(let id, let type, let value):
                    guard let payload = try? EMFPlusObjectEncoder.encode(value) else { continue }
                    for rec in EMFPlusCommentWriter.objectRecords(objectID: id, objectType: type, payload: payload) {
                        framed.append(contentsOf: rec)
                    }
                }
            }
            for slot in reused { for chunk in defs.definition(of: slot) { framed.append(contentsOf: chunk) } }
            streamByComment[comment, default: []].append(contentsOf: framed)
            if isDual {
                var dropped: [ExportWarning] = []
                var chunks: [[UInt8]] = []
                for payload in SceneSynthesis.emfBlock(for: element, baseHandle: baseHandle, warnings: &dropped) {
                    if let encoded = try? EMFRecordEncoder.encode(payload) { chunks.append([UInt8](encoded)) }
                }
                fallbackByComment[comment, default: []].append(contentsOf: chunks)
            }
        }

        // Pass 1: rebuild the EMF+ record stream, grouped by source comment.
        let firstDraw = streamIndexToID.keys.min()
        for streamIndex in plusStream.records.indices {
            let record = plusStream.records[streamIndex]
            let comment = record.sourceRecordIndex
            if streamIndex == firstDraw {
                for element in insertions.atStart { emitSynth(element, comment: comment); changed = true }
            }
            if let id = streamIndexToID[streamIndex] {
                if let element = presentByID[id] {
                    if element.provenance.edited {
                        emitSynth(element, comment: comment); changed = true
                        editedOrDeletedComments.insert(comment)
                    } else {
                        streamByComment[comment, default: []].append(contentsOf: EMFPlusCommentWriter.frame(record))
                    }
                } else {
                    changed = true   // deleted → drop its drawing record
                    editedOrDeletedComments.insert(comment)
                }
            } else {
                let framed = EMFPlusCommentWriter.frame(record)
                streamByComment[comment, default: []].append(contentsOf: framed)
                defs.feed(record: record, framed: framed)
            }
            if let news = insertions.afterStream[streamIndex] {
                for element in news { emitSynth(element, comment: comment); changed = true }
            }
        }
        if firstDraw == nil, !insertions.atStart.isEmpty {
            let comment = plusStream.records.first?.sourceRecordIndex ?? 1
            for element in insertions.atStart { emitSynth(element, comment: comment); changed = true }
        }
        // GetDC-window GDI elements are not EMF+ stream records, so pass 1 does not
        // see them: fold their edits/deletions into `changed` before deciding.
        for id in Set(gdiRecordToID.values) {
            if let element = presentByID[id] { if element.provenance.edited { changed = true } }
            else { changed = true }   // a deleted GetDC GDI element
        }
        // Pairing rule ([MS-EMFPLUS] §1.3.1): the GDI fallback run paired to an EMF+
        // element is the one sitting between that element's EMF+ comment and the next
        // EMF+ comment. For each EDITED/DELETED element, drop its paired fallback (so a
        // GDI-mode reader does not keep drawing the pre-edit version). Fallback that
        // sits between NO element's comment and the next is UNPAIRED — its relationship
        // to the edit can't be determined — so a `fallbackMayBeStale` warning is raised
        // when any survives, the honest account of a GDI copy the editor can't re-pair.
        func pairedRange(of comment: Int) -> Range<Int> {
            comment + 1 ..< (sortedComments.first { $0 > comment } ?? Int.max)
        }
        var removedFallback: Set<Int> = []
        var pairedFallback: Set<Int> = []
        if isDual {
            let elementComments = Set(streamIndexToID.keys.map { plusStream.records[$0].sourceRecordIndex })
            for comment in elementComments {
                let range = pairedRange(of: comment)
                pairedFallback.formUnion(scene.partition.fallback.filter { range.contains($0) })
            }
            for comment in editedOrDeletedComments {
                let range = pairedRange(of: comment)
                removedFallback.formUnion(scene.partition.fallback.filter { range.contains($0) })
            }
        }
        if isDual, changed, !scene.partition.fallback.subtracting(pairedFallback).isEmpty {
            warnings.append(.fallbackMayBeStale)
        }

        // Nothing actually changed (coverage-based `isEdited` routes every EMF+ scene
        // here to catch a delete): re-emit byte-identical, like an unchanged export.
        guard changed else { return (try EMFDocumentWriter.reEmit(file, source: source), []) }

        // Pass 2: assemble the EMF file (header + re-packed comments + GDI records + EOF).
        var headerBytes = try rawOrThrow(bytes, file.records[0])
        var body: [[UInt8]] = []
        for i in 1 ..< file.records.count {
            let record = file.records[i]
            if record.type == Self.emrCommentType {
                if sourceComments.contains(i) {
                    if let stream = streamByComment[i], !stream.isEmpty {
                        body.append(contentsOf: splitRecords(EMFPlusCommentWriter.packComments(streamBytes: stream)))
                    }
                    if let fb = fallbackByComment[i] { body.append(contentsOf: fb) }
                } else if isEMFPlusComment(bytes, record) {
                    // Continuation-only EMF+ comment: its record was re-framed whole at
                    // the comment its header started in — emit nothing here.
                } else {
                    body.append(try rawOrThrow(bytes, record))   // private (non-EMF+) comment
                }
            } else if let id = gdiRecordToID[i] {
                if let element = presentByID[id] {
                    if element.provenance.edited {
                        changed = true
                        // An edited GetDC-window GDI TEXT run re-emitted as integer
                        // EXTTEXTOUTW in device space quantises its baseline under the
                        // window's fractional world transform (slice E1b2e item 1). Draw
                        // it in place through a world-transform block instead, which the
                        // GetDC GDI engine renders exactly as the source did (no
                        // quantisation, alignment honoured); it stays ONE record, so an
                        // EMF+ reader and a GDI reader each draw exactly one copy. Non-text
                        // edits keep the device-space block — their vertices re-emit exactly.
                        let payloads = element.kind == .text
                            ? SceneSynthesis.emfTextBlockWorld(for: element, fontHandle: baseHandle, warnings: &warnings)
                            : SceneSynthesis.emfBlock(for: element, baseHandle: baseHandle, warnings: &warnings)
                        for payload in payloads {
                            body.append([UInt8](try EMFRecordEncoder.encode(payload)))
                        }
                    } else {
                        body.append(try rawOrThrow(bytes, record))
                    }
                }   // deleted GetDC GDI element → drop
            } else if removedFallback.contains(i) {
                // A GDI fallback record paired to an edited/deleted element → drop it,
                // so a GDI-mode reader does not keep drawing the pre-edit version.
            } else {
                body.append(try rawOrThrow(bytes, record))
            }
        }
        if file.records.last?.type != eofType { body.append(canonicalEMFEOF) }

        let bodyTotal = body.reduce(0) { $0 + $1.count }
        let totalBytes = headerBytes.count + bodyTotal
        guard totalBytes <= Int(UInt32.max) else { throw EMFWriteError.fileTooLarge(byteLength: totalBytes) }
        let recordCount = UInt32(clamping: 1 + body.count)
        let handles = max(file.header.handles, try handleCount(body))
        patchU32(&headerBytes, 48, UInt32(totalBytes))
        patchU32(&headerBytes, 52, recordCount)
        patchU16(&headerBytes, 56, handles)

        var out = [UInt8]()
        out.reserveCapacity(totalBytes)
        out.append(contentsOf: headerBytes)
        for chunk in body { out.append(contentsOf: chunk) }
        return (Data(out), warnings)
    }

    /// Splits a concatenation of EMR records (e.g. `packComments` output) into one
    /// chunk per record, reading each record's `nSize` at offset 4, so the header
    /// Records field counts every comment the overlay emits.
    private static func splitRecords(_ concatenated: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var offset = 0
        while offset + 8 <= concatenated.count {
            let size = Int(UInt32(concatenated[offset + 4]) | UInt32(concatenated[offset + 5]) << 8
                | UInt32(concatenated[offset + 6]) << 16 | UInt32(concatenated[offset + 7]) << 24)
            guard size >= 8, offset + size <= concatenated.count else { break }
            out.append(Array(concatenated[offset ..< offset + size]))
            offset += size
        }
        return out
    }

    /// Maps new (no-provenance) EMF+ elements to the EMF+ drawing stream record
    /// they insert after — the stream record of the previous `.plus` element in
    /// z-order (or the start of the drawing records for the bottom).
    private static func planPlusInsertions(_ scene: Scene, entries: [PlusEntry]) -> (atStart: [Element], afterStream: [Int: [Element]]) {
        var atStart: [Element] = []
        var afterStream: [Int: [Element]] = [:]
        var prev: Int?
        for element in scene.elements {
            if element.provenance.sourceRecordIndices.isEmpty {
                if let p = prev { afterStream[p, default: []].append(element) } else { atStart.append(element) }
            } else if element.id >= 0, element.id < entries.count, case .plus(let op) = entries[element.id] {
                prev = op.streamIndex
            }
        }
        return (atStart, afterStream)
    }

    /// True when `record` is an EMR_COMMENT whose 4-byte identifier is "EMF+"
    /// ([MS-EMF] §2.3.3.4), with a DataSize large enough to carry it.
    private static func isEMFPlusComment(_ bytes: [UInt8], _ record: EMFRawRecord) -> Bool {
        let base = record.offset
        guard record.size >= 16, base >= 0, base + 16 <= bytes.count else { return false }
        let dataSize = UInt32(bytes[base + 8]) | UInt32(bytes[base + 9]) << 8
            | UInt32(bytes[base + 10]) << 16 | UInt32(bytes[base + 11]) << 24
        guard dataSize >= 4 else { return false }
        let id = UInt32(bytes[base + 12]) | UInt32(bytes[base + 13]) << 8
            | UInt32(bytes[base + 14]) << 16 | UInt32(bytes[base + 15]) << 24
        return id == Self.emfPlusCommentIdentifier
    }

    // MARK: - Edited WMF

    private static func exportEditedWMF(_ scene: Scene) throws(SceneExportError) -> (Data, [ExportWarning]) {
        let wmf: WMFFile
        do { wmf = try WMFFile.parse(scene.source.data) } catch { throw .unreadableSource }
        do {
            if scene.source.renderPath == .gdi {
                return try overlayEmbeddedWMF(wmf, scene)
            }
            return try overlayWMF(wmf, scene)
        } catch let error as WMFWriteError {
            throw .wmfWriteFailed(error)
        } catch let error as EMFWriteError {
            throw .emfWriteFailed(error)
        } catch {
            throw .unreadableSource
        }
    }

    /// True WMF overlay (renderPath .wmf): element provenance maps through the
    /// translated program's per-payload source index back to source WMF records,
    /// so every unedited record is kept verbatim and an edited element is replaced
    /// in place by a block drawn in the file's own LOGICAL coordinate space (object
    /// slots modelled along the stream). Mirrors the EMF overlay.
    private static func overlayWMF(_ wmf: WMFFile, _ scene: Scene) throws -> (Data, [ExportWarning]) {
        let program = WMFTranslator.translate(wmf)
        let srcIndex = program.payloadSourceIndices
        let bytes = [UInt8](scene.source.data)
        let windows = wmfWindowTracking(program)

        func sources(of payloadIndices: [Int]) -> [Int] {
            payloadIndices.compactMap { $0 >= 0 && $0 < srcIndex.count && srcIndex[$0] >= 0 ? srcIndex[$0] : nil }
        }
        var ownerBySource: [Int: Element] = [:]
        var drawKeyOf: [Int: Int] = [:]   // element id → its last source WMF record
        for element in scene.elements where !element.provenance.sourceRecordIndices.isEmpty {
            let recs = sources(of: element.provenance.sourceRecordIndices)
            for s in recs { ownerBySource[s] = element }
            if let k = recs.max() { drawKeyOf[element.id] = k }
        }
        var contentSources = Set<Int>()
        for p in scene.partition.drawing.union(scene.partition.passthrough) where p < srcIndex.count && srcIndex[p] >= 0 {
            contentSources.insert(srcIndex[p])
        }
        let insertions = planInsertionsWMF(scene, srcIndex: srcIndex)
        let firstContent = contentSources.min()

        var table = SlotTable()
        var warnings: [ExportWarning] = []
        var body: [[UInt8]] = []
        var maxRecordWords: UInt32 = 0
        func emit(_ chunk: [UInt8]) {
            body.append(chunk)
            maxRecordWords = max(maxRecordWords, UInt32(chunk.count / 2))
        }
        func emitBlocks(_ elements: [Element], window: (PointL, SizeL)) throws(WMFWriteError) {
            let space = Self.logicalSpace(winOrg: window.0, winExt: window.1, canvasWidth: program.canvasWidth, canvasHeight: program.canvasHeight)
            for element in elements where !element.hidden {
                for record in try wmfBlockRecords(element, space: space, table: &table, warnings: &warnings) {
                    emit(try WMFRecordEncoder.encode(record))
                }
            }
        }

        for (i, record) in wmf.records.enumerated() {
            if record.function == 0x0000 { continue }   // META_EOF — appended last
            if i == firstContent { try emitBlocks(insertions.atStart, window: windows.base) }

            if contentSources.contains(i) {
                if let owner = ownerBySource[i] {
                    if owner.provenance.edited {
                        // Use the window actually in effect where this element draws.
                        if i == drawKeyOf[owner.id] { try emitBlocks([owner], window: windows.bySource[i] ?? windows.base) }
                    } else {
                        emit(try wmfRawOrThrow(bytes, record))
                    }
                }   // deleted → drop
            } else {
                emit(try wmfRawOrThrow(bytes, record))
            }
            applyWMFObjectEffect(record, bytes: bytes, table: &table)
            if let after = insertions.afterRecord[i] { try emitBlocks(after, window: windows.bySource[i] ?? windows.base) }
        }
        if firstContent == nil { try emitBlocks(insertions.atStart, window: windows.base) }

        return (try assembleWMF(source: bytes, wmf: wmf, body: body, maxRecordWords: maxRecordWords,
                                numberOfObjects: max(wmf.header.numberOfObjects, UInt16(clamping: table.highWater))), warnings)
    }

    /// Embedded-EMF WMF overlay (renderPath .gdi): the drawing comes from an
    /// embedded EMF, so the edit lands there — overlay the embedded EMF, re-embed
    /// it as fresh WMFC escape records, and keep the WMF records unchanged (a
    /// WMF-only reader still shows the original: `embeddedEMFOnly` warning).
    private static func overlayEmbeddedWMF(_ wmf: WMFFile, _ scene: Scene) throws -> (Data, [ExportWarning]) {
        guard case .reassembled(let emfData) = WMFEmbeddedEMF.reassemble(wmf) else {
            return try overlayWMF(wmf, scene)   // defensive: no usable embedded EMF
        }
        let emfFile = try EMFFile.parse(emfData)
        var (editedEMF, warnings) = try overlayEMF(emfFile, scene, source: emfData)
        warnings.append(.embeddedEMFOnly)

        let bytes = [UInt8](scene.source.data)
        let newEscapes = try WMFEmbeddedEMFWriter.escapeRecords(for: editedEMF)
        editedEMF.removeAll(keepingCapacity: false)

        var body: [[UInt8]] = []
        var maxRecordWords: UInt32 = 0
        for chunk in newEscapes { body.append(chunk); maxRecordWords = max(maxRecordWords, UInt32(chunk.count / 2)) }
        for record in wmf.records {
            if record.function == 0x0000 { continue }   // EOF appended last
            if isWMFCEscape(bytes, record) { continue } // drop old embedded-EMF escapes
            let chunk = try wmfRawOrThrow(bytes, record)
            body.append(chunk); maxRecordWords = max(maxRecordWords, UInt32(chunk.count / 2))
        }
        return (try assembleWMF(source: bytes, wmf: wmf, body: body, maxRecordWords: maxRecordWords,
                                numberOfObjects: wmf.header.numberOfObjects), warnings)
    }

    // MARK: - WMF assembly

    /// Builds the output WMF: preserved placeable (checksum patched) + META_HEADER
    /// (SizeLow/High, MaxRecord, NumberOfObjects patched) + `body` + META_EOF.
    private static func assembleWMF(source: [UInt8], wmf: WMFFile, body: [[UInt8]], maxRecordWords: UInt32, numberOfObjects: UInt16) throws(WMFWriteError) -> Data {
        let eof: [UInt8] = [0x03, 0x00, 0x00, 0x00, 0x00, 0x00]   // RecordSize 3 words, Function META_EOF
        let hasPlaceable = wmf.placeable != nil
        let metaOffset = hasPlaceable ? 22 : 0
        guard source.count >= metaOffset + 18 else { throw .sourceRecordOutOfBounds(recordOffset: 0, recordSize: 18) }

        var bodyBytes = 0
        for chunk in body { bodyBytes += chunk.count }
        let metafileBytes = 18 + bodyBytes + eof.count
        guard metafileBytes / 2 <= Int(UInt32.max) else { throw .fileTooLarge(byteCount: metafileBytes) }
        let metafileWords = metafileBytes / 2
        let mrw = max(maxRecordWords, UInt32(eof.count / 2))

        var header = Array(source[metaOffset ..< metaOffset + 18])
        patchU16(&header, 6, UInt16(metafileWords & 0xFFFF))
        patchU16(&header, 8, UInt16((metafileWords >> 16) & 0xFFFF))
        patchU16(&header, 10, numberOfObjects)
        patchU32(&header, 12, mrw)

        var out = [UInt8]()
        if hasPlaceable {
            var placeable = Array(source[0 ..< 22])
            patchU16(&placeable, 20, placeableChecksum(placeable))
            out.append(contentsOf: placeable)
        }
        out.append(contentsOf: header)
        for chunk in body { out.append(contentsOf: chunk) }
        out.append(contentsOf: eof)
        return Data(out)
    }

    /// Updates the slot model for a source WMF record's object effect.
    private static func applyWMFObjectEffect(_ record: WMFRawRecord, bytes: [UInt8], table: inout SlotTable) {
        let createFunctions: Set<UInt16> = [0x02FA, 0x02FB, 0x02FC, 0x00F7, 0x01F9, 0x0142, 0x06FF]
        if createFunctions.contains(record.function) {
            _ = table.allocate()
        } else if record.function == 0x01F0 {   // META_DELETEOBJECT
            let o = record.offset + 6
            guard o >= 0, o + 2 <= bytes.count else { return }
            let slot = UInt16(bytes[o]) | (UInt16(bytes[o + 1]) << 8)
            if slot & 0x8000 == 0 { table.free(Int(slot)) }
        }
    }

    /// Builds one element's logical-space WMF block, allocating its object slots
    /// from the running slot model. The element is first mapped into the WMF's
    /// LOGICAL coordinate space (`space`) so the block draws exactly where the
    /// file's own records do — full scale in any spec-correct reader.
    private static func wmfBlockRecords(_ element: Element, space: WMFLogicalSpace, table: inout SlotTable, warnings: inout [ExportWarning]) throws(WMFWriteError) -> [WMFRecord] {
        let needs = SceneSynthesis.wmfSlotNeeds(for: element)
        let penSlot = needs.pen ? table.allocate() : 0
        let brushSlot = needs.brush ? table.allocate() : 0
        let fontSlot = needs.font ? table.allocate() : 0
        let logical = wmfLogicalElement(element, space)
        let records = SceneSynthesis.wmfBlock(for: logical, winOrg: space.winOrg, winExt: space.winExt, penSlot: penSlot, brushSlot: brushSlot, fontSlot: fontSlot, warnings: &warnings)
        if needs.font { table.free(Int(fontSlot)) }
        if needs.brush { table.free(Int(brushSlot)) }
        if needs.pen { table.free(Int(penSlot)) }
        return records
    }

    /// The WMF page's base window (the translated program's preamble) and the
    /// device-canvas → WMF-logical affine. A synthesised block is drawn in this
    /// logical space, like every verbatim record, so a spec-correct standalone
    /// reader maps it to the full output frame (not to the small device canvas).
    private struct WMFLogicalSpace {
        var winOrg: PointL
        var winExt: SizeL
        var canvasToLogical: CGAffineTransform
    }

    /// The WMF logical window in effect, tracked per SOURCE record. `base` is the
    /// window the synthetic preamble established (payloads with source index -1);
    /// `bySource[i]` is the window as source record `i` begins to play — after
    /// every window change (SETWINDOWORG/EXT, OFFSETWINDOWORG, SCALEWINDOWEXT,
    /// which the translator already lowers to SETWINDOWORGEX/EXTEX) in the records
    /// before it. E1b1 read only the preamble window, so an edit after a mid-stream
    /// window change inverted its device geometry with the wrong mapping and landed
    /// in the wrong place; using the window actually in effect there fixes it
    /// ([MS-WMF] §2.3.5.30/.31, §3.1.4.2).
    private static func wmfWindowTracking(_ program: WMFRenderProgram) -> (base: (PointL, SizeL), bySource: [Int: (PointL, SizeL)]) {
        var org = PointL(x: 0, y: 0)
        var ext = SizeL(cx: Int32(max(1, program.canvasWidth)), cy: Int32(max(1, program.canvasHeight)))
        var base: (PointL, SizeL)?
        var bySource: [Int: (PointL, SizeL)] = [:]
        let sources = program.payloadSourceIndices
        for (i, payload) in program.payloads.enumerated() {
            let s = i < sources.count ? sources[i] : -1
            if s < 0 {
                // Preamble: accumulate to the base window (its last values win).
                switch payload {
                case .setWindowOrgEx(let o): org = o
                case .setWindowExtEx(let e): ext = e
                default: break
                }
            } else {
                if base == nil { base = (org, ext) }
                if bySource[s] == nil { bySource[s] = (org, ext) }   // window as record `s` starts
                switch payload {
                case .setWindowOrgEx(let o): org = o
                case .setWindowExtEx(let e): ext = e
                default: break
                }
            }
        }
        return (base ?? (org, ext), bySource)
    }

    /// Inverts the window→canvas scale into the canvas→logical affine
    /// (logical = winOrg + canvas × winExt / canvasSize) for a given window.
    /// Defaults keep the map finite for a degenerate window ([MS-WMF] §2.3.5.30,
    /// §3.1.4.2).
    private static func logicalSpace(winOrg org: PointL, winExt ext: SizeL, canvasWidth: Int, canvasHeight: Int) -> WMFLogicalSpace {
        let cw = max(1, canvasWidth), ch = max(1, canvasHeight)
        let sx = ext.cx == 0 ? 1 : Double(ext.cx) / Double(cw)
        let sy = ext.cy == 0 ? 1 : Double(ext.cy) / Double(ch)
        let canvasToLogical = CGAffineTransform(
            a: CGFloat(sx), b: 0, c: 0, d: CGFloat(sy),
            tx: CGFloat(org.x), ty: CGFloat(org.y)
        )
        return WMFLogicalSpace(winOrg: org, winExt: ext, canvasToLogical: canvasToLogical)
    }

    /// Returns a copy of `element` mapped into WMF-logical space with an identity
    /// transform: geometry, image destination and the (post-edit) text reference
    /// go through `canvasToLogical`, so the synthesis — which reads these fields
    /// and scales widths by `averageScale(transform)` (now 1) — emits logical
    /// records at logical pen widths and font heights.
    private static func wmfLogicalElement(_ element: Element, _ space: WMFLogicalSpace) -> Element {
        var mapped = element
        mapped.geometryDevice = element.geometryDevice.applying(space.canvasToLogical)
        if var text = mapped.text {
            let device = CGPoint(x: text.referenceLogical.x, y: text.referenceLogical.y).applying(element.transform)
            text.referenceLogical = device.applying(space.canvasToLogical)
            mapped.text = text
        }
        if var image = mapped.image {
            image.destRectDevice = image.destRectDevice.applying(space.canvasToLogical)
            mapped.image = image
        }
        mapped.transform = .identity
        return mapped
    }

    private static func isWMFCEscape(_ bytes: [UInt8], _ record: WMFRawRecord) -> Bool {
        guard record.function == 0x0626 else { return false }   // META_ESCAPE
        let o = record.offset + 6
        guard o + 8 <= bytes.count else { return false }
        let escapeFn = UInt16(bytes[o]) | (UInt16(bytes[o + 1]) << 8)
        guard escapeFn == 0x000F else { return false }          // MFCOMMENT
        let id = UInt32(bytes[o + 4]) | (UInt32(bytes[o + 5]) << 8) | (UInt32(bytes[o + 6]) << 16) | (UInt32(bytes[o + 7]) << 24)
        return id == 0x4346_4D57                                // "WMFC"
    }

    private static func wmfRawOrThrow(_ bytes: [UInt8], _ record: WMFRawRecord) throws(WMFWriteError) -> [UInt8] {
        let start = record.offset, size = record.byteSize
        guard start >= 0, size >= 0, size <= bytes.count, start <= bytes.count - size else {
            throw .sourceRecordOutOfBounds(recordOffset: start, recordSize: size)
        }
        return Array(bytes[start ..< start + size])
    }

    // MARK: - Insertions (z-position)

    private struct Insertions { var atStart: [Element]; var afterRecord: [Int: [Element]] }

    /// Maps new (no-provenance) elements to the source record after which they
    /// insert — the last record of the source element below them in z-order (or
    /// the start of the drawing records for the bottom).
    private static func planInsertions(_ scene: Scene) -> Insertions {
        var atStart: [Element] = []
        var afterRecord: [Int: [Element]] = [:]
        var prevSourceLast: Int?
        for element in scene.elements {
            if element.provenance.sourceRecordIndices.isEmpty {
                if let p = prevSourceLast { afterRecord[p, default: []].append(element) }
                else { atStart.append(element) }
            } else {
                prevSourceLast = element.provenance.sourceRecordIndices.max()
            }
        }
        return Insertions(atStart: atStart, afterRecord: afterRecord)
    }

    private static func planInsertionsWMF(_ scene: Scene, srcIndex: [Int]) -> Insertions {
        var atStart: [Element] = []
        var afterRecord: [Int: [Element]] = [:]
        var prevSourceLast: Int?
        for element in scene.elements {
            if element.provenance.sourceRecordIndices.isEmpty {
                if let p = prevSourceLast { afterRecord[p, default: []].append(element) }
                else { atStart.append(element) }
            } else {
                let recs = element.provenance.sourceRecordIndices.compactMap { $0 >= 0 && $0 < srcIndex.count && srcIndex[$0] >= 0 ? srcIndex[$0] : nil }
                if let k = recs.max() { prevSourceLast = k }
            }
        }
        return Insertions(atStart: atStart, afterRecord: afterRecord)
    }

    // MARK: - Helpers

    /// Gzip-wraps the bytes when the format is compressed.
    private static func finalize(_ data: Data, _ format: ExportFormat) -> Data {
        format.isCompressed ? GzipWriter.compress(data) : data
    }

    /// One past the largest object-table index any creation/reference record
    /// names, so synthesised objects use slots no existing record touches.
    private static func maxTableIndex(_ records: [EMFRawRecord], _ bytes: [UInt8]) -> UInt32 {
        var maxIndex: UInt32 = 0
        for record in records where handleFieldTypes.contains(record.type) {
            let offset = record.offset + 8
            guard record.size >= 12, offset >= 0, offset <= bytes.count - 4 else { continue }
            let raw = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
            if raw & 0x8000_0000 == 0, raw > maxIndex { maxIndex = raw }
        }
        return maxIndex
    }

    private static func rawOrThrow(_ bytes: [UInt8], _ record: EMFRawRecord) throws(EMFWriteError) -> [UInt8] {
        let start = record.offset
        let size = Int(record.size)
        guard start >= 0, size >= 0, size <= bytes.count, start <= bytes.count - size else {
            throw .sourceRecordOutOfBounds(recordOffset: start, recordSize: record.size)
        }
        return Array(bytes[start ..< start + size])
    }

    /// The handle-table size the body demands: one past the largest table index
    /// any output record (verbatim or synthesised) names in its offset-8 field.
    private static func handleCount(_ chunks: [[UInt8]]) throws(EMFWriteError) -> UInt16 {
        var maxIndex: UInt32 = 0
        var sawAny = false
        for chunk in chunks where chunk.count >= 12 {
            let type = UInt32(chunk[0]) | (UInt32(chunk[1]) << 8) | (UInt32(chunk[2]) << 16) | (UInt32(chunk[3]) << 24)
            guard handleFieldTypes.contains(type) else { continue }
            let raw = UInt32(chunk[8]) | (UInt32(chunk[9]) << 8) | (UInt32(chunk[10]) << 16) | (UInt32(chunk[11]) << 24)
            guard raw & 0x8000_0000 == 0 else { continue }
            sawAny = true
            if raw > maxIndex { maxIndex = raw }
        }
        guard sawAny else { return 1 }
        let count = maxIndex + 1
        guard count <= UInt32(UInt16.max) else { throw .objectTableOverflow(index: maxIndex) }
        return UInt16(count)
    }

    private static func patchU32(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt32) {
        guard offset >= 0, offset <= buffer.count - 4 else { return }
        buffer[offset] = UInt8(value & 0xFF)
        buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
        buffer[offset + 2] = UInt8((value >> 16) & 0xFF)
        buffer[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
    private static func patchU16(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt16) {
        guard offset >= 0, offset <= buffer.count - 2 else { return }
        buffer[offset] = UInt8(value & 0xFF)
        buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    /// The Aldus placeable `Checksum`: XOR of the first ten 16-bit WORDs
    /// ([MS-WMF] §2.3.2.3), the computation WMFParse verifies.
    private static func placeableChecksum(_ placeable: [UInt8]) -> UInt16 {
        var checksum: UInt16 = 0
        for i in 0 ..< 10 where i * 2 + 1 < placeable.count {
            checksum ^= UInt16(placeable[i * 2]) | (UInt16(placeable[i * 2 + 1]) << 8)
        }
        return checksum
    }
}

/// The WMF object-table model for the overlay ([MS-WMF] §3.1.4.1): simulated
/// along the source stream so a synthesised block takes the lowest free slots
/// the same allocator would, and `highWater` gives the `NumberOfObjects` the
/// output must declare.
private struct SlotTable {
    private var occupied = Set<Int>()
    private(set) var highWater = 0
    mutating func allocate() -> UInt16 {
        var slot = 0
        while occupied.contains(slot) { slot += 1 }
        occupied.insert(slot)
        highWater = max(highWater, slot + 1)
        return UInt16(truncatingIfNeeded: slot)
    }
    mutating func free(_ slot: Int) { occupied.remove(slot) }
}

/// Tracks the current EmfPlusObject definition of each EMF+ object slot as the
/// overlay re-emits the stream verbatim ([MS-EMFPLUS] §3.1.2 object table): a slot
/// stays defined until redefined (EMF+ has no delete-object). A synthesised block
/// that must REUSE a defined slot re-emits that slot's last definition after the
/// block (slot restore), so later records that read the slot still see the
/// original object. A definition that spanned several continuation records
/// ([MS-EMFPLUS] §2.3.5.1) is kept as that run of framed records, re-emitted whole.
struct PlusObjectDefs {
    /// EmfPlusObject record type ([MS-EMFPLUS] §2.1.1.1).
    private static let objectType: UInt16 = 0x4008
    /// EmfPlusObject continuation flag ([MS-EMFPLUS] §2.3.5.1, bit 15 of Flags):
    /// set on every chunk of a multi-record object definition.
    private static let continueFlag: UInt16 = 0x8000

    private var defs: [UInt8: [[UInt8]]] = [:]
    private var run: (id: UInt8, chunks: [[UInt8]])?

    /// The slots with a current definition (after `flush`).
    var definedSlots: Set<UInt8> { Set(defs.keys) }

    /// Feeds one kept-verbatim stream record. A COMPLETE definition (an
    /// EmfPlusObject with the continuation flag clear) replaces the slot's
    /// definition outright, so two back-to-back complete definitions of one slot
    /// keep only the last ([MS-EMFPLUS] §2.3.5.1). A CONTINUED definition (the
    /// flag set) groups its consecutive same-slot chunks into one definition.
    /// Any non-object record ends an in-progress run.
    mutating func feed(record: EMFPlusRecord, framed: [UInt8]) {
        guard record.type == Self.objectType else { flush(); return }
        let id = UInt8(record.flags & 0x00FF)
        if record.flags & Self.continueFlag != 0 {
            // Part of a continued object: accumulate consecutive same-slot chunks.
            if var current = run, current.id == id {
                current.chunks.append(framed); run = current
            } else {
                flush(); run = (id, [framed])
            }
        } else {
            // A complete single-record definition: it ends any run and REPLACES
            // the slot's definition (a later complete def wins over an earlier one).
            flush()
            defs[id] = [framed]
        }
    }

    /// Finalises any in-progress object run into `defs`.
    mutating func flush() {
        if let current = run { defs[current.id] = current.chunks; run = nil }
    }

    /// The framed record bytes that last defined `slot`, empty if undefined.
    func definition(of slot: UInt8) -> [[UInt8]] { defs[slot] ?? [] }
}
