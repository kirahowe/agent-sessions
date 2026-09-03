import XCTest
@testable import Agents

/// Coverage for `AgentDashboard.entries`: which sessions are omitted (no
/// attention entry at all, vs. an entry present with a nil `activity`,
/// vs. a stale attention id with no live session), the blocked-before-
/// your-turn ranking, and that ranking's within-rank order preservation —
/// see `SessionAttentionTests` for the same pure-function testing style
/// applied to the reducer this type consumes.
final class AgentDashboardTests: XCTestCase {

    private func session(_ name: String) -> SessionRow {
        SessionRow(id: UUID().uuidString, target: .root(projectPath: "/tmp/project"), name: name)
    }

    private func attentionState(_ activity: SessionActivity?) -> AttentionState {
        AttentionState(activity: activity)
    }

    // MARK: - 1

    func test01_sessionsWithNoAttentionEntryAreOmitted() {
        let sessions = [session("A"), session("B"), session("C")]

        let result = AgentDashboard.entries(sessions: sessions, attention: [:])

        XCTAssertTrue(result.isEmpty, "a session AppStore has never recorded any attention signal for must not appear in the dashboard, or every freshly opened session would show up as needing attention before it has said anything at all")
    }

    // MARK: - 2

    func test02_attentionStatePresentButActivityNilIsOmitted() {
        let quiet = session("Quiet")
        // A hook that latched (isStructured: true) and then cleared: the
        // dictionary lookup succeeds, unlike case 1, but the activity is
        // nil — this must be a separately-tested code path, since a bug
        // that only guarded against a missing dictionary entry would still
        // pass test01 while showing this row.
        let attention = [quiet.id: AttentionState(activity: nil, isStructured: true)]

        let result = AgentDashboard.entries(sessions: [quiet], attention: attention)

        XCTAssertTrue(result.isEmpty, "a session whose attention state exists but whose activity has been cleared (e.g. a hook that latched then sent .clear) must not linger in the dashboard just because a dictionary entry for it exists")
    }

    // MARK: - 3

    func test03_blockedSessionListedAfterYourTurnSessionSortsFirst() {
        let yourTurnSession = session("Waiting")
        let blockedSession = session("Stuck")
        let sessions = [yourTurnSession, blockedSession]
        let attention = [
            yourTurnSession.id: attentionState(.yourTurn),
            blockedSession.id: attentionState(.blocked)
        ]

        let result = AgentDashboard.entries(sessions: sessions, attention: attention)

        XCTAssertEqual(result.map(\.session.id), [blockedSession.id, yourTurnSession.id], "a blocked session must be shown before a your-turn session even when the sidebar lists it later — blocked is the more urgent state and must never be buried beneath a merely-waiting session")
        XCTAssertEqual(result.first?.activity, .blocked, "the entry for the blocked session must carry .blocked, matching the state it came from")
        XCTAssertEqual(result.last?.activity, .yourTurn, "the entry for the your-turn session must carry .yourTurn, matching the state it came from")
    }

    // MARK: - 4

