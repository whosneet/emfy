import CoreGraphics
import Testing
@testable import EMFEdit

// MARK: - Edit grounding semantics (X2b item 0)

@Suite struct EditSemanticsTests {

    private func rgb(_ v: UInt32) -> SceneColor {
        SceneColor(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    // MARK: Colour naming

    @Test func namesPrimariesAndNeutrals() {
        #expect(DrawingColorNames.name(for: rgb(0x000000)) == "black")
        #expect(DrawingColorNames.name(for: rgb(0xFFFFFF)) == "white")
        #expect(DrawingColorNames.name(for: rgb(0x1F3A93)) == "dark blue")
        // A low-saturation mid-grey names as a grey, not a hue.
        #expect(DrawingColorNames.name(for: rgb(0x999999)).contains("grey"))
    }

    @Test func pureBlueNamesAsBlueNotDarkBlue() {
        // #0000FF is a bright blue; naming it should land on "blue", and crucially the
        // curated "dark blue" is a DIFFERENT, darker value.
        let darkBlue = DrawingColorNames.color(forPhrase: "dark blue")!
        #expect(DrawingColorMath.deltaE(darkBlue, rgb(0x0000FF)) > 10)
    }

    // MARK: Colour-word resolution

    @Test func darkBlueResolvesAwayFromPureBlue() {
        let resolved = DrawingColorNames.color(forPhrase: "dark blue")
        #expect(resolved != nil)
        // It is a blue (ΔE closer to #1F3A93 than to pure #0000FF) and noticeably dark.
        let c = resolved!
        #expect(DrawingColorMath.deltaE(c, rgb(0x1F3A93)) < DrawingColorMath.deltaE(c, rgb(0x0000FF)))
        #expect(DrawingColorMath.toLab(c).L < 50)
    }

    @Test func resolvesModifiersAndNeutrals() {
        #expect(DrawingColorNames.color(forPhrase: "navy") != nil)
        #expect(DrawingColorNames.color(forPhrase: "bright red") != nil)
        #expect(DrawingColorNames.color(forPhrase: "light green") != nil)
        #expect(DrawingColorNames.color(forPhrase: "dark grey") != nil)
        #expect(DrawingColorNames.color(forPhrase: "black")?.red == 0)
        // No colour word → nil (not a false match).
        #expect(DrawingColorNames.color(forPhrase: "bigger") == nil)
        #expect(DrawingColorNames.color(forPhrase: "") == nil)
    }

    @Test func lightIsLighterThanDark() {
        let light = DrawingColorNames.color(forPhrase: "light blue")!
        let dark = DrawingColorNames.color(forPhrase: "dark blue")!
        #expect(DrawingColorMath.toLab(light).L > DrawingColorMath.toLab(dark).L)
    }

    @Test func promptGuidanceNamesDarkBlue() {
        let guidance = DrawingColorNames.promptGuidance()
        #expect(guidance.contains("dark blue #1F3A93"))
        #expect(guidance.contains("#0000FF"))   // warns against the pure primary
    }

    // MARK: ΔE

    @Test func deltaEIdentityIsZero() {
        #expect(DrawingColorMath.deltaE(rgb(0x1F3A93), rgb(0x1F3A93)) < 0.001)
    }

    @Test func deltaEOrdersByPerception() {
        let target = rgb(0x1F3A93)
        let near = rgb(0x24409A)
        let far = rgb(0xE67E22)
        #expect(DrawingColorMath.deltaE(target, near) < DrawingColorMath.deltaE(target, far))
    }

    // MARK: Text role classification

    @Test func classifiesHeadingsBodyAndSmall() {
        let runs = [
            TextRoleClassifier.Run(id: 1, pointSize: 24, top: 10),
            TextRoleClassifier.Run(id: 2, pointSize: 24, top: 60),
            TextRoleClassifier.Run(id: 3, pointSize: 12, top: 120),
            TextRoleClassifier.Run(id: 4, pointSize: 12, top: 150),
            TextRoleClassifier.Run(id: 5, pointSize: 7, top: 300),
        ]
        let roles = TextRoleClassifier.classify(runs)
        #expect(roles[1] == .heading)
        #expect(roles[2] == .heading)
        #expect(roles[3] == .body)
        #expect(roles[4] == .body)
        #expect(roles[5] == .small)
    }

    @Test func uniformSizesAreAllBody() {
        let runs = (1...3).map { TextRoleClassifier.Run(id: $0, pointSize: 12, top: Double($0) * 20) }
        let roles = TextRoleClassifier.classify(runs)
        #expect(roles.values.allSatisfy { $0 == .body })
    }

    @Test func singleRunIsBody() {
        let roles = TextRoleClassifier.classify([TextRoleClassifier.Run(id: 9, pointSize: 40, top: 5)])
        #expect(roles[9] == .body)
    }

    @Test func titleIsLargestTopmost() {
        let runs = [
            TextRoleClassifier.Run(id: 1, pointSize: 28, top: 50),
            TextRoleClassifier.Run(id: 2, pointSize: 28, top: 10),   // same size, higher
            TextRoleClassifier.Run(id: 3, pointSize: 12, top: 5),
        ]
        #expect(TextRoleClassifier.titleID(runs) == 2)
    }

    @Test func twoEqualHeadingsAreBothHeadingsNoTitle() {
        // Two equal large runs plus smaller body: both are headings, and there is NO unique
        // title (so neither is split off as the title). This is the "make the headings dark
        // blue" grounding that previously mislabelled one heading as a title.
        let runs = [
            TextRoleClassifier.Run(id: 0, pointSize: 20, top: 70),
            TextRoleClassifier.Run(id: 1, pointSize: 20, top: 110),
            TextRoleClassifier.Run(id: 2, pointSize: 11, top: 150),
            TextRoleClassifier.Run(id: 3, pointSize: 11, top: 180),
        ]
        let roles = TextRoleClassifier.classify(runs)
        #expect(roles[0] == .heading)
        #expect(roles[1] == .heading)
        #expect(roles[2] == .body)
        #expect(roles[3] == .body)
        #expect(TextRoleClassifier.uniqueTitleID(runs) == nil)
    }

    @Test func uniqueTitleIsDetectedWhenStrictlyLargest() {
        let runs = [
            TextRoleClassifier.Run(id: 7, pointSize: 28, top: 50),
            TextRoleClassifier.Run(id: 8, pointSize: 12, top: 110),
            TextRoleClassifier.Run(id: 9, pointSize: 12, top: 140),
        ]
        #expect(TextRoleClassifier.uniqueTitleID(runs) == 7)
    }
}
