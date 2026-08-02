import AppKit
import SwiftUI

@main
struct AgentsApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session") {
                    store.newSession(in: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

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
