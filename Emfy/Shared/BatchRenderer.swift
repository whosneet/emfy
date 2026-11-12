import CoreGraphics
import EMFParse
import EMFRender
import Foundation

/// Bridges the pure `BatchConvert` engine to EMFKit (F1 design call 4): it reads a
/// source file's bytes and produces the requested output format, classifying a
/// hostile or non-metafile input as a log-and-skip (`.unparseable`) rather than
/// crashing (§8). PNG uses the Settings default scale reduced to the shared area cap
/// and the Settings PNG background; PDF is a true vector page; SVG is produced from
/// the imported scene. `Sendable` free functions, so the engine runs them on its task
/// group off the main actor.
enum BatchRenderer {
    /// Produces `source` as `format`. Never throws — every outcome is a typed
    /// `BatchProduceOutcome` the report classifies.
    static func produce(
        _ source: BatchSource,
        format: BatchOutputFormat,
        pngScale: Int,
        background: RenderBackground,
        options: RenderOptions
    ) -> BatchProduceOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: source.url, options: .mappedIfSafe)
        } catch {
            return .failed(reason: "Couldn’t read the file.")
        }
        return produce(bytes: data, format: format, pngScale: pngScale, background: background, options: options)
    }

    /// The byte-level core, split out so a test can drive it with in-memory bytes
    /// (including hostile garbage) without touching the disk.
    static func produce(
        bytes data: Data,
        format: BatchOutputFormat,
        pngScale: Int,
        background: RenderBackground,
        options: RenderOptions
    ) -> BatchProduceOutcome {
        switch format {
        case .svg:
            guard let produced = SVGExport.data(from: data) else {
                return .unparseable(reason: "Not a drawing Emfy can convert.")
            }
            return .converted(produced.data)

        case .png, .pdf:
            guard let opened = try? OpenedMetafile.open(data),
                  let prepared = MetafileRenderer.prepare(opened, options: options) else {
                return .unparseable(reason: "Not a supported metafile.")
            }
            if format == .pdf {
                guard let pdf = MetafileRenderer.pdfData(prepared, options: options) else {
                    return .failed(reason: "Couldn’t produce a PDF.")
                }
                return .converted(pdf)
            }
            let selection = ExportScale.select(
                baseWidth: Int(prepared.naturalSize.width.rounded()),
                baseHeight: Int(prepared.naturalSize.height.rounded()),
                requested: pngScale,
                areaCap: ExportScale.areaCap
            )
            guard let (image, _) = MetafileRenderer.makeImage(
                    prepared, scale: CGFloat(selection.multiplier), background: background, options: options),
                  let png = EMFExport.pngData(from: image) else {
                return .failed(reason: "Couldn’t produce a PNG.")
            }
            return .converted(png)
        }
    }
}
