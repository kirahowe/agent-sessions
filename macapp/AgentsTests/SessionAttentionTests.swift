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
/// Fixed clock readings for the reducer's `at:` parameter. Real dates,
/// distinct and ordered, so a test can tell "stamped now" from "left as it
/// was" — see `AttentionState.since`.
private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
private let t1 = t0.addingTimeInterval(60)
private let t2 = t1.addingTimeInterval(60)

/// The reducer with the clock defaulted to `t0`: the transition-table cases
/// below don't care what time it is, only the `since` cases do, and those
/// pass a later reading explicitly.
private func reduce(_ state: AttentionState, _ signal: AttentionSignal, at now: Date = t0) -> AttentionState {
    SessionAttention.reduce(state, signal, at: now)
}

final class SessionAttentionTests: XCTestCase {

    // MARK: - 1

    func test01_structuredSetFromVirginStateSetsActivityAndLatches() {
        let next = reduce(.init(), .structured(.set(.blocked)))

        XCTAssertEqual(next.activity, .blocked, "a fresh session's first structured payload must set the indicator, or the very first permission prompt an agent reports would show nothing")
        XCTAssertTrue(next.isStructured, "the latch must engage on the very first structured message, not just on some later one, or an unstructured signal arriving next would wrongly get to reclassify this session")
    }

    // MARK: - 2

    func test02_structuredClearFromVirginStateClearsActivityAndLatches() {
        let next = reduce(.init(), .structured(.clear))

        XCTAssertNil(next.activity, "a structured clear on a session with no prior activity must leave the indicator off")
        XCTAssertTrue(next.isStructured, "a structured .clear latches exactly like a structured .set does — a hook that only ever sends clears (e.g. a script that never reports .blocked) must still be trusted over classification for that session")
    }

    // MARK: - 3

    func test03_structuredSetOnAlreadyLatchedStateUpdatesActivity() {
        let latched = reduce(.init(), .structured(.set(.blocked)))

        let next = reduce(latched, .structured(.set(.yourTurn)))

        XCTAssertEqual(next.activity, .yourTurn, "the hook must be able to move a session from blocked to your-turn once the permission prompt is answered — the latch says 'trust this source,' not 'freeze the first value it sent'")
        XCTAssertTrue(next.isStructured, "the latch must stay engaged across repeated structured messages, not reset")
    }

    // MARK: - 4

    func test04_structuredClearOnAlreadyLatchedStateClearsActivity() {
        let latched = reduce(.init(), .structured(.set(.blocked)))

        let next = reduce(latched, .structured(.clear))

        XCTAssertNil(next.activity, "the hook's own clear must still work on a session it has already latched — the whole point of the hook path is that it stays authoritative for that session's whole life")
    }

    // MARK: - 5

    func test05_notificationOnUnlatchedUnattendedStateClassifiesBlockedCue() {
        let next = reduce(.init(), .notification(title: "Claude Code", body: "Claude needs your permission to use Bash"))

        XCTAssertEqual(next.activity, .blocked, "an agent with no hook installed that emits a permission-prompt notification must still raise the red indicator, or the entire headline feature (lighting up agents without a hook) does nothing for the exact case it exists for")
    }

    // MARK: - 6

    func test06_notificationOnUnlatchedUnattendedStateClassifiesYourTurnCue() {
        let next = reduce(.init(), .notification(title: "Claude Code", body: "Claude is waiting for your input"))

        XCTAssertEqual(next.activity, .yourTurn, "a turn-end notification from a hookless agent must raise the gold dot, or every Gemini CLI / plain Claude Code session would sit silent forever with no indicator at all")
    }

    // MARK: - 7

    func test07_notificationOnLatchedStateIsANoOpEvenWhenTextWouldClassifyOppositely() {
        let latched = reduce(.init(), .structured(.set(.yourTurn)))

        let next = reduce(latched, .notification(title: "Claude Code", body: "Claude needs your permission to use Bash"))

        XCTAssertEqual(next.activity, .yourTurn, "once a session has proven it speaks the structured protocol, a free-text notification — even one whose wording would classify as blocked — must never override it; letting it through here is exactly the dual-path suppression bug (cmux #2322) this design exists to avoid")
        XCTAssertTrue(next.isStructured)
    }

    // MARK: - 8

    func test08_notificationWhileAttendedIsANoOp() {
        let attended = reduce(.init(), .attentionChanged(isAttended: true))

        let next = reduce(attended, .notification(title: "Claude Code", body: "Claude needs your permission to use Bash"))

        XCTAssertNil(next.activity, "a notification for a session the user is already looking at must not light up a row they're staring at — and since no later selection change would ever clear it, a raise here would stay lit forever")
    }

    // MARK: - 9

    func test09_bellOnVirginStateRaisesYourTurn() {
        let next = reduce(.init(), .bell)

        XCTAssertEqual(next.activity, .yourTurn, "a bare bell from an agent with no other signal must still raise something — a bell carries no text to classify, so the gold dot is the only honest guess available")
    }

