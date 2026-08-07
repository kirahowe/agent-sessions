import Foundation

/// Abstracts terminal-lifecycle teardown away from `AppStore` so it can be
/// tested without spinning up real `TerminalView`/`GhosttyTerminal` state.
/// `TerminalCenter` is the production conformer; tests inject a spy.
@MainActor
protocol SessionTerminating: AnyObject {
    var onProcessExit: ((String) -> Void)? { get set }
    /// Fired when a session's terminal reports an activity-status change
    /// (parsed from a Claude Code hook's OSC notification — see
    /// `SessionActivity.parseStatusMessage`). A nil activity means "clear
    /// this session's indicator." Mirrors `onProcessExit`'s per-session,
    /// callback-based seam so `AppStore` can be tested against a spy without
    /// any real terminal machinery.
    var onSessionActivity: ((String, SessionActivity?) -> Void)? { get set }
    /// Fired when a session's terminal reports a new OSC window-title string
    /// (sessionID, title). Mirrors `onSessionActivity`'s per-session,
    /// callback-based seam so `AppStore` can be tested against a spy without
    /// any real terminal machinery. A blank/whitespace-only title means "no
    /// meaningful title" — the shell cleared it or never set one.
    var onTitleChange: ((String, String) -> Void)? { get set }
    func closeSession(_ id: String)
}
