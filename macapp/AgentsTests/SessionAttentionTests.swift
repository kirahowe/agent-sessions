import XCTest
@testable import Agents

/// Exhaustive coverage of `SessionAttention.reduce` against every cell of
/// the transition table in `design/session-attention.md`, plus the three
/// consequences that table's doc comment calls out by name (bell can only
/// raise, raises drop while attended, attending clears unstructured but not
/// structured state). No `@MainActor`: the reducer is a pure static
/// function over Foundation-only types, so these tests need no store, spy,
/// or terminal machinery at all — see `ToolPreflightTests` for the same
/// pattern applied to another pure function.
final class SessionAttentionTests: XCTestCase {

    // MARK: - 1

    func test01_structuredSetFromVirginStateSetsActivityAndLatches() {
        let next = SessionAttention.reduce(.init(), .structured(.set(.blocked)))

        XCTAssertEqual(next.activity, .blocked, "a fresh session's first structured payload must set the indicator, or the very first permission prompt an agent reports would show nothing")
        XCTAssertTrue(next.isStructured, "the latch must engage on the very first structured message, not just on some later one, or an unstructured signal arriving next would wrongly get to reclassify this session")
    }

    // MARK: - 2

    func test02_structuredClearFromVirginStateClearsActivityAndLatches() {
        let next = SessionAttention.reduce(.init(), .structured(.clear))

        XCTAssertNil(next.activity, "a structured clear on a session with no prior activity must leave the indicator off")
        XCTAssertTrue(next.isStructured, "a structured .clear latches exactly like a structured .set does — a hook that only ever sends clears (e.g. a script that never reports .blocked) must still be trusted over classification for that session")
    }

    // MARK: - 3

    func test03_structuredSetOnAlreadyLatchedStateUpdatesActivity() {
        let latched = SessionAttention.reduce(.init(), .structured(.set(.blocked)))

        let next = SessionAttention.reduce(latched, .structured(.set(.yourTurn)))

        XCTAssertEqual(next.activity, .yourTurn, "the hook must be able to move a session from blocked to your-turn once the permission prompt is answered — the latch says 'trust this source,' not 'freeze the first value it sent'")
        XCTAssertTrue(next.isStructured, "the latch must stay engaged across repeated structured messages, not reset")
    }

    // MARK: - 4

    func test04_structuredClearOnAlreadyLatchedStateClearsActivity() {
        let latched = SessionAttention.reduce(.init(), .structured(.set(.blocked)))

        let next = SessionAttention.reduce(latched, .structured(.clear))

        XCTAssertNil(next.activity, "the hook's own clear must still work on a session it has already latched — the whole point of the hook path is that it stays authoritative for that session's whole life")
    }

    // MARK: - 5

    func test05_notificationOnUnlatchedUnattendedStateClassifiesBlockedCue() {
        let next = SessionAttention.reduce(.init(), .notification(title: "Claude Code", body: "Claude needs your permission to use Bash"))

        XCTAssertEqual(next.activity, .blocked, "an agent with no hook installed that emits a permission-prompt notification must still raise the red indicator, or the entire headline feature (lighting up agents without a hook) does nothing for the exact case it exists for")
    }

    // MARK: - 6

    func test06_notificationOnUnlatchedUnattendedStateClassifiesYourTurnCue() {
        let next = SessionAttention.reduce(.init(), .notification(title: "Claude Code", body: "Claude is waiting for your input"))

        XCTAssertEqual(next.activity, .yourTurn, "a turn-end notification from a hookless agent must raise the gold dot, or every Gemini CLI / plain Claude Code session would sit silent forever with no indicator at all")
    }

    // MARK: - 7

    func test07_notificationOnLatchedStateIsANoOpEvenWhenTextWouldClassifyOppositely() {
        let latched = SessionAttention.reduce(.init(), .structured(.set(.yourTurn)))

        let next = SessionAttention.reduce(latched, .notification(title: "Claude Code", body: "Claude needs your permission to use Bash"))

        XCTAssertEqual(next.activity, .yourTurn, "once a session has proven it speaks the structured protocol, a free-text notification — even one whose wording would classify as blocked — must never override it; letting it through here is exactly the dual-path suppression bug (cmux #2322) this design exists to avoid")
        XCTAssertTrue(next.isStructured)
    }

    // MARK: - 8

    func test08_notificationWhileAttendedIsANoOp() {
        let attended = SessionAttention.reduce(.init(), .attentionChanged(isAttended: true))

        let next = SessionAttention.reduce(attended, .notification(title: "Claude Code", body: "Claude needs your permission to use Bash"))

        XCTAssertNil(next.activity, "a notification for a session the user is already looking at must not light up a row they're staring at — and since no later selection change would ever clear it, a raise here would stay lit forever")
    }

    // MARK: - 9

    func test09_bellOnVirginStateRaisesYourTurn() {
        let next = SessionAttention.reduce(.init(), .bell)

        XCTAssertEqual(next.activity, .yourTurn, "a bare bell from an agent with no other signal must still raise something — a bell carries no text to classify, so the gold dot is the only honest guess available")
    }

    // MARK: - 10

