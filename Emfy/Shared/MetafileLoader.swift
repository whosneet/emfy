import CoreGraphics
import EMFParse
import EMFRender
import Foundation

/// iOS-only loading helpers that turn raw metafile bytes into the values the
/// SwiftUI views show. The heavy work — gzip unwrap, parse, prepare, one bounded
/// render for the log — runs off the main actor through EMFKit's one front door
/// (`OpenedMetafile.open` → `MetafileRenderer`), exactly as the Mac app and the
/// Quick Look extensions do (primer §8: anything past a valid header renders
/// best-effort).
///
/// The viewer does NOT keep a rendered bitmap here — it re-renders the vector at
/// the on-screen scale per tile (`ZoomableMetafileView`), which is what fixes
/// the I1 fixed-2× raster. The one render below exists only to collect the
/// authoritative render log for the partial-support notice.
struct LoadedMetafile: Sendable {
    /// The parsed metafile, re-rendered on demand by the tiled viewer and used
    /// for the natural size and PDF export. `Sendable`.
    let prepared: MetafileRenderer.Prepared
    /// The metafile's true natural device size (EMF header bounds or WMF canvas),
    /// shown in the inspector's "Picture size" row.
    let naturalSize: CGSize
    /// The natural size clamped to a sane display range (long side ≤ 16384 pt,
    /// each side ≥ 1 pt). This is what becomes view geometry — a hostile header
    /// with billion-unit bounds must not produce a billion-point frame or a
    /// ~1e-9 minimum zoom.
    let displaySize: CGSize
    /// Parse/render/front-door notes for the banner and the inspector.
    let diagnostics: ViewerDiagnostics
}

enum MetafileLoader {
    /// The maximum side, in points, the displayed picture may claim as geometry.
    /// Matches the renderer's own per-side cap.
    private static let maxDisplaySide: CGFloat = 16384
    /// The log-capture render is bounded well below the renderer's 32 MP bitmap
    /// cap: ~4 MP keeps the transient allocation ≤ ~16 MB for any input.
    private static let logRenderMaxArea: CGFloat = 4_000_000

    /// Thrown only for a file EMFKit cannot open at all (a broken gzip wrapper,
    /// an unrecognised format, or a header-less EMF/WMF). Everything past a
    /// valid header is best-effort and never throws.
    struct UnreadableFile: Error {}

    /// Scales a natural size so the long side is ≤ 16384 pt and each side ≥ 1 pt,
    /// preserving aspect. For a normal file this is a no-op.
    static func clampedDisplaySize(_ size: CGSize) -> CGSize {
        let width = size.width.isFinite && size.width > 0 ? size.width : 1
        let height = size.height.isFinite && size.height > 0 ? size.height : 1
        let longest = max(width, height)
        let scale = longest > maxDisplaySide ? maxDisplaySide / longest : 1
        return CGSize(
            width: max(1, (width * scale).rounded()),
            height: max(1, (height * scale).rounded())
        )
    }

    /// Parses and prepares `data` off the main actor, capturing the render log.
    /// Call from a cancellable background context; the result is `Sendable`. The
    /// one render below is skipped when the task has been cancelled (the viewer
    /// was popped), and is bounded in area regardless of the file's bounds.
    static func load(_ data: Data) throws -> LoadedMetafile {
        guard let opened = try? OpenedMetafile.open(data),
              let prepared = MetafileRenderer.prepare(opened) else {
            throw UnreadableFile()
        }
        let displaySize = clampedDisplaySize(prepared.naturalSize)
        let log = Task.isCancelled ? [] : captureRenderLog(prepared, displaySize: displaySize)
        let diagnostics = ViewerDiagnostics(
            kind: prepared.kind,
            embeddedEMF: prepared.embeddedEMF,
            renderLog: log,
            parserDiagnostics: prepared.emfDiagnostics,
            frontDoorDiagnostics: opened.diagnostics,
            wasDecompressed: opened.wasDecompressed
        )
        return LoadedMetafile(
            prepared: prepared,
            naturalSize: prepared.naturalSize,
            displaySize: displaySize,
            diagnostics: diagnostics
        )
    }

    /// Renders once into a small, area-capped context purely to collect the
    /// render log (unimplemented records, substitutions, skips). Uses
    /// `MetafileRenderer.render` into a caller-sized context — not `makeImage` —
    /// so it never allocates a large bitmap and never logs the on-screen
    /// `canvasClamped` note (which doesn't apply to the tiled viewer).
    private static func captureRenderLog(_ prepared: MetafileRenderer.Prepared, displaySize: CGSize) -> [EMFRenderLog.Entry] {
        let area = displaySize.width * displaySize.height
        let scale = area > logRenderMaxArea ? (logRenderMaxArea / area).squareRoot() : 1
        let width = max(1, Int((displaySize.width * scale).rounded()))
        let height = max(1, Int((displaySize.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return [] }
        return MetafileRenderer.render(
            prepared,
            into: context,
            target: CGRect(x: 0, y: 0, width: width, height: height)
        ).entries
    }

    /// A cheap readability check used when adding a file to recents: can EMFKit
    /// open and prepare it? Avoids a full render just to validate.
    static func canOpen(_ data: Data) -> Bool {
        guard let opened = try? OpenedMetafile.open(data) else { return false }
        return MetafileRenderer.prepare(opened) != nil
    }

    /// Renders a bounded thumbnail PNG for the recents grid on a **transparent**
    /// background, so the drawing sits directly on the tile's white paper with no
    /// inner white rectangle (the metafile's own white page would otherwise read
    /// as a card-inside-a-card when letterboxed in a fixed-aspect tile). White
    /// content stays invisible against the white tile either way, so nothing is
    /// lost. `maxLongEdge` caps the long side in pixels (§8: a huge-bounds file
    /// still produces a small, memory-cheap bitmap). Returns `nil` for an
    /// unreadable file or an allocation failure.
    static func thumbnailPNG(_ data: Data, maxLongEdge: Int) -> Data? {
        guard let opened = try? OpenedMetafile.open(data),
              let prepared = MetafileRenderer.prepare(opened) else {
            return nil
        }
        let natural = prepared.naturalSize
        let longEdge = max(natural.width, natural.height)
        // Never upscale past 1×; shrink so the long edge fits maxLongEdge. The
        // long edge is capped, so width·height ≤ maxLongEdge² — bounded.
        let scale = longEdge > CGFloat(maxLongEdge) ? CGFloat(maxLongEdge) / longEdge : 1
        let width = max(1, Int((natural.width * scale).rounded()))
        let height = max(1, Int((natural.height * scale).rounded()))

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        // No white fill: the context starts transparent, so only the drawing's
        // ink ends up in the PNG.
        _ = MetafileRenderer.render(
            prepared,
            into: context,
            target: CGRect(x: 0, y: 0, width: width, height: height)
        )
        guard let image = context.makeImage() else { return nil }
        return EMFExport.pngData(from: image)
    }
}