    // MARK: - 10

    func test10_bellNeverDowngradesAnExistingBlockedToYourTurn() {
        // Reached the realistic way: a notification classifies to .blocked
        // while unstructured (a permission prompt with no hook installed),
        // and only afterward does the terminal also emit a bell.
        let blocked = reduce(.init(), .notification(title: "Claude Code", body: "Claude needs your permission to use Bash"))
        XCTAssertEqual(blocked.activity, .blocked)

        let next = reduce(blocked, .bell)

        XCTAssertEqual(next.activity, .blocked, "a bell arriving after a permission prompt was already classified must never downgrade the red pulse to a gold dot — that would silently tell the user an open permission prompt has been resolved when it hasn't, right as they're deciding whether it's safe to ignore the row")
    }

    // MARK: - 11

    func test11_bellOnLatchedStateIsANoOp() {
        let latched = reduce(.init(), .structured(.set(.blocked)))

        let next = reduce(latched, .bell)

        XCTAssertEqual(next.activity, .blocked, "a bell must not be able to touch a session the hook already speaks for — an errant BEL byte must never be able to move state the hook controls")
    }

    // MARK: - 12

    func test12_bellWhileAttendedIsANoOp() {
        let attended = reduce(.init(), .attentionChanged(isAttended: true))

        let next = reduce(attended, .bell)

        XCTAssertNil(next.activity, "a bell for a session the user is already looking at must not light up the row they're staring at, same as a notification")
    }

    // MARK: - 13

    func test13_workingClearsAnUnlatchedActivity() {
        let raised = AttentionState(activity: .yourTurn)

        let next = reduce(raised, .working)

        XCTAssertNil(next.activity, "once the agent is demonstrably busy again, a stale unstructured raise must be withdrawn — otherwise the indicator would keep telling the user 'your turn' about a turn the agent has already resumed")
    }

    // MARK: - 14

    func test14_workingOnLatchedStateIsANoOp() {
        let latched = reduce(.init(), .structured(.set(.blocked)))

        let next = reduce(latched, .working)

        XCTAssertEqual(next.activity, .blocked, "a structured .blocked must survive the agent's own progress reports — an agent can be busy computing AND still sitting on an unanswered permission prompt from three turns ago, and only the hook gets to resolve that, never a generic busy heuristic")
    }

    // MARK: - 15

    func test15_attentionChangedTrueClearsAnUnlatchedActivityAndSetsIsAttended() {
        let raised = AttentionState(activity: .yourTurn)

        let next = reduce(raised, .attentionChanged(isAttended: true))

        XCTAssertNil(next.activity, "selecting a session the user was told needs attention must clear the indicator — 'looked at it' is the only honest clear available without a hook, and leaving the dot lit after they've already looked would train them to ignore it")
        XCTAssertTrue(next.isAttended)
    }

    // MARK: - 16

    func test16_attentionChangedTrueOnLatchedStateSetsIsAttendedButLeavesActivityAlone() {
        let latched = reduce(.init(), .structured(.set(.blocked)))

        let next = reduce(latched, .attentionChanged(isAttended: true))

        XCTAssertEqual(next.activity, .blocked, "selecting a session that is genuinely still blocked (the hook says so) must not clear the red pulse — going dark while the agent is actually still waiting on a permission prompt would be a lie the user could act on by walking away")
        XCTAssertTrue(next.isAttended)
    }

    // MARK: - 17

    func test17_attentionChangedFalseClearsIsAttendedOnUnlatchedStateAndLeavesActivityAlone() {
        let attended = AttentionState(activity: .yourTurn, isAttended: true)

        let next = reduce(attended, .attentionChanged(isAttended: false))

        XCTAssertFalse(next.isAttended)
        XCTAssertEqual(next.activity, .yourTurn, "deselecting a session must not itself change or clear its activity — only the signals in the other cases of this table decide the indicator; attention tracking is a separate concern")
    }

    // MARK: - 18

    func test18_attentionChangedFalseClearsIsAttendedOnLatchedStateAndLeavesActivityAlone() {
        let attended = AttentionState(activity: .blocked, isStructured: true, isAttended: true)

        let next = reduce(attended, .attentionChanged(isAttended: false))

        XCTAssertFalse(next.isAttended)
        XCTAssertEqual(next.activity, .blocked, "deselecting a still-blocked session must not touch its activity either — the same non-interference as the unlatched case, regardless of which source is authoritative")
    }

    // MARK: - 19

