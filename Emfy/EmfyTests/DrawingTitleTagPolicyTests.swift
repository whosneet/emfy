import Foundation
import Testing

// A1b Part 1: generation and display gating, plus the content-hash cache key.

@Suite struct DrawingTitleTagPolicyTests {

    @Test func generatesOnlyWhenEnabledNonPrivateAndModelAvailable() {
        #expect(DrawingTitleTagPolicy.shouldGenerate(aiEnabled: true, privateMode: false, modelAvailable: true))
        #expect(!DrawingTitleTagPolicy.shouldGenerate(aiEnabled: false, privateMode: false, modelAvailable: true))
        #expect(!DrawingTitleTagPolicy.shouldGenerate(aiEnabled: true, privateMode: true, modelAvailable: true))
        #expect(!DrawingTitleTagPolicy.shouldGenerate(aiEnabled: true, privateMode: false, modelAvailable: false))
    }

    @Test func displaysOnlyWhenEnabledAndNonPrivate() {
        #expect(DrawingTitleTagPolicy.shouldDisplay(aiEnabled: true, privateMode: false))
        #expect(!DrawingTitleTagPolicy.shouldDisplay(aiEnabled: false, privateMode: false))
        #expect(!DrawingTitleTagPolicy.shouldDisplay(aiEnabled: true, privateMode: true))
    }

    @Test func requiresTwentyCharactersOfText() {
        #expect(!DrawingTitleTagPolicy.hasEnoughText(characterCount: 0))
        #expect(!DrawingTitleTagPolicy.hasEnoughText(characterCount: 19))
        #expect(DrawingTitleTagPolicy.hasEnoughText(characterCount: 20))
        #expect(DrawingTitleTagPolicy.hasEnoughText(characterCount: 200))
    }

    @Test func contentHashIsStableAndContentSensitive() {
        let a = Data([1, 2, 3, 4])
        let b = Data([1, 2, 3, 4])
        let c = Data([1, 2, 3, 5])
        #expect(DrawingContentHash.hash(a) == DrawingContentHash.hash(b))
        #expect(DrawingContentHash.hash(a) != DrawingContentHash.hash(c))
        // SHA-256 hex is 64 characters.
        #expect(DrawingContentHash.hash(a).count == 64)
    }
}
