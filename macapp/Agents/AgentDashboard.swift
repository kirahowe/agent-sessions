import Foundation

/// One row the Agent Dashboard shows: a session together with the
/// non-optional attention state that earned it a place in the list.
struct AgentDashboardEntry: Identifiable, Equatable {
    let session: SessionRow
    let activity: SessionActivity
    /// When `activity` was raised — `AttentionState.since`, carried through
    /// so the row can show its age. Optional only because the state's field
    /// is: the reducer sets it whenever it sets an activity, and a row whose
    /// timestamp were somehow missing should still be listed, just undated.
    let since: Date?
    var id: String { session.id }
}

/// The dashboard's filter-and-order rule and its age formatting, kept
/// Foundation-only (like `SessionAttention`) so both can be unit-tested
/// without a view hierarchy.
enum AgentDashboard {
    /// The sessions needing attention, most urgent first: every `.blocked`
    /// session, then every `.yourTurn` session. Within a rank the input
    /// (sidebar) order is preserved. Sessions with no attention state, or
    /// whose state has a nil `activity`, are omitted entirely. Attention
    /// entries whose id has no live session are ignored.
    static func entries(sessions: [SessionRow], attention: [String: AttentionState]) -> [AgentDashboardEntry] {
        // Built by walking `sessions` (sidebar order), never the `attention`
        // dictionary — dictionary iteration order is arbitrary and would
        // make the list's within-rank order nondeterministic.
        let candidates: [AgentDashboardEntry] = sessions.compactMap { session in
            guard let state = attention[session.id], let activity = state.activity else { return nil }
            return AgentDashboardEntry(session: session, activity: activity, since: state.since)
        }

        // `sorted` is not guaranteed stable, so ranking directly could
        // reshuffle same-rank entries relative to each other on any given
        // run. Sorting (offset, rank) pairs — the same technique the view
        // used before this type existed — keeps the original (sidebar)
        // order within each rank by using the offset as an explicit
        // tiebreak instead of relying on whatever order `sorted` happens to
        // preserve.
        return candidates.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element.activity)
            let right = rank(rhs.element.activity)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// Exhaustive by design (no `default`): adding a third `SessionActivity`
    /// case must fail to compile here until this ranking says where it goes,
    /// rather than silently falling through to some default order.
    private static func rank(_ activity: SessionActivity) -> Int {
        switch activity {
        case .blocked: return 0
        case .yourTurn: return 1
        }
    }

    /// How long a row has been waiting, in the two forms the dashboard
    /// needs: `short` for the trailing edge of a card ("now", "8m", "3h",
    /// "2d") and `spoken` for its accessibility label ("just now", "8
    /// minutes", "3 hours", "2 days").
    struct Elapsed: Equatable {
        let short: String
        let spoken: String
    }

    /// Whole units only, floored: the question a row answers is "roughly
    /// how long has this one been on me?", and a seconds counter would only
    /// add churn. A `since` in the future (clock skew) reads as "now" rather
    /// than as a negative age.
    static func elapsed(since: Date, now: Date) -> Elapsed {
        let minutes = Int(max(0, now.timeIntervalSince(since)) / 60)
        let hours = minutes / 60
        let days = hours / 24
        if minutes < 1 { return Elapsed(short: "now", spoken: "just now") }
        if hours < 1 { return Elapsed(short: "\(minutes)m", spoken: count(minutes, "minute")) }
        if days < 1 { return Elapsed(short: "\(hours)h", spoken: count(hours, "hour")) }
        return Elapsed(short: "\(days)d", spoken: count(days, "day"))
    }

    private static func count(_ n: Int, _ unit: String) -> String {
        "\(n) \(unit)\(n == 1 ? "" : "s")"
    }
}
