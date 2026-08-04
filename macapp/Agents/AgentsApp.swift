import AppKit
import SwiftUI

/// Tiny UI-only state that doesn't belong in AppStore's persisted model —
/// currently whether the ⌘? shortcut-help sheet is showing, and whether
/// there's a launch-time missing-tools notice to display. Owned by
/// AgentsApp alongside AppActions: AppActions.perform(.showShortcutHelp)
/// toggles showShortcutHelp, RootView observes both to drive its `.sheet`
/// and `.alert`.
@MainActor
final class UIState: ObservableObject {
    @Published var showShortcutHelp = false

    /// Guidance text from `ToolPreflight` when a launch-time check finds bb
    /// and/or jj missing — nil means there's nothing to show, either because
    /// both tools were found or because the notice has already been
    /// dismissed. Purely informational: workspace operations will still
    /// fail their own way if attempted, this just gives the user an earlier,
    /// readable heads-up instead of a low-level subprocess error.
    @Published var missingToolsNotice: String?
}

@main
struct AgentsApp: App {
    let center: TerminalCenter
    let actions: AppActions
    let router: ShortcutRouter
    let uiState: UIState
    @StateObject private var store: AppStore

    init() {
        let center = TerminalCenter()
        self.center = center
        let store = AppStore(terminals: center, stateURL: AppStore.defaultStateURL)
        _store = StateObject(wrappedValue: store)

        let uiState = UIState()
        self.uiState = uiState

        let actions = AppActions(store: store, uiState: uiState)
        self.actions = actions
        let router = ShortcutRouter { actions.perform($0) }
        self.router = router
        // Local monitors don't need NSApp to have finished launching, so
        // installing here (rather than deferring to RootView's .task) is
        // safe and keeps shortcut wiring colocated with the rest of app
        // construction. (If a real launch shows this is flaky, move the
        // install() call into RootView's .task instead and note why here.)
        router.install()
    }

    /// Whether `store.selection` currently points at a session whose target
    /// is a workspace (rather than a project root) — drives "Keep Workspace
    /// Changes…"'s enabled state, resolved the same way
    /// `AppActions.perform(.keepWorkspaceChanges)` resolves its target.
    private var selectionTargetsWorkspace: Bool {
        guard let selection = store.selection,
              let row = store.sessions.first(where: { $0.id == selection })
        else { return false }
        if case .workspace = row.target { return true }
        return false
    }

    var body: some Scene {
        // `Window` (single-window), not `WindowGroup`: TerminalCenter caches
        // exactly one NSView/TerminalController pair per session id, with no
        // notion of "which window" it belongs to. WindowGroup can still spawn
        // a second window (Dock re-open, window-tabbing affordances) even
        // with File > New Window's menu item replaced above, and a second
        // window hosting the same session would either steal its NSView out
        // from under the first window (a view can only have one superview)
        // or show a blank surface. Don't revert this to WindowGroup without
        // first making TerminalCenter's cache window-aware.
        Window("Agents", id: "main") {
            RootView(store: store, center: center, uiState: uiState)
                .environment(\.appActions, actions)
        }
        .commands {
            // Replaces (rather than extends) the system File > New Window
            // group: New Window (⌘N) makes no sense for this app, and ⌘N is
            // repurposed below for New Workspace.
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    actions.perform(.newSession)
                }
                .keymapShortcut(.newSession)

                Button("New Workspace") {
                    actions.perform(.newWorkspace)
                }
                .keymapShortcut(.newWorkspace)

                Button("Add Project…") {
                    actions.perform(.addProject)
                }
                .keymapShortcut(.addProject)

                Button("Remove Project…") {
                    actions.perform(.removeProject)
                }
                // No .keymapShortcut: removeProject has no Keymap entry (menu-only).

                Button("Delete Workspace…") {
                    actions.perform(.deleteWorkspace)
                }
                // No .keymapShortcut: deleteWorkspace has no Keymap entry (menu-only).

                Button("Keep Workspace Changes…") {
                    actions.perform(.keepWorkspaceChanges)
                }
                .disabled(!selectionTargetsWorkspace)
                // No .keymapShortcut: keepWorkspaceChanges has no Keymap entry (menu-only).
            }

            CommandGroup(replacing: .saveItem) {
                Button("Close Session") {
                    actions.perform(.closeSession)
                }
                .keymapShortcut(.closeSession)
                .disabled(store.selection == nil)

                Button("Close Window") {
                    actions.perform(.closeWindow)
                }
                .keymapShortcut(.closeWindow)
            }

            CommandMenu("Session") {
                Button("Previous Session") {
                    actions.perform(.previousSession)
                }
                .keymapShortcut(.previousSession)

                Button("Next Session") {
                    actions.perform(.nextSession)
                }
                .keymapShortcut(.nextSession)
            }

            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    actions.perform(.showShortcutHelp)
                }
                .keymapShortcut(.showShortcutHelp)
            }
        }
    }
}

private extension View {
    /// Applies the `KeyboardShortcut` SwiftUI should render/fire for a menu
    /// item, sourced from `Keymap.standard` — the same table `Keymap.action`
    /// matches keydowns against. No-op if the action has no entry (e.g.
    /// `.removeProject`, which is menu-only).
    @ViewBuilder
    func keymapShortcut(_ action: AppAction) -> some View {
        if let shortcut = Keymap.standard[action] {
            let (key, modifiers) = shortcut.swiftUIShortcut
            self.keyboardShortcut(key, modifiers: modifiers)
        } else {
            self
        }
    }
}
