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
    var nextRenameName: String? = nil
    /// Defaults to "" (NOT nil) — meaning "user confirmed without typing a
    /// custom name" — because that's the outcome existing `.newSession`
    /// tests already assume when they don't touch this fake. A nil default
    /// would silently turn every one of those into a cancel and break them.
    var nextNewSessionName: String? = ""

    private(set) var chooseProjectDirectoryCallCount: Int = 0
    private(set) var confirmRemoveCalls: [Project] = []
    private(set) var confirmDeleteWorkspaceCalls: [WorkspaceRow] = []
    private(set) var promptLandMessageCalls: [WorkspaceRow] = []
    private(set) var promptRenameCalls: [String] = []
    private(set) var promptNewSessionNameCallCount: Int = 0

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

    func promptRename(currentName: String) -> String? {
        promptRenameCalls.append(currentName)
        return nextRenameName
    }

    func promptNewSessionName() -> String? {
        promptNewSessionNameCallCount += 1
        return nextNewSessionName
    }
}
