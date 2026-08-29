import Foundation
@testable import Agents

/// Test double for `SessionTerminating`. Records every id passed to
/// `closeSession` so tests can assert teardown happened (and how many
/// times) without any real terminal/process machinery.
@MainActor
final class SpyTerminals: SessionTerminating {
    var onProcessExit: ((String) -> Void)?
    /// Tests fire this directly (`spy.onSessionSignal?(id, .structured(.set(.blocked)))`)
    /// to simulate a terminal reporting an attention signal, the same way
    /// `onProcessExit` simulates process exit.
    var onSessionSignal: ((String, AttentionSignal) -> Void)?
    /// Tests fire this directly (`spy.onTitleChange?(id, "building...")`) to
    /// simulate a terminal reporting an OSC title change, the same way
    /// `onSessionSignal` simulates an attention signal.
    var onTitleChange: ((String, String) -> Void)?
    var onAgentSessionEvent: ((String, AgentSessionEvent) -> Void)?
    private(set) var closedIDs: [String] = []
    private(set) var quiesceCalls: [Set<String>] = []
    private(set) var resumeCalls: [Set<String>] = []
    var onCloseSession: ((String) -> Void)?
    var quiesceSessionsHandler: ((Set<String>) async -> Void)?

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
