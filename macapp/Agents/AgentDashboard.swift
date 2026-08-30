import Foundation

/// One row the Agent Dashboard shows: a session together with the
/// non-optional attention state that earned it a place in the list.
struct AgentDashboardEntry: Identifiable, Equatable {
    let session: SessionRow
    let activity: SessionActivity
    var id: String { session.id }
}

/// The dashboard's filter-and-order rule, kept Foundation-only (like
/// `SessionAttention`) so it can be unit-tested without a view hierarchy.
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
            guard let activity = attention[session.id]?.activity else { return nil }
            return AgentDashboardEntry(session: session, activity: activity)
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
}
