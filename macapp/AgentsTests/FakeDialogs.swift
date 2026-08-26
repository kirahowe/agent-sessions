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
    /// Defaults to `.cancel` — the enum's own version of "user cancelled",
    /// matching this file's existing default-to-cancelled convention for
    /// every other optional-returning method below.
    var nextLandDecision: LandDecision = .cancel
    var nextConfirmRebaseOntoTrunk: Bool = true
    var nextRenameName: String? = nil
    var nextNewWorkspaceResult: NewWorkspacePromptResult? = nil

    private(set) var chooseProjectDirectoryCallCount: Int = 0
    private(set) var confirmRemoveCalls: [Project] = []
    private(set) var confirmDeleteWorkspaceCalls: [WorkspaceRow] = []
    private(set) var confirmLandCalls: [(workspace: WorkspaceRow, preview: LandPreview)] = []
    private(set) var confirmRebaseOntoTrunkCalls: [(count: Int, bookmark: String)] = []
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

    func confirmDeleteWorkspace(_ ws: WorkspaceRow) -> Bool {
        confirmDeleteWorkspaceCalls.append(ws)
        return nextConfirmDeleteWorkspace
    }

    func confirmLand(workspace: WorkspaceRow, preview: LandPreview) -> LandDecision {
        confirmLandCalls.append((workspace: workspace, preview: preview))
        return nextLandDecision
    }

    func confirmRebaseOntoTrunk(count: Int, bookmark: String) -> Bool {
        confirmRebaseOntoTrunkCalls.append((count: count, bookmark: bookmark))
        return nextConfirmRebaseOntoTrunk
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
