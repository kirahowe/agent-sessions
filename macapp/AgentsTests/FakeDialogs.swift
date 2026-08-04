import Foundation
@testable import Agents

/// Test double for `DialogPresenting`. Scriptable per-call result (defaults
/// to "user cancelled" for the optional-returning methods, "confirmed" for
/// the boolean ones) and records every call so tests can assert both what
/// was called and what `AppActions` did with the result — without any real
/// NSAlert/NSOpenPanel modal loop.
@MainActor
final class FakeDialogs: DialogPresenting {
    var nextProjectDirectory: String? = nil
    var nextConfirmRemove: Bool = true
    var nextConfirmDeleteWorkspace: Bool = true
    var nextLandMessage: String? = nil

    private(set) var chooseProjectDirectoryCallCount: Int = 0
    private(set) var confirmRemoveCalls: [Project] = []
    private(set) var confirmDeleteWorkspaceCalls: [WorkspaceRow] = []
    private(set) var promptLandMessageCalls: [WorkspaceRow] = []

    func chooseProjectDirectory() -> String? {
        chooseProjectDirectoryCallCount += 1
        return nextProjectDirectory
    }

    func confirmRemove(_ project: Project) -> Bool {
        confirmRemoveCalls.append(project)
        return nextConfirmRemove
    }

    func confirmDeleteWorkspace(_ ws: WorkspaceRow) -> Bool {
        confirmDeleteWorkspaceCalls.append(ws)
        return nextConfirmDeleteWorkspace
    }

    func promptLandMessage(workspace: WorkspaceRow) -> String? {
        promptLandMessageCalls.append(workspace)
        return nextLandMessage
    }
}
