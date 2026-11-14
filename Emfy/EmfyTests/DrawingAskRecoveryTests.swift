import Foundation
import Testing

// F2: the Ask flow re-grounds in a fresh session when there is none yet, when the
// transcript reaches the turn cap, or after a context-window overflow. The overflow
// DETECTION is covered by DrawingAIEngineErrorTests (isContextOverflow over both
// error types); here is the cap / re-ground decision, extracted as a pure helper so
// it is unit-testable without driving the real on-device session.
@Suite("DrawingAskModel re-ground decision (F2)")
struct DrawingAskRecoveryTests {

    @Test("A question with no live session must ground")
    func noSessionGrounds() {
        #expect(DrawingAskModel.shouldReground(hasSession: false, groundedTurns: 0))
        #expect(DrawingAskModel.shouldReground(hasSession: false, groundedTurns: 5))
    }

    @Test("A live session continues until the transcript cap, then re-grounds")
    func capForcesReground() {
        #expect(!DrawingAskModel.shouldReground(hasSession: true, groundedTurns: 0))
        #expect(!DrawingAskModel.shouldReground(hasSession: true, groundedTurns: DrawingAskModel.maxGroundedTurns - 1))
        #expect(DrawingAskModel.shouldReground(hasSession: true, groundedTurns: DrawingAskModel.maxGroundedTurns))
        #expect(DrawingAskModel.shouldReground(hasSession: true, groundedTurns: DrawingAskModel.maxGroundedTurns + 3))
    }

    @Test("The cap is a sane positive bound and the reset notice is non-empty")
    func capAndNoticeConfigured() {
        #expect(DrawingAskModel.maxGroundedTurns > 0 && DrawingAskModel.maxGroundedTurns <= 50)
        #expect(!DrawingAskModel.contextResetNotice.isEmpty)
    }
}
