import XCTest
@testable import Agents

/// `TerminalReadiness` is the pure state machine behind "is this pane safe to
/// type a line into." It was extracted from `TerminalCenter.PaneEntry` so the
/// two gates — surface exists, shell at prompt — and the generation
/// bookkeeping that keeps a stale fallback timer from speaking for a later
/// surface can be exercised directly, with no live libghostty surface. The
/// restore banner's whole correctness rests on `isReady`, and every edge
/// below is one the banner would otherwise hit only intermittently against a
/// real terminal.
final class TerminalReadinessTests: XCTestCase {
    func testStartsNotReady() {
        let readiness = TerminalReadiness()
        XCTAssertFalse(
            readiness.isReady,
            "a fresh pane has no surface and no prompt — typing into it would go nowhere"
        )
        XCTAssertFalse(readiness.surfaceAttached)
        XCTAssertFalse(readiness.promptSeen)
    }

    func testSurfaceAloneIsNotReady() {
        var readiness = TerminalReadiness()
        readiness.attach()
        XCTAssertTrue(readiness.surfaceAttached)
        XCTAssertFalse(
            readiness.isReady,
            "a surface exists but no shell is at its prompt yet — a full line typed now lands while login still owns the cooked tty and is echoed raw"
        )
    }

    func testPromptBeforeSurfaceIsNotReady() {
        var readiness = TerminalReadiness()
        readiness.notePrompt()
        XCTAssertFalse(
            readiness.isReady,
            "a prompt signal with no surface must not read as ready — there is no pty to type into until the surface is built"
        )
    }

    func testReadyOnceSurfaceAndPromptBothArrive() {
        var readiness = TerminalReadiness()
        readiness.attach()
        readiness.notePrompt()
        XCTAssertTrue(
            readiness.isReady,
            "surface plus a real prompt is the safe case the banner waits for"
        )
    }

    func testReadyIsOrderIndependent() {
        var promptFirst = TerminalReadiness()
        promptFirst.notePrompt()
        promptFirst.attach()
        XCTAssertTrue(
            promptFirst.isReady,
            "the prompt title can arrive before or after the surface attaches — either order must reach ready, or a real race would strand the banner"
        )
    }

    func testFallbackStandsInForAMissingPromptTitle() {
        var readiness = TerminalReadiness()
        let generation = readiness.attach()
        XCTAssertTrue(
            readiness.noteFallbackElapsed(generation: generation),
            "a shell that never titles itself must still become ready when the fallback fires"
        )
        XCTAssertTrue(readiness.isReady)
    }

    func testNotePromptReportsOnlyTheFirstEdge() {
        var readiness = TerminalReadiness()
        XCTAssertTrue(
            readiness.notePrompt(),
            "the first title is the first prompt — the caller acts on this edge to deliver a waiting banner exactly once"
        )
        XCTAssertFalse(
            readiness.notePrompt(),
            "later titles are not new prompts — reporting them as edges would re-deliver the banner on every prompt the shell prints"
        )
    }

    func testFallbackFromAStaleGenerationIsIgnored() {
        var readiness = TerminalReadiness()
        let firstGeneration = readiness.attach()
        readiness.detach()
        let secondGeneration = readiness.attach()
        XCTAssertNotEqual(firstGeneration, secondGeneration)

        XCTAssertFalse(
            readiness.noteFallbackElapsed(generation: firstGeneration),
            "a fallback timer armed for a surface that has since been torn down and rebuilt must not fire — it would declare the NEW surface's shell ready before it has reached a prompt"
        )
        XCTAssertFalse(
            readiness.isReady,
            "the stale fallback must leave the rebuilt surface waiting for its own prompt signal"
        )
    }

    func testFallbackForTheCurrentGenerationStillFiresAfterAStaleOneIsRejected() {
        var readiness = TerminalReadiness()
        let firstGeneration = readiness.attach()
        readiness.detach()
        let secondGeneration = readiness.attach()

        XCTAssertFalse(readiness.noteFallbackElapsed(generation: firstGeneration))
        XCTAssertTrue(
            readiness.noteFallbackElapsed(generation: secondGeneration),
            "rejecting the stale timer must not poison the live one — the current surface's own fallback must still be able to fire"
        )
        XCTAssertTrue(readiness.isReady)
    }

    func testFallbackWithNoSurfaceIsIgnored() {
        var readiness = TerminalReadiness()
        let generation = readiness.attach()
        readiness.detach()
        XCTAssertFalse(
            readiness.noteFallbackElapsed(generation: generation),
            "once the surface is gone, its fallback must not fire — there is nothing to be ready for"
        )
    }

    func testDetachResetsBothPromptSignals() {
        var readiness = TerminalReadiness()
        let generation = readiness.attach()
        readiness.notePrompt()
        readiness.noteFallbackElapsed(generation: generation)
        XCTAssertTrue(readiness.isReady)

        readiness.detach()
        XCTAssertFalse(readiness.surfaceAttached)
        XCTAssertFalse(readiness.promptSeen)
        XCTAssertFalse(readiness.promptFallbackElapsed)
        XCTAssertFalse(
            readiness.isReady,
            "after a detach the next surface's shell starts from scratch — carrying the old prompt state over would type the banner into a shell that is not at its prompt"
        )
    }

    func testReattachAfterDetachNeedsAFreshPrompt() {
        var readiness = TerminalReadiness()
        readiness.attach()
        readiness.notePrompt()
        readiness.detach()

        readiness.attach()
        XCTAssertFalse(
            readiness.isReady,
            "a rebuilt surface is a fresh shell — it must reach its own prompt before the pane is ready again"
        )
        XCTAssertTrue(readiness.notePrompt())
        XCTAssertTrue(readiness.isReady)
    }

    func testFallbackIsIdempotentForItsGeneration() {
        var readiness = TerminalReadiness()
        let generation = readiness.attach()
        XCTAssertTrue(readiness.noteFallbackElapsed(generation: generation))
        XCTAssertFalse(
            readiness.noteFallbackElapsed(generation: generation),
            "a second fire of the same fallback is a no-op — it is already elapsed, and re-reporting the edge could re-trigger a once-only delivery"
        )
    }
}
