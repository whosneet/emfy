import CoreGraphics
import Foundation
import Testing

// F3 unit tests for the pure find engine (`DrawingTextFind`): case- and
// diacritic-insensitive matching, occurrence counting, reading-order match order,
// and the next/previous wrap plus the "n of m" status.

@Suite struct DrawingTextFindTests {

    private func run(_ text: String, _ y: CGFloat, _ x: CGFloat = 0, _ source: DrawingTextRun.Source = .drawing) -> DrawingTextRun {
        DrawingTextRun(text: text, boundsDevice: CGRect(x: x, y: y, width: 40, height: 10), fontFamily: nil, fontSize: nil, source: source)
    }

    @Test func matchIsCaseInsensitive() {
        let runs = [run("Hello World", 0)]
        #expect(DrawingTextFind.matches(of: "hello", in: runs).count == 1)
        #expect(DrawingTextFind.matches(of: "WORLD", in: runs).count == 1)
    }

    @Test func matchIsDiacriticInsensitive() {
        let runs = [run("Café résumé", 0)]
        #expect(DrawingTextFind.matches(of: "cafe", in: runs).count == 1)
        #expect(DrawingTextFind.matches(of: "resume", in: runs).count == 1)
    }

    @Test func countsMultipleNonOverlappingOccurrences() {
        #expect(DrawingTextFind.occurrenceCount(of: "ab", in: "ababab") == 3)
        #expect(DrawingTextFind.occurrenceCount(of: "aa", in: "aaaa") == 2)   // non-overlapping
        #expect(DrawingTextFind.occurrenceCount(of: "x", in: "no match") == 0)
    }

    @Test func emptyQueryHasNoMatches() {
        #expect(DrawingTextFind.matches(of: "", in: [run("anything", 0)]).isEmpty)
    }

    @Test func matchesAreInReadingOrder() {
        // Three runs out of order; each contains "x" once.
        let runs = [
            run("x bottom", 100),
            run("x top", 0),
            run("x middle", 50),
        ]
        let m = DrawingTextFind.matches(of: "x", in: runs)
        #expect(m.count == 3)
        // After reading-order sort the run indices are top(0), middle(1), bottom(2).
        #expect(m.map(\.runIndex) == [0, 1, 2])
    }

    @Test func pictureSourceIsPreservedOnMatches() {
        let runs = [run("in picture", 0, 0, .picture)]
        let m = DrawingTextFind.matches(of: "picture", in: runs)
        #expect(m.first?.source == .picture)
    }

    // MARK: Navigation

    @Test func nextWrapsPastTheEnd() {
        #expect(DrawingTextFind.next(current: nil, total: 3) == 0)
        #expect(DrawingTextFind.next(current: 0, total: 3) == 1)
        #expect(DrawingTextFind.next(current: 2, total: 3) == 0)
        #expect(DrawingTextFind.next(current: nil, total: 0) == nil)
    }

    @Test func previousWrapsPastTheStart() {
        #expect(DrawingTextFind.previous(current: nil, total: 3) == 2)
        #expect(DrawingTextFind.previous(current: 0, total: 3) == 2)
        #expect(DrawingTextFind.previous(current: 2, total: 3) == 1)
        #expect(DrawingTextFind.previous(current: nil, total: 0) == nil)
    }

    @Test func statusReadsNofM() {
        #expect(DrawingTextFind.status(current: 2, total: 12) == "3 of 12")
        #expect(DrawingTextFind.status(current: nil, total: 0) == "")
        #expect(DrawingTextFind.status(current: 0, total: 1) == "1 of 1")
    }
}
