import AppKit
import SwiftUI

@main
struct AgentsApp: App {
    let center: TerminalCenter
    let actions: AppActions
    let router: ShortcutRouter
    @StateObject private var store: AppStore

    init() {
        let center = TerminalCenter()
        self.center = center
        let store = AppStore(terminals: center, stateURL: AppStore.defaultStateURL)
        _store = StateObject(wrappedValue: store)

        let actions = AppActions(store: store)
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

    var body: some Scene {
        WindowGroup {
            RootView(store: store, center: center)
                .environment(\.appActions, actions)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session") {
                    actions.perform(.newSession)
                }
                .keymapShortcut(.newSession)

                Button("Add Project…") {
                    actions.perform(.addProject)
                }
                .keymapShortcut(.addProject)

                Button("Remove Project…") {
                    actions.perform(.removeProject)
                }
                // No .keymapShortcut: removeProject has no Keymap entry (menu-only).
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
