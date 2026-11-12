import CoreGraphics
import Foundation
import Testing

// F1 unit tests for the pure print-view fit maths (`PrintLayout`): the Fit-to-page
// and Actual-size draw rects (centred, aspect preserved), and the orientation picked
// from the drawing's aspect.

@Suite struct PrintLayoutTests {

    // A US Letter printable area (points), origin at a non-zero margin so the tests
    // also prove the rect is positioned relative to `printable.origin`, not (0,0).
    private let printable = CGRect(x: 18, y: 18, width: 576, height: 756)

    // MARK: orientation

    @Test func orientationIsLandscapeWhenWider() {
        #expect(PrintLayout.orientation(for: CGSize(width: 800, height: 400)) == .landscape)
    }

    @Test func orientationIsPortraitWhenTallerOrSquare() {
        #expect(PrintLayout.orientation(for: CGSize(width: 400, height: 800)) == .portrait)
        #expect(PrintLayout.orientation(for: CGSize(width: 500, height: 500)) == .portrait)
    }

    // MARK: fit to page

    @Test func fitScalesToFillTheLimitingAxisAndCentres() {
        // A 2:1 drawing in a 576×756 area is limited by width: scale = 576/1000.
        let rect = PrintLayout.drawRect(
            naturalSize: CGSize(width: 1000, height: 500), printable: printable, scaling: .fitToPage)
        #expect(abs(rect.width - 576) < 0.001)
        #expect(abs(rect.height - 288) < 0.001)
        // Centred in the printable area.
        #expect(abs(rect.midX - printable.midX) < 0.001)
        #expect(abs(rect.midY - printable.midY) < 0.001)
        // Fits inside the printable area.
        #expect(rect.minX >= printable.minX - 0.001)
        #expect(rect.maxX <= printable.maxX + 0.001)
    }

    @Test func fitUpscalesASmallDrawing() {
        // A tiny drawing fills the page (Fit scales up), aspect preserved.
        let rect = PrintLayout.drawRect(
            naturalSize: CGSize(width: 100, height: 50), printable: printable, scaling: .fitToPage)
        #expect(rect.width > 100)
        #expect(abs(rect.width / rect.height - 2) < 0.001)
    }

    @Test func fitPreservesAspectWhenHeightLimited() {
        // A tall 1:2 drawing is limited by height: scale = 756/1000.
        let rect = PrintLayout.drawRect(
            naturalSize: CGSize(width: 500, height: 1000), printable: printable, scaling: .fitToPage)
        #expect(abs(rect.height - 756) < 0.001)
        #expect(abs(rect.width - 378) < 0.001)
    }

    // MARK: actual size

    @Test func actualSizeKeepsNaturalPointSizeCentred() {
        let natural = CGSize(width: 200, height: 300)
        let rect = PrintLayout.drawRect(naturalSize: natural, printable: printable, scaling: .actualSize)
        #expect(rect.size == natural)
        #expect(abs(rect.midX - printable.midX) < 0.001)
        #expect(abs(rect.midY - printable.midY) < 0.001)
    }

    @Test func actualSizeLargerThanPageOverflowsCentred() {
        // A drawing bigger than the page stays natural size and is centred, so it
        // overflows symmetrically (the page clips it on print).
        let natural = CGSize(width: 2000, height: 2000)
        let rect = PrintLayout.drawRect(naturalSize: natural, printable: printable, scaling: .actualSize)
        #expect(rect.size == natural)
        #expect(rect.minX < printable.minX)
        #expect(rect.maxX > printable.maxX)
    }

    // MARK: degenerate input

    @Test func zeroSizedDrawingNeverDividesByZero() {
        let rect = PrintLayout.drawRect(
            naturalSize: .zero, printable: printable, scaling: .fitToPage)
        #expect(rect.width > 0)
        #expect(rect.height > 0)
        #expect(rect.width.isFinite)
        #expect(rect.height.isFinite)
    }
}