    func test04_sameRankSessionsPreserveSidebarOrder() {
        let a = session("A")
        let b = session("B")
        let c = session("C")
        let d = session("D")
        let e = session("E")
        let sessions = [a, b, c, d, e]
        let attention = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, attentionState(.yourTurn)) })

        let result = AgentDashboard.entries(sessions: sessions, attention: attention)

        XCTAssertEqual(result.map(\.session.id), sessions.map(\.id), "five same-rank sessions must come out in exactly the sidebar order they went in — a non-stable sort has a realistic chance of reshuffling a group this size, which would make the dashboard's row order flicker between refreshes for no reason visible to the user")
    }

    // MARK: - 5

    func test05_mixedRanksAndOmissionsSortBlockedFirstThenYourTurnInSidebarOrder() {
        let x = session("X")
        let y = session("Y")
        let z = session("Z")
        let w = session("W")
        let v = session("V")
        let sessions = [x, y, z, w, v]
        let attention = [
            x.id: attentionState(.yourTurn),
            y.id: attentionState(.blocked),
            // z has no attention entry at all.
            w.id: attentionState(.yourTurn),
            v.id: attentionState(.blocked)
        ]

        let result = AgentDashboard.entries(sessions: sessions, attention: attention)

        XCTAssertEqual(result.map(\.session.id), [y.id, v.id, x.id, w.id], "a realistic mix of ranks and an omitted quiet session must still resolve to every blocked session (in sidebar order), then every your-turn session (in sidebar order), with the quiet session absent entirely")
    }

    // MARK: - 6

    func test06_staleAttentionEntryWithNoMatchingSessionProducesNoEntryAndDoesNotCrash() {
        let quiet = session("Quiet")
        let attention = ["stale-session-id-not-in-sessions": attentionState(.blocked)]

        let result = AgentDashboard.entries(sessions: [quiet], attention: attention)

        XCTAssertTrue(result.isEmpty, "an attention entry left behind under an id no longer present in `sessions` (e.g. a closed session whose attention state hasn't been pruned yet) must not manufacture a phantom dashboard row for a session that no longer exists")
    }

    // MARK: - 7

    func test07_emptyInputsProduceEmptyResultAndEntryIdMatchesSessionId() {
        let empty = AgentDashboard.entries(sessions: [], attention: [:])
        XCTAssertTrue(empty.isEmpty, "no open sessions at all must mean no dashboard entries — there is nothing to show attention for")

        let only = session("Only")
        let result = AgentDashboard.entries(sessions: [only], attention: [only.id: attentionState(.blocked)])

        XCTAssertEqual(result.count, 1, "a single blocked session must produce exactly one entry")
        XCTAssertEqual(result.first?.id, only.id, "an entry's `id` must equal its session's id — SwiftUI's `ForEach(rows)` relies on this for row identity, and a mismatch here would let the queue misidentify or misanimate cards across updates")
    }

    // MARK: - 8

    func test08_entryCarriesTheStatesSinceTimestamp() {
        let raisedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let dated = session("Dated")
        let undated = session("Undated")
        let attention = [
            dated.id: AttentionState(activity: .blocked, since: raisedAt),
            undated.id: AttentionState(activity: .yourTurn)
        ]

        let result = AgentDashboard.entries(sessions: [dated, undated], attention: attention)

        XCTAssertEqual(result.first?.since, raisedAt, "the entry must carry the state's `since` through unchanged — it is the only thing the card's age is computed from")
        XCTAssertEqual(result.last?.since, nil, "a state with no timestamp must still produce an entry (the row is listed, just undated) rather than being dropped")
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - 9

    /// The exact boundaries matter: a card reads "now" for its first minute,
    /// then flips unit at 60 minutes and 24 hours, always rounding down.
    func test09_elapsedFormatsWholeUnitsFlooredWithSpokenForms() {
        let since = Date(timeIntervalSinceReferenceDate: 0)
        func at(_ seconds: TimeInterval) -> AgentDashboard.Elapsed {
            AgentDashboard.elapsed(since: since, now: since.addingTimeInterval(seconds))
        }

        XCTAssertEqual(at(0), .init(short: "now", spoken: "just now"))
        XCTAssertEqual(at(59), .init(short: "now", spoken: "just now"), "anything under a minute is 'now' — a seconds counter would only add churn")
        XCTAssertEqual(at(60), .init(short: "1m", spoken: "1 minute"), "the singular form must be used at exactly one unit")
        XCTAssertEqual(at(8 * 60 + 59), .init(short: "8m", spoken: "8 minutes"), "minutes must floor, not round — 8:59 is still 8m")
        XCTAssertEqual(at(59 * 60 + 59), .init(short: "59m", spoken: "59 minutes"))
        XCTAssertEqual(at(60 * 60), .init(short: "1h", spoken: "1 hour"))
        XCTAssertEqual(at(23 * 3600 + 59 * 60), .init(short: "23h", spoken: "23 hours"))
        XCTAssertEqual(at(24 * 3600), .init(short: "1d", spoken: "1 day"))
        XCTAssertEqual(at(2 * 24 * 3600 + 5 * 3600), .init(short: "2d", spoken: "2 days"), "days must floor too — two days and five hours is 2d")
        XCTAssertEqual(at(-30), .init(short: "now", spoken: "just now"), "a `since` in the future (clock skew between a stamp and a later reading) must read as 'now', never as a negative age")
    }
}
