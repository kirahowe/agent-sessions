import Foundation

/// Turns a free-text OSC 9/777 desktop-notification title+body pair into a
/// best-guess `SessionActivity`, for agents that never speak the structured
/// `agents:status` protocol (see `SessionActivity.parseStatusMessage`).
///
/// This is inherently fuzzy, English-only and wording-dependent — the OSC
/// number itself is flattened by libghostty (`ghostty_action_desktop_notification_s`
/// carries only `title`/`body`, so OSC 9, 777 and 99 are indistinguishable
/// to us), which leaves the notification text as the only semantic signal
/// available at all. The blast radius of getting the wording wrong is
/// deliberately small and one-directional:
///
/// - It can only ever choose between two states, never invent a third.
/// - Its fallback is the *safer* state: an unmatched wording degrades
///   `.blocked` (red, "come deal with this now") down to `.yourTurn` (gold,
///   "no rush"), never the reverse. A cue we haven't seen yet costs the user
///   a less urgent indicator, not a missed permission prompt.
/// - It is ignored entirely for any session that has ever sent a structured
///   payload — see `AttentionState.isStructured`. This classifier only ever
///   runs for sessions with no better source of truth.
enum AttentionClassifier {
    /// Checked first, so a string that happens to contain both a blocked
    /// cue and a your-turn cue (plausible — e.g. a permission prompt whose
    /// body also says "waiting") classifies as the more urgent state.
    static let blockedCues = [
        "permission", "approve", "approval", "authorize", "allow", "permission_prompt",
    ]

    /// The phrasings we have actually seen agents use to hand the turn back.
    /// Matching one of these reaches the same `.yourTurn` the fallback below
    /// reaches, so nothing today classifies differently for their presence —
    /// but the two are not the same statement, and collapsing them would
    /// lose that: a cue match is a *recognised* phrasing, the fallback is a
    /// *guess* at an unrecognised one. Keeping them as separate branches is
    /// what makes this read as a cue table rather than a single special-cased
    /// list, and it's where a third state, or any fallback other than
    /// `.yourTurn`, would slot in as a local edit.
    static let yourTurnCues = [
        "waiting", "awaiting", "idle", "needs your input", "finished", "complete", "done",
    ]

    static func classify(title: String, body: String) -> SessionActivity {
        // Whitespace is normalised, not merely trimmed: notification bodies
        // arrive wrapped or newline-broken often enough that a multi-word cue
        // like "needs your input" would otherwise miss on text a human reads
        // as containing it verbatim. Splitting on whitespace and rejoining
        // collapses runs, newlines and the title/body seam alike, so cues
        // that straddle any of those still match.
        let haystack = (title + " " + body)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        if blockedCues.contains(where: { haystack.contains($0) }) {
            return .blocked
        }
        if yourTurnCues.contains(where: { haystack.contains($0) }) {
            return .yourTurn
        }
        // A notification always means *something* wants the user's
        // attention, even when its wording doesn't match a known cue — see
        // the type doc comment for why `.yourTurn` is the safe direction to
        // default toward.
        return .yourTurn
    }
}
