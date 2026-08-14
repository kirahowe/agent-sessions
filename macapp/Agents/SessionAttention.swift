import Foundation

/// Everything that can inform a session's attention state, from any source:
/// the structured hook protocol, a free-text OSC desktop notification, a
/// bare bell, the agent's own progress reporting, and the user's own focus.
enum AttentionSignal: Equatable {
    /// A parsed `agents:status` payload — see `SessionActivity.parseStatusMessage`.
    /// The high-fidelity path: an agent that speaks this protocol is trusted
    /// over every other source for the rest of its session (see
    /// `AttentionState.isStructured`).
    case structured(SessionActivity.StatusMessage)
    /// Free-text OSC 9/777 desktop-notification title+body, from any agent
    /// that emits one without ever having spoken the structured protocol —
    /// the fallback path that lights up Gemini CLI, Claude Code with
    /// `preferredNotifChannel` set, and anything else that just uses the
    /// terminal's native notification escape.
    case notification(title: String, body: String)
    /// A bare BEL, carrying no text at all.
    case bell
    /// The agent is demonstrably busy again (e.g. an OSC 9;4 progress
    /// report), so any unstructured raise should be withdrawn.
    case working
    /// The user is now looking (or has stopped looking) at this session.
    /// Driven from `AppStore.selection` plus app-active state, not the
    /// terminal package's own focus delegate — that fires on window-level
    /// changes, which don't mean the user attended to a particular session
    /// (see the design doc's "Focus and granularity" section).
    case attentionChanged(isAttended: Bool)
}

/// Resolved per-session attention state. `activity` is what the sidebar
/// indicator renders; `nil` means "show nothing."
struct AttentionState: Equatable {
    var activity: SessionActivity?

    /// Sticky, one-way latch: once true, stays true for the rest of this
    /// session's life. Never a cache, never a timeout, and never mutual.
    /// This is the direct answer to two bugs cmux (a Ghostty-based terminal
    /// that solved nearly this problem) hit and documented:
    ///
    /// - **#2322**: a hook path and a raw-OSC path each suppressed the other
    ///   through a possibly-stale cache, producing both missed and
    ///   duplicated notifications. A one-way latch can't oscillate the way a
    ///   cache can — once true it can never flip back to false and let the
    ///   unstructured path back in.
    /// - **#9523**: attention state written from ~20 uncoordinated call
    ///   sites with no reconciliation layer, so the same race recurred per
    ///   integration. Routing every signal through this one reducer, gated
    ///   on this one field, is the reconciliation layer.
    ///
    /// A session that has ever proven it speaks the structured protocol is
    /// trusted to keep speaking it — every other source becomes noise for
    /// that session, permanently, not just until the next thing it says.
    var isStructured = false

    /// True when the user is currently looking at this session: selected
    /// AND the app is frontmost. Suppresses unstructured raises (the row is
    /// already on screen) and clears an unstructured indicator on the way
    /// in (see `SessionAttention.reduce`'s `.attentionChanged` case).
    var isAttended = false
}

/// The single funnel every attention signal, from every source, passes
/// through — nothing else may compute or write attention state (see
/// `AppStore.apply(_:to:)`, the only caller). Foundation-only, like
/// `SessionActivity.swift`, so the whole state machine is testable without
/// SwiftUI, AppKit, or a real terminal.
///
/// Nothing below depends on receiving a repeated identical signal. Ghostty
/// rate-limits desktop notifications to about once a second and suppresses
/// identical content within a short window, so a design that needed a
/// repeat to, say, re-raise or refresh something would silently lose those
/// events. Every case here either latches, raises once, or clears — none of
/// them need to fire twice to be correct.
enum SessionAttention {
    static func reduce(_ state: AttentionState, _ signal: AttentionSignal) -> AttentionState {
        var next = state
        switch signal {
        case .structured(let message):
            // Latches unconditionally, on both .set and .clear, which is
            // what makes every other case below safe to gate on
            // `state.isStructured` — see that property's doc comment.
            next.isStructured = true
            switch message {
            case .set(let activity): next.activity = activity
            case .clear: next.activity = nil
            }
        case .notification(let title, let body):
            guard !state.isStructured, !state.isAttended else { return state }
            next.activity = AttentionClassifier.classify(title: title, body: body)
        case .bell:
            guard !state.isStructured, !state.isAttended else { return state }
            // `?? .yourTurn`, never an unconditional overwrite: a bell may
            // only ever raise attention from nothing. Overwriting here would
            // let the least informative signal in this whole design — a
            // bare BEL with no text — downgrade an already-known `.blocked`
            // back to `.yourTurn`, telling the user a still-open permission
            // prompt has been resolved when it hasn't.
            next.activity = state.activity ?? .yourTurn
        case .working:
            // Only the unstructured path clears itself on a busy signal. A
            // structured `.blocked` must survive the agent's own progress
            // reports: an agent can be simultaneously "computing" and
            // "still waiting on a permission prompt from three turns ago,"
            // and only the hook — not a generic busy heuristic — gets to
            // resolve that.
            guard !state.isStructured else { return state }
            next.activity = nil
        case .attentionChanged(let isAttended):
            next.isAttended = isAttended
            // Raises are dropped while attended (above) because the user is
            // already looking at the row and there's no subsequent
            // selection change to clear a raise that landed while they were
            // looking. Attending clears an unstructured indicator for the
            // same reason "looked at it" is the only honest clear available
            // without a hook — but never a structured one: with a hook the
            // agent's actual state is known, and going dark while it's
            // genuinely still blocked would be a lie. It stays red until
            // the hook says otherwise.
            if isAttended, !state.isStructured { next.activity = nil }
        }
        return next
    }
}
