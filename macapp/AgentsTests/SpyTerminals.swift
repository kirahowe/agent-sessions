import Foundation
@testable import Agents

/// Test double for `SessionTerminating`. Records every id passed to
/// `closeSession` so tests can assert teardown happened (and how many
/// times) without any real terminal/process machinery.
@MainActor
final class SpyTerminals: SessionTerminating {
    var onProcessExit: ((String) -> Void)?
    /// Tests fire this directly (`spy.onSessionActivity?(id, .blocked)`) to
    /// simulate a terminal reporting a status change, the same way
    /// `onProcessExit` simulates process exit.
    var onSessionActivity: ((String, SessionActivity?) -> Void)?
    /// Tests fire this directly (`spy.onTitleChange?(id, "building...")`) to
    /// simulate a terminal reporting an OSC title change, the same way
    /// `onSessionActivity` simulates a status change.
    var onTitleChange: ((String, String) -> Void)?
    private(set) var closedIDs: [String] = []

    func closeSession(_ id: String) {
        closedIDs.append(id)
    }
}
