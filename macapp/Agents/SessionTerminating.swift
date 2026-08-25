import Foundation

/// Abstracts terminal-lifecycle teardown away from `AppStore` so it can be
/// tested without spinning up real `TerminalView`/`GhosttyTerminal` state.
/// `TerminalCenter` is the production conformer; tests inject a spy.
@MainActor
protocol SessionTerminating: AnyObject {
    var onProcessExit: ((String) -> Void)? { get set }
    /// Fired whenever a session's terminal reports anything that could bear
    /// on attention state — a structured `agents:status` payload, a
    /// free-text desktop notification, a bell, and so on (see
    /// `AttentionSignal`). The proxy no longer parses or decides anything
    /// itself: it only translates a delegate callback into a signal and
    /// forwards it. All interpretation — classification, the structured
    /// latch, attended-suppression — lives in `SessionAttention.reduce`.
    /// Mirrors `onProcessExit`'s per-session, callback-based seam so
    /// `AppStore` can be tested against a spy without any real terminal
    /// machinery.
    var onSessionSignal: ((String, AttentionSignal) -> Void)? { get set }
    /// Fired when a session's terminal reports a new OSC window-title string
    /// (sessionID, title). Mirrors `onSessionSignal`'s per-session,
    /// callback-based seam so `AppStore` can be tested against a spy without
    /// any real terminal machinery. A blank/whitespace-only title is IGNORED
    /// downstream (see AppStore.setSessionTitle): "remember the last title"
    /// means a shell clearing its title keeps the last real one.
    var onTitleChange: ((String, String) -> Void)? { get set }
    /// Fired for a valid version-1 OMP Warp CLI-agent notification. The
    /// terminal bridge consumes all notifications carrying Warp's magic
    /// title, but forwards only successfully decoded OMP envelopes here.
    var onOmpSessionEvent: ((String, OmpSessionEvent) -> Void)? { get set }
    func closeSession(_ id: String)
}
