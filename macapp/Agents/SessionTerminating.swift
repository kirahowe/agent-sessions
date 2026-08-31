import Foundation

/// What a pane's OSC title is authoritative for — see
/// `SessionTerminating.onTitleChange`.
struct SessionTitleRoles: OptionSet {
    let rawValue: Int
    /// The row's sidebar/window name (the focused pane's title).
    static let display = SessionTitleRoles(rawValue: 1 << 0)
    /// The resume metadata's human label (the resume-designate pane's title).
    static let resume = SessionTitleRoles(rawValue: 1 << 1)
}

/// Abstracts terminal-lifecycle teardown away from `AppStore` so it can be
/// tested without spinning up real `TerminalView`/`GhosttyTerminal` state.
/// `TerminalCenter` is the production conformer; tests inject a spy.
@MainActor
protocol SessionTerminating: AnyObject {
    var onProcessExit: ((String) -> Void)? { get set }
    /// Fired whenever any of a session's pane terminals reports anything
    /// that could bear on attention state — a structured `agents:status`
    /// payload, a free-text desktop notification, a bell, and so on (see
    /// `AttentionSignal`), as (sessionID, paneID, signal). The proxy no
    /// longer parses or decides anything itself: it only translates a
    /// delegate callback into a signal and forwards it. All interpretation
    /// — classification, the structured latch, attended-suppression —
    /// lives in `SessionAttention.reduce`, applied PER PANE: each pane is
    /// its own agent with its own state stream, and `AppStore` folds the
    /// pane states into the one session-row indicator. Collapsing panes
    /// into one reduction here would let one pane's clear erase another
    /// pane's still-open blocked state. Mirrors `onProcessExit`'s
    /// callback-based seam so `AppStore` can be tested against a spy
    /// without any real terminal machinery.
    var onSessionSignal: ((String, UUID, AttentionSignal) -> Void)? { get set }
    /// Fired with (sessionID, paneID) whenever one pane's surface is torn
    /// down — pane close, pane process exit, session close, quiesce. This
    /// is what lets `AppStore` drop the closed pane's attention
    /// contribution: without it, a pane that closed while blocked would
    /// keep the session row red forever.
    var onPaneClosed: ((String, UUID) -> Void)? { get set }
    /// Fired when one of a session's panes reports a new OSC window-title
    /// string, as (sessionID, title, roles). The roles say what the title
    /// is authoritative FOR — the two consumers follow different panes:
    ///
    /// - `.display`: the focused pane's title drives the row's sidebar and
    ///   window name.
    /// - `.resume`: the resume-designate pane's title (the initial pane
    ///   while it lives — the pane whose agent owns `SessionRow.resume`)
    ///   labels the resume metadata.
    ///
    /// A single-pane session's one pane holds both roles, so both arrive on
    /// every emit — pre-split behavior exactly. A title carrying NEITHER
    /// role (an unfocused, non-designate pane) is never emitted. Splitting
    /// the roles is what keeps a focused sibling's title from rewriting the
    /// designate agent's resume label into a lie ("Last session: <B's
    /// task> … --resume <A's id>"). A blank/whitespace-only title is
    /// IGNORED downstream (see AppStore.setSessionTitle): "remember the
    /// last title" means a shell clearing its title keeps the last real one.
    var onTitleChange: ((String, String, SessionTitleRoles) -> Void)? { get set }
    /// Fired for a valid version-1 session-resume notification — either
    /// Warp's CLI-agent title (which OMP speaks natively) or the app's own
    /// hook title (`agents:session`, for Claude Code and Codex) — as
    /// (sessionID, event, authoring pane's current OSC title). The terminal
    /// bridge consumes every notification carrying either magic title, but
    /// forwards only successfully decoded envelopes here, and only from the
    /// session's resume-designate pane. The attached title is the seed for
    /// the resume record's human label: it comes from the SAME pane whose
    /// agent produced the event, never from `agentTitle`, which the focused
    /// pane — possibly a sibling agent — owns. Nil when that pane hasn't
    /// titled itself yet (notably the first event after a relaunch, where
    /// the label heals on the pane's next `.resume`-role title).
    var onAgentSessionEvent: ((String, AgentSessionEvent, String?) -> Void)? { get set }
    func closeSession(_ id: String)
    /// Stops every target terminal and returns only after its Ghostty surface
    /// has been explicitly freed. Session rows remain owned by AppStore.
    func quiesceSessions(_ ids: Set<String>) async
    /// Makes refused or failed close operations eligible for lazy recreation.
    func resumeSessions(_ ids: Set<String>)
}
