import CoreGraphics
import EMFParse
import EMFRender
import Foundation

/// iOS-only loading helpers that turn raw metafile bytes into something the
/// SwiftUI views can show. The heavy work — gzip unwrap, parse, render — runs
/// off the main actor through EMFKit's one front door (`OpenedMetafile.open`
/// → `MetafileRenderer`), exactly as the Mac app and the Quick Look extensions
/// do (primer §8: anything past a valid header renders best-effort).
///
/// `CGImage` is immutable once created, so carrying it across an actor boundary
/// in a `@unchecked Sendable` box is safe; this avoids a PNG round-trip for the
/// full-resolution viewer image.
struct SendableImage: @unchecked Sendable {
    let cgImage: CGImage
}

/// A loaded metafile ready to display: the rendered picture plus its natural
/// device size. `@unchecked Sendable` for the same CGImage-immutability reason.
struct LoadedMetafile: @unchecked Sendable {
    /// The rendered picture at the requested scale. `nil` only when the bitmap
    /// context could not be allocated — the viewer then shows a plain message
    /// instead of a blank canvas.
    let image: CGImage?
    /// The metafile's natural device size (EMF header bounds or WMF canvas).
    let naturalSize: CGSize
}

enum MetafileLoader {
    /// The on-screen render scale (retina). The renderer caps absurd bounds at
    /// 16384 per side / 32 MP area, so this is safe for hostile input.
    static let viewerScale: CGFloat = 2

    /// Thrown only for a file EMFKit cannot open at all (a broken gzip wrapper,
    /// an unrecognised format, or a header-less EMF/WMF). Everything past a
    /// valid header is best-effort and never throws.
    struct UnreadableFile: Error {}

    /// Parses and renders `data` off the main actor. Call from a background
    /// context; the result is `Sendable` and crosses back to the main actor
    /// safely.
    static func load(_ data: Data) throws -> LoadedMetafile {
        guard let opened = try? OpenedMetafile.open(data),
              let prepared = MetafileRenderer.prepare(opened) else {
            throw UnreadableFile()
        }
        let image = MetafileRenderer.makeImage(prepared, scale: viewerScale)?.0
        return LoadedMetafile(image: image, naturalSize: prepared.naturalSize)
    }

    /// Renders a bounded thumbnail PNG for the recents grid. `maxLongEdge` caps
    /// the long side in pixels, so a huge-bounds file still produces a small,
    /// memory-cheap bitmap. Returns `nil` for an unreadable file or an
    /// allocation failure.
    static func thumbnailPNG(_ data: Data, maxLongEdge: Int) -> Data? {
        guard let opened = try? OpenedMetafile.open(data),
              let prepared = MetafileRenderer.prepare(opened) else {
            return nil
        }
        let natural = prepared.naturalSize
        let longEdge = max(natural.width, natural.height)
        // Never upscale past 1×; shrink so the long edge fits maxLongEdge.
        let scale = longEdge > CGFloat(maxLongEdge) ? CGFloat(maxLongEdge) / longEdge : 1
        guard let image = MetafileRenderer.makeImage(prepared, scale: scale)?.0 else {
            return nil
        }
        return EMFExport.pngData(from: image)
    }
}
