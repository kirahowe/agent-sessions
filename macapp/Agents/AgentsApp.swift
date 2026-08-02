import AppKit
import SwiftUI

@main
struct AgentsApp: App {
    let center: TerminalCenter
    @StateObject private var store: AppStore

    init() {
        let center = TerminalCenter()
        self.center = center
        _store = StateObject(
            wrappedValue: AppStore(terminals: center, stateURL: AppStore.defaultStateURL)
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store, center: center)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session") {
                    store.newSession(in: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Close Session") {
                    guard let selection = store.selection else { return }
                    store.closeSession(selection)
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(store.selection == nil)

                Button("Close Window") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }
    }
}
