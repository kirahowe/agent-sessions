import Foundation

/// Abstracts the split-pane commands away from `AppActions` so they can be
/// tested without spinning up real `TerminalView`/`GhosttyTerminal` state —
/// the same seam pattern as `SessionTerminating`, but a separate protocol:
/// `AppStore` owns session lifecycle and never touches panes, while
/// `AppActions` dispatches pane commands and never tears down sessions.
/// `TerminalCenter` is the production conformer; tests inject a spy.
@MainActor
protocol PaneCommanding: AnyObject {
    /// Splits the session's focused pane, spawning a fresh shell in
    /// `workingDirectory`. Returns the new pane's id, or nil for a session
    /// with no live layout (never shown, or quiesced).
    @discardableResult
    func splitPane(in sessionID: String, axis: SplitAxis, workingDirectory: String) -> UUID?
    /// Closes the focused pane of a multi-pane session. False for a
    /// single-pane session — closing the last pane is `closeSession`'s job.
    @discardableResult
    func closeFocusedPane(in sessionID: String) -> Bool
    /// Moves the session's focus one pane toward `direction`. False at an
    /// edge, so the caller can report the shortcut as unhandled.
    @discardableResult
    func moveFocus(in sessionID: String, direction: FocusDirection) -> Bool
}

extension TerminalCenter: PaneCommanding {}
