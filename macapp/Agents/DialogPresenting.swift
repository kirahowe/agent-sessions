import AppKit

/// Abstracts AppKit dialog presentation away from `AppActions` so its
/// routing logic can be tested without a running NSAlert/NSOpenPanel modal
/// loop — mirrors the `SessionTerminating`/`WorkspaceEngineProviding` seams
/// already used by `AppStore`. `LiveDialogPresenter` (below) is the
/// production conformer, forwarding to the real `Dialogs` enum; tests
/// inject a fake. Deliberately covers only the 4 operations `AppActions`
/// actually calls — `Dialogs.promptRename` is called directly from
/// SidebarView and has no seam here.
@MainActor
protocol DialogPresenting {
    func chooseProjectDirectory() -> String?
    func confirmRemove(_ project: Project) -> Bool
    func confirmDeleteWorkspace(_ ws: WorkspaceRow) -> Bool
    func promptLandMessage(workspace: WorkspaceRow) -> String?
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
    func confirmDeleteWorkspace(_ ws: WorkspaceRow) -> Bool { Dialogs.confirmDeleteWorkspace(ws) }
    func promptLandMessage(workspace: WorkspaceRow) -> String? { Dialogs.promptLandMessage(workspace: workspace) }
}
