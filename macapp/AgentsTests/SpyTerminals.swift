import Foundation
@testable import Agents

/// Test double for `SessionTerminating`. Records every id passed to
/// `closeSession` so tests can assert teardown happened (and how many
/// times) without any real terminal/process machinery.
@MainActor
final class SpyTerminals: SessionTerminating {
    var onProcessExit: ((String) -> Void)?
    private(set) var closedIDs: [String] = []

    func closeSession(_ id: String) {
        closedIDs.append(id)
    }
}
