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

    /// Schedules dialog presentation one runloop turn after `perform`
    /// returns, instead of presenting inline. `ShortcutRouter` calls
    /// `perform` from inside an `NSEvent` local-monitor callback, and
    /// `NSAlert.runModal`/`NSOpenPanel.runModal` nested there would run a
    /// modal event loop while AppKit is still dispatching the triggering
    /// keydown — which was observed leaking that keystroke into the hosted
    /// terminal once the dialog closed.
    ///
    /// Deferring is NOT what fixes the duplicate dialog (the "press Escape
    /// twice" bug); `perform`'s per-keystroke dedup is. But the two are
    /// linked: because presentation is deferred, both dispatches of a
    /// keystroke finish before any modal loop starts, so the second one
    /// still sees the same `NSApp.currentEvent` the dedup keys on. Moving
    /// presentation back inline would silently break that guarantee.
    ///
    /// Tests inject a synchronous `present` so assertions can still run
    /// immediately after `perform` returns.
    private let present: (@escaping () -> Void) -> Void

    /// The keydown AppKit was dispatching when this action was last
    /// *handled*. Injected as a closure (rather than read from `NSApp`
    /// directly) so tests can drive the dedup in `perform` without a real
    /// event stream.
    private let currentEvent: () -> NSEvent?
    private var lastKeyDispatch: (action: AppAction, timestamp: TimeInterval)?

    init(
        store: AppStore,
        uiState: UIState,
        dialogs: any DialogPresenting = LiveDialogPresenter(),
        present: @escaping (@escaping () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) },
        currentEvent: @escaping () -> NSEvent? = { NSApp.currentEvent }
    ) {
        self.store = store
        self.uiState = uiState
        self.dialogs = dialogs
        self.present = present
        self.currentEvent = currentEvent
    }

    /// Runs `action` at most once per originating keystroke.
    ///
    /// A ⌘-shortcut in this app is dispatched by two entirely independent
    /// mechanisms: `ShortcutRouter`'s local `NSEvent` monitor, and the menu
    /// item's own key equivalent, which `.keymapShortcut(_:)` attaches in
    /// AgentsApp.swift. The router returning nil for a handled event was
    /// assumed to consume the keydown and stop the menu from also firing.
    /// Measured against the running app — breakpoints on both paths — it
    /// does not: one ⇧⌘R produces a call from the monitor *and* a call from
    /// `-[NSMenu _performKeyEquivalentForItemAtIndex:]`. For most actions the
    /// second dispatch is invisible or self-cancelling (a second toggle, a
    /// re-select of the row already selected), but the six dialog-presenting
    /// actions each queued a second dialog behind the first — which is why
    /// dismissing the rename alert appeared to need two Escapes.
    ///
    /// Both dispatches happen synchronously inside the same
    /// `-[NSApplication sendEvent:]`, so they share one `NSApp.currentEvent`.
    /// That makes the identity of the keydown a sound dedup key — and it
    /// holds only because dialog presentation is deferred a runloop turn
    /// (see `present`): no modal loop runs between the two dispatches to
    /// swap `NSApp.currentEvent` out from under the second one.
    ///
    /// Two deliberate exclusions. A menu item chosen with the mouse carries
    /// a non-keyDown current event, so it is never deduplicated — picking
    /// Rename Session… from the menu twice in a row must work. And only a
    /// dispatch that actually handled the action is recorded, so a `false`
    /// return (⌘W with nothing selected, say) never suppresses a later
    /// legitimate attempt riding the same event.
    @discardableResult
    func perform(_ action: AppAction) -> Bool {
        guard let event = currentEvent(), event.type == .keyDown else {
            return dispatch(action)
        }
        if let last = lastKeyDispatch, last.action == action, last.timestamp == event.timestamp {
            return true
        }
        let handled = dispatch(action)
        if handled {
            lastKeyDispatch = (action, event.timestamp)
        }
        return handled
    }

    private func dispatch(_ action: AppAction) -> Bool {
        switch action {
        case .newSession:
            guard !store.projects.isEmpty else { return false }
            store.newSession(in: nil)
            return true

        case .closeSession:
            guard let selection = store.selection else { return false }
            store.closeSession(selection)
            return true

        case .renameSession:
            guard let selection = store.selection,
                  let row = store.sessions.first(where: { $0.id == selection })
            else { return false }
            // Cancel still counts as handled: once the row is resolved we
            // scheduled the prompt, so the shortcut/menu item did its job
            // regardless of the user's choice.
            present {
                if let name = self.dialogs.promptRename(currentName: row.displayName) {
                    self.store.renameSession(selection, to: name)
                }
            }
            return true

        case .closeWindow:
            guard let window = NSApp.keyWindow else { return false }
            window.performClose(nil)
            return true

        case .addProject:
            // Cancel still counts as handled — the shortcut did its job by
            // scheduling the panel.
            present {
                if let path = self.dialogs.chooseProjectDirectory() {
                    self.store.addProject(path: path)
                }
            }
            return true

        case .removeProject:
            let project = resolveProject()
            guard let project else { return false }
            // Once a project is resolved we scheduled the confirm dialog, so
            // the shortcut/menu-item did its job regardless of the user's
            // choice (same "cancel still counts as handled" reasoning as addProject).
            present {
                if self.dialogs.confirmRemove(project) {
                    self.store.removeProject(project)
                }
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
            let projects = store.projects
            guard !projects.isEmpty else { return false }
            let defaultProject = selectedProject()
            // Cancel still counts as handled, same reasoning as .addProject
            // above: once the dialog is scheduled the shortcut/menu item did
            // its job regardless of the user's choice.
            present {
                if let result = self.dialogs.promptNewWorkspace(
                    projects: projects,
                    defaultProject: defaultProject
                ) {
                    Task {
                        await self.store.createWorkspace(
                            in: result.projectPath,
                            label: result.label
                        )
                    }
                }
            }
            return true

        case .closeWorkspace:
            guard let selection = store.selection,
                  let row = store.sessions.first(where: { $0.id == selection }),
                  case .workspace(let projectPath, let name) = row.target,
                  let workspace = store.workspaces.first(where: {
                      $0.projectPath == projectPath && $0.name == name
                  })
            else { return false }
            Task { await store.prepareCloseWorkspace(workspace.id) }
            return true

        case .showShortcutHelp:
            uiState.showShortcutHelp.toggle()
            return true
        }
    }

    /// Returns the project represented by the current session selection.
    private func selectedProject() -> Project? {
        guard let selection = store.selection,
              let row = store.sessions.first(where: { $0.id == selection })
        else { return nil }
        return store.projects.first(where: { $0.path == row.projectPath })
    }

    /// Resolves the target for an unqualified project-removal action: the
    /// selected session's project, or the only project when exactly one is
    /// open.
    private func resolveProject() -> Project? {
        if let selectedProject = selectedProject() {
            return selectedProject
        }
        if store.projects.count == 1 {
            return store.projects.first
        }
        return nil
    }
}

// MARK: - Environment injection

/// Lets SidebarView (and any other view) reach the single AppActions instance.
private struct AppActionsKey: EnvironmentKey {
    static let defaultValue: AppActions? = nil
}

extension EnvironmentValues {
    var appActions: AppActions? {
        get { self[AppActionsKey.self] }
        set { self[AppActionsKey.self] = newValue }
    }
}
