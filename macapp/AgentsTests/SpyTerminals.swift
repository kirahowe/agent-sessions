import Foundation
@testable import Agents

/// Test double for `SessionTerminating`. Records every id passed to
/// `closeSession` so tests can assert teardown happened (and how many
/// times) without any real terminal/process machinery.
@MainActor
final class SpyTerminals: SessionTerminating {
    var onProcessExit: ((String) -> Void)?
    /// Tests simulate a terminal reporting an attention signal through
    /// `emitSignal` below, the same way `onProcessExit` simulates process
    /// exit.
    var onSessionSignal: ((String, UUID, AttentionSignal) -> Void)?
    var onPaneClosed: ((String, UUID) -> Void)?
    /// Tests simulate a terminal reporting an OSC title change through
    /// `emitTitle` below, the same way `emitSignal` simulates an attention
    /// signal.
    var onTitleChange: ((String, String, SessionTitleRoles) -> Void)?
    var onAgentSessionEvent: ((String, AgentSessionEvent, String?) -> Void)?
    private(set) var closedIDs: [String] = []
    private(set) var quiesceCalls: [Set<String>] = []
    private(set) var resumeCalls: [Set<String>] = []
    var onCloseSession: ((String) -> Void)?
    var quiesceSessionsHandler: ((Set<String>) async -> Void)?

    /// A stable synthetic pane id per session, so a test firing several
    /// signals at one session exercises ONE pane's reduction stream —
    /// matching a real single-pane session — rather than accidentally
    /// spreading the signals across phantom panes and bypassing the
    /// structured latch. Tests that specifically need multiple panes pass
    /// an explicit `pane:`.
    private var syntheticPaneIDs: [String: UUID] = [:]

    func paneID(for sessionID: String) -> UUID {
        if let existing = syntheticPaneIDs[sessionID] { return existing }
        let paneID = UUID()
        syntheticPaneIDs[sessionID] = paneID
        return paneID
    }

    /// Simulates a terminal attention signal, defaulting to the session's
    /// stable synthetic pane.
    func emitSignal(_ sessionID: String, pane: UUID? = nil, _ signal: AttentionSignal) {
        onSessionSignal?(sessionID, pane ?? paneID(for: sessionID), signal)
    }

    /// Simulates one pane's surface being freed.
    func emitPaneClosed(_ sessionID: String, pane: UUID? = nil) {
        onPaneClosed?(sessionID, pane ?? paneID(for: sessionID))
    }

    /// The last `.resume`-role title emitted per session — what
    /// `TerminalCenter` would hold as the authoring pane's `lastTitle` and
    /// attach to that pane's agent events. `emitAgentEvent` mirrors that
    /// production guarantee so tests exercise the real seeding contract.
    private var lastResumeTitles: [String: String] = [:]

    /// Simulates an OSC title change. Defaults to both roles — a
    /// single-pane session's one pane is focused AND resume designate, so
    /// every pre-split test means both. Role-splitting tests pass their own.
    func emitTitle(
        _ sessionID: String, _ title: String, roles: SessionTitleRoles = [.display, .resume]
    ) {
        if roles.contains(.resume) {
            lastResumeTitles[sessionID] = title
        }
        onTitleChange?(sessionID, title, roles)
    }

    /// Simulates a decoded agent session event, attaching the authoring
    /// pane's title exactly as `TerminalCenter.handleAgentSessionEvent`
    /// does (its `lastTitle` — here, the last `.resume`-role title).
    func emitAgentEvent(_ sessionID: String, _ event: AgentSessionEvent) {
        onAgentSessionEvent?(sessionID, event, lastResumeTitles[sessionID])
    }

    func closeSession(_ id: String) {
        onCloseSession?(id)
        closedIDs.append(id)
    }

    func quiesceSessions(_ ids: Set<String>) async {
        quiesceCalls.append(ids)
        await quiesceSessionsHandler?(ids)
    }

    func resumeSessions(_ ids: Set<String>) {
        resumeCalls.append(ids)
    }
}
