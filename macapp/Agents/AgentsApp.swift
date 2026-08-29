import AppKit
import Sparkle
import SwiftUI

/// Tiny UI-only state that doesn't belong in AppStore's persisted model —
/// currently whether the ⌘? shortcut-help sheet is showing, and whether
/// there's a launch-time prerequisite notice to display. Owned by
/// AgentsApp alongside AppActions: AppActions.perform(.showShortcutHelp)
/// toggles showShortcutHelp, RootView observes both to drive its `.sheet`
/// and `.alert`.
@MainActor
final class UIState: ObservableObject {
    @Published var showShortcutHelp = false

    /// Guidance from `ToolPreflight` when bb or the temporary manager checkout
    /// is missing. Nil means every global prerequisite was found or the notice
    /// was dismissed. Project-specific version-control tools are not checked
    /// here; workspace operations resolve those when needed.
    @Published var prerequisiteNotice: String?
}

@main
struct AgentsApp: App {
    let center: TerminalCenter
    let overlays: OverlayCenter
    let controlServer: ControlServer
    let actions: AppActions
    let router: ShortcutRouter
    let uiState: UIState
    let updaterEnabled: Bool
    let updaterController: SPUStandardUpdaterController
    @StateObject private var store: AppStore
    @AppStorage(AppearanceMode.defaultsKey) private var appearanceMode: AppearanceMode = .system

    init() {
        let center = TerminalCenter()
        self.center = center

        // The overlay owner and its control channel are constructed here, and
        // the socket starts listening immediately: a review can be requested
        // by any session the moment that session exists, and a session can
        // exist before the window is on screen (restored rows spawn eagerly).
        // Binding later — in RootView's .task, say — would leave a window
        // where the launcher finds no socket and reports the app as absent.
        let overlays = OverlayCenter()
        self.overlays = overlays
        let controlServer = ControlServer(overlays: overlays)
        self.controlServer = controlServer
        controlServer.start()
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

        // The dev build (com.kirahowe.agents.dev) never starts the updater
        // at all — this bundle-identifier check is the ONLY place that
        // happens, so a dev build can never phone home or attempt a
        // self-update against the release app's identity/state.
        let updaterEnabled = Bundle.main.bundleIdentifier == "com.kirahowe.agents"
        self.updaterEnabled = updaterEnabled
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: updaterEnabled,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Whether the current session belongs to a workspace, used to enable
    /// the selection-targeted close action.
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
            RootView(store: store, center: center, overlays: overlays, uiState: uiState)
                .environment(\.appActions, actions)
                // Forced explicitly rather than left to the asset catalog
                // alone: ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME (set
                // in project.yml) only takes effect when the user's system
                // accent colour preference is "Multicolor" — any other
                // choice overrides it app-wide. This app's tint is part of
                // its identity, not a preference we want the system to
                // override, so `.tint` reapplies `Theme.accent` regardless
                // of that setting.
                .tint(Theme.accent)
        }
        .commands {
            // Deliberately does NOT route through AppActions/Keymap the way
            // the other menu items in this file do: Sparkle owns its own
            // update-checking UI and flow end-to-end, and this touches
            // neither `store` nor `uiState`. It's menu-only, exactly like
            // "Remove Project…" above is menu-only — no .keymapShortcut call
            // either, for the same reason: this isn't a shortcut-table
            // action.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
                .disabled(!updaterEnabled)
            }

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

                Button("Close Workspace…") {
                    actions.perform(.closeWorkspace)
                }
                .disabled(!selectionTargetsWorkspace)
                // No .keymapShortcut: closeWorkspace is menu-only.
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
                Button("Rename Session…") {
                    actions.perform(.renameSession)
                }
                .keymapShortcut(.renameSession)
                .disabled(store.selection == nil)

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
        // The single place the appearance preference is actually applied.
        // `initial: true` covers launch; the same observer fires again when
        // the Settings window's picker rewrites the shared @AppStorage key,
        // since both read/write the same UserDefaults entry — so there's no
        // second application site for the two to drift apart from each
        // other. (Scene.onChange(of:initial:) exists on macOS 14+; this
        // app's deployment target is 15.)
        .onChange(of: appearanceMode, initial: true) { _, mode in
            mode.apply()
        }

        // A `Settings` scene is what makes macOS add "Settings…" (⌘,) to the
        // app menu automatically — no CommandGroup wiring needed, unlike
        // every menu item above.
        Settings {
            SettingsView()
                // Reapplied here because the `.tint` on the main Window's
                // content (above) doesn't reach a separate scene — the same
                // system-accent-override reasoning applies as there.
                .tint(Theme.accent)
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
