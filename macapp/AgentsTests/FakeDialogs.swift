import Foundation
@testable import Agents

/// Test double for the remaining synchronous dialogs used by AppActions.
@MainActor
final class FakeDialogs: DialogPresenting {
    var nextProjectDirectory: String? = nil
    var nextConfirmRemove: Bool = true
    var nextRenameName: String? = nil
    var nextNewWorkspaceResult: NewWorkspacePromptResult? = nil

    private(set) var chooseProjectDirectoryCallCount: Int = 0
    private(set) var confirmRemoveCalls: [Project] = []
    private(set) var promptRenameCalls: [String] = []
    private(set) var promptNewWorkspaceCalls: [(projects: [Project], defaultProject: Project?)] = []

    func chooseProjectDirectory() -> String? {
        chooseProjectDirectoryCallCount += 1
        return nextProjectDirectory
    }

    func confirmRemove(_ project: Project) -> Bool {
        confirmRemoveCalls.append(project)
        return nextConfirmRemove
    }


    func promptRename(currentName: String) -> String? {
        promptRenameCalls.append(currentName)
        return nextRenameName
    }

    func promptNewWorkspace(
        projects: [Project],
        defaultProject: Project?
    ) -> NewWorkspacePromptResult? {
        promptNewWorkspaceCalls.append((projects: projects, defaultProject: defaultProject))
        return nextNewWorkspaceResult
    }
}