    func test10_bellNeverDowngradesAnExistingBlockedToYourTurn() {
        // Reached the realistic way: a notification classifies to .blocked
        // while unstructured (a permission prompt with no hook installed),
        // and only afterward does the terminal also emit a bell.
        let blocked = SessionAttention.reduce(.init(), .notification(title: "Claude Code", body: "Claude needs your permission to use Bash"))
        XCTAssertEqual(blocked.activity, .blocked)

        let next = SessionAttention.reduce(blocked, .bell)

        XCTAssertEqual(next.activity, .blocked, "a bell arriving after a permission prompt was already classified must never downgrade the red pulse to a gold dot — that would silently tell the user an open permission prompt has been resolved when it hasn't, right as they're deciding whether it's safe to ignore the row")
    }

    // MARK: - 11

    func test11_bellOnLatchedStateIsANoOp() {
        let latched = SessionAttention.reduce(.init(), .structured(.set(.blocked)))

        let next = SessionAttention.reduce(latched, .bell)

        XCTAssertEqual(next.activity, .blocked, "a bell must not be able to touch a session the hook already speaks for — an errant BEL byte must never be able to move state the hook controls")
    }

    // MARK: - 12

    func test12_bellWhileAttendedIsANoOp() {
        let attended = SessionAttention.reduce(.init(), .attentionChanged(isAttended: true))

        let next = SessionAttention.reduce(attended, .bell)

        XCTAssertNil(next.activity, "a bell for a session the user is already looking at must not light up the row they're staring at, same as a notification")
    }

    // MARK: - 13

    func test13_workingClearsAnUnlatchedActivity() {
        let raised = AttentionState(activity: .yourTurn)

        let next = SessionAttention.reduce(raised, .working)

        XCTAssertNil(next.activity, "once the agent is demonstrably busy again, a stale unstructured raise must be withdrawn — otherwise the indicator would keep telling the user 'your turn' about a turn the agent has already resumed")
    }

    // MARK: - 14

    func test14_workingOnLatchedStateIsANoOp() {
        let latched = SessionAttention.reduce(.init(), .structured(.set(.blocked)))

        let next = SessionAttention.reduce(latched, .working)

        XCTAssertEqual(next.activity, .blocked, "a structured .blocked must survive the agent's own progress reports — an agent can be busy computing AND still sitting on an unanswered permission prompt from three turns ago, and only the hook gets to resolve that, never a generic busy heuristic")
    }

    // MARK: - 15

    func test15_attentionChangedTrueClearsAnUnlatchedActivityAndSetsIsAttended() {
        let raised = AttentionState(activity: .yourTurn)

        let next = SessionAttention.reduce(raised, .attentionChanged(isAttended: true))

        XCTAssertNil(next.activity, "selecting a session the user was told needs attention must clear the indicator — 'looked at it' is the only honest clear available without a hook, and leaving the dot lit after they've already looked would train them to ignore it")
        XCTAssertTrue(next.isAttended)
    }

    // MARK: - 16

    func test16_attentionChangedTrueOnLatchedStateSetsIsAttendedButLeavesActivityAlone() {
        let latched = SessionAttention.reduce(.init(), .structured(.set(.blocked)))

        let next = SessionAttention.reduce(latched, .attentionChanged(isAttended: true))

        XCTAssertEqual(next.activity, .blocked, "selecting a session that is genuinely still blocked (the hook says so) must not clear the red pulse — going dark while the agent is actually still waiting on a permission prompt would be a lie the user could act on by walking away")
        XCTAssertTrue(next.isAttended)
    }

    // MARK: - 17

    func test17_attentionChangedFalseClearsIsAttendedOnUnlatchedStateAndLeavesActivityAlone() {
        let attended = AttentionState(activity: .yourTurn, isAttended: true)

        let next = SessionAttention.reduce(attended, .attentionChanged(isAttended: false))

        XCTAssertFalse(next.isAttended)
        XCTAssertEqual(next.activity, .yourTurn, "deselecting a session must not itself change or clear its activity — only the signals in the other cases of this table decide the indicator; attention tracking is a separate concern")
    }

    // MARK: - 18

    func test18_attentionChangedFalseClearsIsAttendedOnLatchedStateAndLeavesActivityAlone() {
        let attended = AttentionState(activity: .blocked, isStructured: true, isAttended: true)

        let next = SessionAttention.reduce(attended, .attentionChanged(isAttended: false))

        XCTAssertFalse(next.isAttended)
        XCTAssertEqual(next.activity, .blocked, "deselecting a still-blocked session must not touch its activity either — the same non-interference as the unlatched case, regardless of which source is authoritative")
    }

    // MARK: - 19

    /// The latch is permanent for the session's whole life, not scoped to
    /// suppressing just the signal that follows it. This is the test that
    /// would catch a reducer accidentally re-deriving `isStructured` from
    /// the incoming signal instead of carrying it forward on `state`.
    func test19_structuredStateSurvivesAnyNumberOfSubsequentUnstructuredSignals() {
        var state = SessionAttention.reduce(.init(), .structured(.set(.blocked)))
        XCTAssertTrue(state.isStructured)

        state = SessionAttention.reduce(state, .notification(title: "Claude Code", body: "Claude is waiting for your input"))
        XCTAssertEqual(state.activity, .blocked, "a notification arriving well after the latch engaged must still be ignored")

        state = SessionAttention.reduce(state, .bell)
        XCTAssertEqual(state.activity, .blocked, "a bell arriving well after the latch engaged must still be ignored")

        state = SessionAttention.reduce(state, .working)
        XCTAssertEqual(state.activity, .blocked, "a working signal arriving well after the latch engaged must still be ignored")

        XCTAssertTrue(state.isStructured, "the latch itself must never turn back off, no matter how many unstructured signals it has absorbed")
    }
}
