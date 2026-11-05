import CoreGraphics
import Foundation
import Testing
import EMFParse
import EMFRender
import EMFWrite

// MARK: - Corpus access (WMF / WMZ)

/// The committed `corpus/*.wmf` and `*.wmz` file names, sorted.
func committedWMFCorpus() -> [String] {
    let dir = repoRootURL().appendingPathComponent("corpus")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasSuffix(".wmf") || $0.hasSuffix(".wmz") }.sorted()
}

/// Every `.wmf`/`.wmz` under `corpus-local/` (recursively), or an empty list when
/// the directory is absent. Work-sourced files there are CONFIDENTIAL — callers
/// report counts only, never these paths.
func corpusLocalWMFFiles() -> [URL] {
    let dir = repoRootURL().appendingPathComponent("corpus-local")
    guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {
        return []
    }
    var out: [URL] = []
    for case let url as URL in e {
        let ext = url.pathExtension.lowercased()
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
           ext == "wmf" || ext == "wmz" {
            out.append(url)
        }
    }
    return out
}

// MARK: - Render + pixel sampling

/// A rendered WMF: the prepared metafile (for the embedded-EMF fate) and a
/// straight-RGBA8 buffer (R,G,B,A per pixel) of the natural-size render on white.
struct RenderedWMF {
    let prepared: MetafileRenderer.Prepared
    let pixels: [UInt8]
    let width: Int
    let height: Int

    /// RGBA at (x, y) in buffer coordinates (row 0 is the context's bottom row).
    func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let o = (y * width + x) * 4
        return (Int(pixels[o]), Int(pixels[o + 1]), Int(pixels[o + 2]), Int(pixels[o + 3]))
    }

    /// True when any pixel in the whole image matches `predicate`.
    func anyPixel(_ predicate: (_ r: Int, _ g: Int, _ b: Int) -> Bool) -> Bool {
        for i in stride(from: 0, to: pixels.count, by: 4)
        where predicate(Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])) {
            return true
        }
        return false
    }

    /// Count of pixels matching `predicate`.
    func countPixels(_ predicate: (_ r: Int, _ g: Int, _ b: Int) -> Bool) -> Int {
        var n = 0
        for i in stride(from: 0, to: pixels.count, by: 4)
        where predicate(Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])) {
            n += 1
        }
        return n
    }
}

func near(_ p: (r: Int, g: Int, b: Int, a: Int), _ r: Int, _ g: Int, _ b: Int, tol: Int = 24) -> Bool {
    abs(p.r - r) <= tol && abs(p.g - g) <= tol && abs(p.b - b) <= tol
}

/// Opens, prepares, and renders `data` (EMF/WMF/EMZ/WMZ) through `MetafileRenderer`
/// into a white RGBA8 bitmap sized to the natural size.
func renderMetafile(
    _ data: Data,
    options: RenderOptions = .default,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> RenderedWMF {
    let opened = try OpenedMetafile.open(data)
    let prepared = try #require(MetafileRenderer.prepare(opened, options: options),
                                "prepare returned nil", sourceLocation: sourceLocation)
    let w = max(1, Int(prepared.naturalSize.width.rounded()))
    let h = max(1, Int(prepared.naturalSize.height.rounded()))
    var buffer = [UInt8](repeating: 0, count: w * h * 4)
    let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
        guard let base = raw.baseAddress,
              let ctx = CGContext(
                  data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        _ = MetafileRenderer.render(prepared, into: ctx, target: CGRect(x: 0, y: 0, width: w, height: h), options: options)
        return true
    }
    try #require(ok, "CGContext allocation failed", sourceLocation: sourceLocation)
    return RenderedWMF(prepared: prepared, pixels: buffer, width: w, height: h)
}
