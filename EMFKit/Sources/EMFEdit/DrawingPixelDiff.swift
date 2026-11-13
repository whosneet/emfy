import CoreGraphics
import Foundation

// MARK: - Pixel-level diff of two rendered versions (X1b item 1)
//
// Rasterises two CGImages into a common RGBA8 buffer and reports which pixels differ
// beyond a per-channel tolerance, as a changed-pixel count plus merged bounding
// regions (for the "highlight differences" overlay). A coarse cell grid keeps the
// region merge cheap on large canvases; the per-pixel scan is exact.

public struct DrawingPixelDiff: Sendable, Equatable {
    /// Pixel dimensions the two images were compared at (the union of their sizes).
    public var width: Int
    public var height: Int
    /// Number of pixels that differ beyond the tolerance.
    public var changedPixelCount: Int
    /// Bounding regions of the changed areas, in pixel space (top-left origin),
    /// merged from the cell grid. Empty when nothing changed.
    public var regions: [CGRect]

    public init(width: Int, height: Int, changedPixelCount: Int, regions: [CGRect]) {
        self.width = width
        self.height = height
        self.changedPixelCount = changedPixelCount
        self.regions = regions
    }

    /// Total pixels compared.
    public var totalPixels: Int { width * height }

    /// Fraction of pixels that changed, 0…1.
    public var changedFraction: Double {
        totalPixels > 0 ? Double(changedPixelCount) / Double(totalPixels) : 0
    }

    /// Whether any pixel changed.
    public var isEmpty: Bool { changedPixelCount == 0 }

    /// Compares `old` and `new`. Each channel difference beyond `channelTolerance`
    /// (0…255) marks a pixel changed; `cellSize` is the grid granularity for merging
    /// changed pixels into regions. Returns nil only if a buffer can't be allocated.
    public static func compare(old: CGImage, new: CGImage, channelTolerance: UInt8 = 8, cellSize: Int = 16) -> DrawingPixelDiff? {
        let width = max(old.width, new.width)
        let height = max(old.height, new.height)
        guard width > 0, height > 0 else {
            return DrawingPixelDiff(width: 0, height: 0, changedPixelCount: 0, regions: [])
        }
        guard let bufferA = rasterise(old, width: width, height: height),
              let bufferB = rasterise(new, width: width, height: height) else { return nil }

        let tolerance = Int(channelTolerance)
        let cells = max(1, cellSize)
        let cols = (width + cells - 1) / cells
        let rows = (height + cells - 1) / cells
        var changedCells = [Bool](repeating: false, count: cols * rows)
        var changedPixelCount = 0

        bufferA.withUnsafeBufferPointer { a in
            bufferB.withUnsafeBufferPointer { b in
                for y in 0 ..< height {
                    let rowBase = y * width * 4
                    for x in 0 ..< width {
                        let p = rowBase + x * 4
                        // RGBA8; compare all four channels.
                        if abs(Int(a[p]) - Int(b[p])) > tolerance
                            || abs(Int(a[p + 1]) - Int(b[p + 1])) > tolerance
                            || abs(Int(a[p + 2]) - Int(b[p + 2])) > tolerance
                            || abs(Int(a[p + 3]) - Int(b[p + 3])) > tolerance {
                            changedPixelCount += 1
                            changedCells[(y / cells) * cols + (x / cells)] = true
                        }
                    }
                }
            }
        }

        let regions = mergeRegions(cells: changedCells, cols: cols, rows: rows, cellSize: cells, width: width, height: height)
        return DrawingPixelDiff(width: width, height: height, changedPixelCount: changedPixelCount, regions: regions)
    }

    // MARK: - Rasterisation

    /// Draws `image` top-left into a fresh RGBA8 buffer of `width`×`height` over white,
    /// so two images of different sizes compare in a common frame.
    private static func rasterise(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Top-left aligned: CGContext is bottom-left origin, so place the image at
            // (0, height - imageHeight).
            context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
            return true
        }
        return drawn ? buffer : nil
    }

    // MARK: - Region merge (connected components on the coarse cell grid)

    /// Merges adjacent changed cells into bounding rectangles via 4-connected flood
    /// fill on the grid, then returns each component's pixel-space bounding box
    /// (clamped to the image).
    private static func mergeRegions(cells: [Bool], cols: Int, rows: Int, cellSize: Int, width: Int, height: Int) -> [CGRect] {
        var visited = [Bool](repeating: false, count: cells.count)
        var regions: [CGRect] = []
        var stack: [Int] = []
        for start in 0 ..< cells.count where cells[start] && !visited[start] {
            visited[start] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            var minCol = cols, maxCol = 0, minRow = rows, maxRow = 0
            while let index = stack.popLast() {
                let col = index % cols
                let row = index / cols
                minCol = min(minCol, col); maxCol = max(maxCol, col)
                minRow = min(minRow, row); maxRow = max(maxRow, row)
                let neighbours = [(col - 1, row), (col + 1, row), (col, row - 1), (col, row + 1)]
                for (nc, nr) in neighbours where nc >= 0 && nc < cols && nr >= 0 && nr < rows {
                    let n = nr * cols + nc
                    if cells[n] && !visited[n] { visited[n] = true; stack.append(n) }
                }
            }
            let x = minCol * cellSize
            let y = minRow * cellSize
            let w = min((maxCol + 1) * cellSize, width) - x
            let h = min((maxRow + 1) * cellSize, height) - y
            regions.append(CGRect(x: x, y: y, width: w, height: h))
        }
        return regions.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }
}
