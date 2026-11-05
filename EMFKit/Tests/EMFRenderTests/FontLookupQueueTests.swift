import Foundation
import Testing
@testable import EMFRender

/// The bounded wait in `FontLookupQueue.run` (fix 5): a wedged font-service
/// lookup must not hang a sandboxed Quick Look extension forever (§8). On
/// timeout the call returns a pre-created fallback and reports it; a healthy
/// lookup still returns its real value.
@Suite("Font lookup queue timeout")
struct FontLookupQueueTests {

    @Test("a stalled lookup returns the fallback within the timeout and reports it")
    func stalledLookupFallsBack() {
        // A semaphore the test controls stands in for a wedged provider — it
        // blocks the queued body until the test releases it, so nothing sleeps a
        // fixed wall-clock time and the serial queue is freed before the test ends.
        let release = DispatchSemaphore(value: 0)
        var timedOut = false
        let clock = ContinuousClock()
        var result = ""
        let elapsed = clock.measure {
            result = FontLookupQueue.run(
                timeout: .milliseconds(200),
                fallback: "FALLBACK",
                onTimeout: { timedOut = true }
            ) {
                release.wait()   // a lookup that never gets its reply
                return "SLOW"
            }
        }
        #expect(result == "FALLBACK", "a timed-out lookup must return the pre-created fallback")
        #expect(timedOut, "onTimeout must fire on a stall")
        #expect(elapsed < .seconds(2), "run must not wait for the stalled body, took \(elapsed)")
        // Free the queued body so the shared serial queue is not left blocked.
        release.signal()
    }

    @Test("a fast lookup returns its real value, not the fallback")
    func fastLookupReturnsValue() {
        let result = FontLookupQueue.run(timeout: .seconds(5), fallback: "FALLBACK") { "REAL" }
        #expect(result == "REAL")
    }

    @Test("a late completion after a timeout is written harmlessly (no crash)")
    func lateCompletionIsSafe() {
        // The heap Box outlives the call: the body completes AFTER run returned the
        // fallback and writes into the orphaned box without trapping. Reaching the
        // end is the proof (a use-after-free would crash the process first).
        let release = DispatchSemaphore(value: 0)
        let first = FontLookupQueue.run(timeout: .milliseconds(100), fallback: 0) {
            release.wait()
            return 42
        }
        #expect(first == 0, "the stalled call returns the fallback")
        release.signal()            // the orphaned body now completes and writes its box
        Thread.sleep(forTimeInterval: 0.05)   // give it a moment to run
        let second = FontLookupQueue.run(fallback: -1) { 7 }
        #expect(second == 7, "the queue keeps working after a late completion")
    }
}
