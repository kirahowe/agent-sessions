import AppKit
import SwiftUI

/// The one dispatch point for every user action in the app — used by
/// `ShortcutRouter`, the menu bar, and (where the action is identical, not
/// row/selection-specific) by view-layer buttons.
@MainActor
final class AppActions {
    let store: AppStore
    let uiState: UIState
    private let dialogs: any DialogPresenting

    init(store: AppStore, uiState: UIState, dialogs: any DialogPresenting = LiveDialogPresenter()) {
        self.store = store
        self.uiState = uiState
        self.dialogs = dialogs
    }

    @discardableResult
    func perform(_ action: AppAction) -> Bool {
        switch action {
        case .newSession:
            guard !store.projects.isEmpty else { return false }
            store.newSession(in: nil)
            return true

        case .closeSession:
            guard let selection = store.selection else { return false }
            store.closeSession(selection)
            return true

        case .closeWindow:
            guard let window = NSApp.keyWindow else { return false }
            window.performClose(nil)
            return true

        case .addProject:
            // Cancel still counts as handled — the shortcut did its job by
            // opening the panel.
            if let path = dialogs.chooseProjectDirectory() {
                store.addProject(path: path)
            }
            return true

        case .removeProject:
            let project = resolveProject()
            guard let project else { return false }
            // Once a project is resolved we opened the confirm dialog, so
            // the shortcut/menu-item did its job regardless of the user's
            // choice (same "cancel still counts as handled" reasoning as addProject).
            if dialogs.confirmRemove(project) {
                store.removeProject(project)
            }
            return true

        case .previousSession:
            guard !store.sessions.isEmpty else { return false }
            store.selectPrevious()
            return true

        case .nextSession:
            guard !store.sessions.isEmpty else { return false }
            store.selectNext()
            return true

        case .selectSession(let index):
            return store.selectSession(at: index)

        case .newWorkspace:
            guard let project = resolveProject() else { return false }
            Task { await store.createWorkspace(in: project.path) }
            return true

        case .deleteWorkspace:
            guard let selection = store.selection,
                  let row = store.sessions.first(where: { $0.id == selection }),
                  case .workspace(let projectPath, let name) = row.target,
                  let workspace = store.workspaces.first(where: { $0.projectPath == projectPath && $0.name == name })
            else { return false }
            // Once a workspace is resolved we opened the confirm dialog, so
            // the shortcut/menu-item did its job regardless of the user's
            // choice (same "cancel still counts as handled" reasoning as addProject/removeProject).
            if dialogs.confirmDeleteWorkspace(workspace) {
                Task { await store.deleteWorkspace(workspace.id) }
            }
            return true

        case .keepWorkspaceChanges:
            guard let selection = store.selection,
                  let row = store.sessions.first(where: { $0.id == selection }),
                  case .workspace(let projectPath, let name) = row.target,
                  let workspace = store.workspaces.first(where: { $0.projectPath == projectPath && $0.name == name })
            else { return false }
            // Cancel still counts as handled, same reasoning as
            // .deleteWorkspace above: once a workspace is resolved we opened
            // the prompt, so the menu item did its job regardless of choice.
            if let message = dialogs.promptLandMessage(workspace: workspace) {
                Task { await store.landWorkspace(workspace.id, message: message) }
            }
            return true

        case .showShortcutHelp:
            uiState.showShortcutHelp.toggle()
            return true
        }
    }

    /// Resolves which project an unqualified, selection-driven action
    /// targets: the selected session's project, or (with no selection) the
    /// single project if exactly one exists. Anything more ambiguous
    /// resolves to nil. Shared by `.removeProject` and `.newWorkspace` —
    /// both need "the project implied by current context," not a
    /// row-targeted project (row-targeted creation/removal goes straight
    /// through the store from SidebarView instead).
    private func resolveProject() -> Project? {
        if let selection = store.selection,
           let row = store.sessions.first(where: { $0.id == selection })
        {
            return store.projects.first(where: { $0.path == row.projectPath })
        }
        if store.projects.count == 1 {
            return store.projects.first
        }
        return nil
    }
}

// MARK: - Environment injection

/// Lets SidebarView (and any other view) reach the single AppActions
/// instance without RootView needing to thread it through its own init —
/// RootView.swift is intentionally left untouched by this change.
private struct AppActionsKey: EnvironmentKey {
    static let defaultValue: AppActions? = nil
}

extension EnvironmentValues {
    var appActions: AppActions? {
        get { self[AppActionsKey.self] }
        set { self[AppActionsKey.self] = newValue }
    }
}
