import AppKit


struct NewWorkspacePromptResult: Equatable {
    let projectPath: String
    let label: String
}

/// Abstracts the remaining synchronous AppKit dialogs away from
/// `AppActions` so routing can be tested without a running modal loop.
/// Workspace closing is intentionally absent: RootView presents that
/// asynchronous, AppStore-owned experience as one SwiftUI sheet.
@MainActor
protocol DialogPresenting {
    func chooseProjectDirectory() -> String?
    func confirmRemove(_ project: Project) -> Bool
    func promptRename(currentName: String) -> String?
    func promptNewWorkspace(projects: [Project], defaultProject: Project?) -> NewWorkspacePromptResult?
}

/// Production conformer: forwards straight through to `Dialogs`.
@MainActor
struct LiveDialogPresenter: DialogPresenting {
    // Explicitly nonisolated, same reasoning as WorkspaceEngineCLI's init:
    // conforming to the @MainActor protocol infers whole-type MainActor
    // isolation, which would otherwise make this initializer MainActor-
    // isolated too — and AppActions.init's default argument
    // (`dialogs: ... = LiveDialogPresenter()`) is evaluated in a
    // synchronous, nonisolated context, so it couldn't call an isolated
    // init. The init itself touches no actor-isolated state, so opting it
    // out here is safe.
    nonisolated init() {}

    func chooseProjectDirectory() -> String? { Dialogs.chooseProjectDirectory() }
    func confirmRemove(_ project: Project) -> Bool { Dialogs.confirmRemove(project) }
    func promptRename(currentName: String) -> String? { Dialogs.promptRename(currentName: currentName) }
    func promptNewWorkspace(projects: [Project], defaultProject: Project?) -> NewWorkspacePromptResult? {
        Dialogs.promptNewWorkspace(projects: projects, defaultProject: defaultProject)
    }
}
