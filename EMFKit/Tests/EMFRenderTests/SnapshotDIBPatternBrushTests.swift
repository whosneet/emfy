// Snapshot baselines are macOS-only; gated like the phase gates.
#if os(macOS)
import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// R2 render coverage for EMR_CREATEDIBPATTERNBRUSHPT (94) with a colour DIB
/// tiled as a fill brush, phased by EMR_SETBRUSHORGEX (13). A 16×16 four-colour
/// DIB (red / green / blue / yellow quadrants) tiles a filled rectangle and a
/// path-bracket fill. The baseline was accepted by first principles (no
/// LibreOffice on this machine) plus a visual read: the tile grid repeats the
/// quadrant pattern, red quadrants sit top-left of each tile (orientation
/// correct), and the brush-origin offset phases the second fill's grid.
@Suite("DIB pattern-brush render snapshot")
struct SnapshotDIBPatternBrushTests {

    /// A 24-bit DIB from a TOP-DOWN pixel grid (row 0 = top). Stored bottom-up
    /// (positive header height), pixels B,G,R, rows padded to a 4-byte stride —
    /// the on-disk form the decoder reads.
    static func dib24(topDown rows: [[(r: UInt8, g: UInt8, b: UInt8)]]) -> (bmi: [UInt8], bits: [UInt8]) {
        let h = rows.count
        let w = rows.first?.count ?? 0
        let rowStride = (w * 3 + 3) & ~3
        var bits: [UInt8] = []
        for rowIndex in Swift.stride(from: h - 1, through: 0, by: -1) {    // bottom-up storage
            var line: [UInt8] = []
            for pixel in rows[rowIndex] {
                line.append(pixel.b); line.append(pixel.g); line.append(pixel.r)
            }
            while line.count < rowStride { line.append(0) }
            bits.append(contentsOf: line)
        }
        let bmi = RenderFixture.bitmapInfoHeader(width: Int32(w), height: Int32(h), bitCount: 24)
        return (bmi, bits)
    }

    /// A 16×16 four-colour quadrant tile: top-left red, top-right green,
    /// bottom-left blue, bottom-right yellow.
    static func quadrantTile() -> (bmi: [UInt8], bits: [UInt8]) {
        let red: (UInt8, UInt8, UInt8) = (220, 40, 40)
        let green: (UInt8, UInt8, UInt8) = (40, 190, 60)
        let blue: (UInt8, UInt8, UInt8) = (50, 60, 220)
        let yellow: (UInt8, UInt8, UInt8) = (230, 200, 50)
        var rows: [[(r: UInt8, g: UInt8, b: UInt8)]] = []
        for y in 0 ..< 16 {
            var row: [(r: UInt8, g: UInt8, b: UInt8)] = []
            for x in 0 ..< 16 {
                let c = y < 8 ? (x < 8 ? red : green) : (x < 8 ? blue : yellow)
                row.append((c.0, c.1, c.2))
            }
            rows.append(row)
        }
        return dib24(topDown: rows)
    }

    private static func fixture() -> RenderFixture {
        var f = RenderFixture()
        f.bounds = (0, 0, 119, 119)
        let tile = quadrantTile()

        // A pattern brush in slot 1; select it. A black cosmetic pen outlines.
        f.createDIBPatternBrush(index: 1, bmi: tile.bmi, bits: tile.bits)
        f.selectObject(1)                     // select the pattern brush
        f.selectObject(0x8000_0008)           // NULL_PEN (no outline on the rect)

        // A rectangle filled with the tiled pattern, phase (0,0).
        f.rectangle(8, 8, 56, 56)

        // A path-bracket fill of a second rectangle, with the brush origin shifted
        // so its tile grid is phased differently (exercises the path-closer
        // pattern fill and SETBRUSHORGEX).
        f.setBrushOrgEx(4, 4)
        f.beginPath()
        f.rectangle(64, 64, 112, 112)
        f.endPath()
        f.fillPath()
        return f
    }

    @Test("a tiled DIB pattern brush fills a rect and a path to the accepted baseline")
    func patternFill() throws {
        let file = try Self.fixture().parsed()
        let (image, _) = try #require(EMFRenderer.makeImage(file, scale: 1), "makeImage returned nil")
        #expect(image.width == 120)
        #expect(image.height == 120)

        let failure = SnapshotComparator.verify(image, baselineNamed: "r2-dibpatternbrush")
        #expect(failure == nil, Comment(rawValue: failure ?? ""))
    }
}
#endif
