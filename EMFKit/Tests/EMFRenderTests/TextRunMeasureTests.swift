import CoreGraphics
import Foundation
import Testing
@testable import EMFRender

// P3: the public advance-measurement entry point behind the find-highlight
// substring boxes. It resolves the font through FontMapper and measures on the
// deadlock-safe lookup queue, so these run like any other font test.

@Suite struct TextRunMeasureTests {

    @Test func cumulativeOffsetsAreMonotonicAndStartAtZero() {
        let offsets = try? #require(TextRunMeasure.cumulativeOffsets(
            string: "Hello", family: "Helvetica", bold: false, italic: false, emSize: 20))
        let o = try! #require(offsets)
        // One entry per UTF-16 boundary (5 code units → 6 offsets).
        #expect(o.count == 6)
        #expect(o.first == 0)
        // Each prefix is at least as wide as the previous (advances are non-negative).
        for i in 1 ..< o.count { #expect(o[i] >= o[i - 1]) }
        // A real run has a positive total width.
        #expect((o.last ?? 0) > 0)
    }

    @Test func widthScalesWithEmSize() {
        let small = TextRunMeasure.cumulativeOffsets(
            string: "Width", family: "Helvetica", bold: false, italic: false, emSize: 10)
        let large = TextRunMeasure.cumulativeOffsets(
            string: "Width", family: "Helvetica", bold: false, italic: false, emSize: 20)
        let s = try! #require(small)
        let l = try! #require(large)
        let sTotal = try! #require(s.last)
        let lTotal = try! #require(l.last)
        // Advances scale linearly with point size: doubling em ~doubles the width
        // (allow a wide tolerance for hinting/rounding).
        #expect(lTotal > sTotal * 1.6)
        #expect(lTotal < sTotal * 2.4)
    }

    @Test func rejectsEmptyStringAndNonPositiveEm() {
        #expect(TextRunMeasure.cumulativeOffsets(
            string: "", family: "Helvetica", bold: false, italic: false, emSize: 10) == nil)
        #expect(TextRunMeasure.cumulativeOffsets(
            string: "x", family: "Helvetica", bold: false, italic: false, emSize: 0) == nil)
        #expect(TextRunMeasure.cumulativeOffsets(
            string: "x", family: "Helvetica", bold: false, italic: false, emSize: -5) == nil)
    }

    @Test func unknownFamilyStillMeasuresViaSubstitution() {
        // A missing family resolves to a substitute (FontMapper), so measurement
        // still succeeds rather than returning nil.
        let offsets = TextRunMeasure.cumulativeOffsets(
            string: "ABC", family: "No Such Face 12345", bold: false, italic: false, emSize: 16)
        let o = try! #require(offsets)
        #expect(o.count == 4)
        #expect((o.last ?? 0) > 0)
    }
}