    /// The latch is permanent for the session's whole life, not scoped to
    /// suppressing just the signal that follows it. This is the test that
    /// would catch a reducer accidentally re-deriving `isStructured` from
    /// the incoming signal instead of carrying it forward on `state`.
    func test19_structuredStateSurvivesAnyNumberOfSubsequentUnstructuredSignals() {
        var state = reduce(.init(), .structured(.set(.blocked)))
        XCTAssertTrue(state.isStructured)

        state = reduce(state, .notification(title: "Claude Code", body: "Claude is waiting for your input"))
        XCTAssertEqual(state.activity, .blocked, "a notification arriving well after the latch engaged must still be ignored")

        state = reduce(state, .bell)
        XCTAssertEqual(state.activity, .blocked, "a bell arriving well after the latch engaged must still be ignored")

        state = reduce(state, .working)
        XCTAssertEqual(state.activity, .blocked, "a working signal arriving well after the latch engaged must still be ignored")

        XCTAssertTrue(state.isStructured, "the latch itself must never turn back off, no matter how many unstructured signals it has absorbed")
    }

    // MARK: - 20: since — every raise stamps the clock it was given

    func test20_everyRaisingSignalStampsSinceWithTheClockItWasGiven() {
        XCTAssertEqual(reduce(.init(), .structured(.set(.blocked)), at: t1).since, t1, "a structured raise must record when it happened, or the dashboard has nothing to show an age from")
        XCTAssertEqual(reduce(.init(), .notification(title: "Claude Code", body: "Claude needs your permission to use Bash"), at: t1).since, t1, "a classified notification raise must be dated the same way as a structured one — the age is about the user's wait, not about which transport reported it")
        XCTAssertEqual(reduce(.init(), .bell, at: t1).since, t1, "a bell raise must be dated too")
        XCTAssertNil(reduce(.init(), .structured(.clear), at: t1).since, "a clear on a virgin state raises nothing, so there is nothing to date")
    }

    // MARK: - 21: since — a repeat of the same state keeps the original stamp

    func test21_repeatingTheSameActivityKeepsTheOriginalSince() {
        let raised = reduce(.init(), .structured(.set(.yourTurn)), at: t0)

        XCTAssertEqual(reduce(raised, .structured(.set(.yourTurn)), at: t1).since, t0, "a hook re-sending the state it already reported must not reset the age — the user has been waited on since the first report, and a timer that restarted on every repeat would keep telling them a stale row is fresh")

        let bellRaised = reduce(.init(), .bell, at: t0)
        XCTAssertEqual(reduce(bellRaised, .bell, at: t1).since, t0, "a second bell must not restart the age of a row the first bell already raised")
    }

    // MARK: - 22: since — moving between states restamps, clearing drops it

    func test22_changingActivityRestampsAndClearingDropsSince() {
        let waiting = reduce(.init(), .structured(.set(.yourTurn)), at: t0)

        let blocked = reduce(waiting, .structured(.set(.blocked)), at: t1)
        XCTAssertEqual(blocked.since, t1, "escalating from your-turn to blocked must date the escalation — 'blocked for 2m' is the honest age of the red state, not the older gold one")

        let backToWaiting = reduce(blocked, .structured(.set(.yourTurn)), at: t2)
        XCTAssertEqual(backToWaiting.since, t2, "de-escalating must restamp for the same reason: the activity value changed")

        XCTAssertNil(reduce(blocked, .structured(.clear), at: t2).since, "a structured clear must drop the timestamp along with the activity — `since` is defined as nil exactly when `activity` is")
        XCTAssertNil(reduce(reduce(.init(), .bell, at: t0), .working, at: t1).since, "an unstructured raise withdrawn by a working signal must drop its timestamp too")
        XCTAssertNil(reduce(reduce(.init(), .bell, at: t0), .attentionChanged(isAttended: true), at: t1).since, "an unstructured raise cleared by attending must drop its timestamp too")
    }

    // MARK: - 23: since — no-op transitions leave it untouched

    func test23_signalsThatLeaveActivityAloneLeaveSinceAlone() {
        let latched = reduce(.init(), .structured(.set(.blocked)), at: t0)

        XCTAssertEqual(reduce(latched, .notification(title: "Claude Code", body: "Claude is waiting for your input"), at: t1).since, t0, "a suppressed notification must not touch the age of a hook-controlled row")
        XCTAssertEqual(reduce(latched, .bell, at: t1).since, t0, "a suppressed bell must not touch it either")
        XCTAssertEqual(reduce(latched, .working, at: t1).since, t0, "a suppressed working signal must not touch it either")
        XCTAssertEqual(reduce(latched, .attentionChanged(isAttended: true), at: t1).since, t0, "attending a structured blocked row leaves its activity alone (test16), so it must leave the age alone as well — the user looking at a still-blocked row doesn't make it any less overdue")
        XCTAssertEqual(reduce(latched, .attentionChanged(isAttended: false), at: t1).since, t0, "deselecting must not touch it")

        let attended = reduce(.init(), .attentionChanged(isAttended: true), at: t0)
        XCTAssertNil(reduce(attended, .bell, at: t1).since, "a bell dropped because the row is attended raises nothing, so it must date nothing")
    }
}
