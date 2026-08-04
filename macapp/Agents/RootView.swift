import SwiftUI

struct RootView: View {
    @ObservedObject var store: AppStore
    let center: TerminalCenter
    @ObservedObject var uiState: UIState

    private var windowTitle: String {
        if let selectedID = store.selection,
           let session = store.sessions.first(where: { $0.id == selectedID }),
           let project = store.projects.first(where: { $0.path == session.projectPath })
        {
            return "\(session.name) — \(project.name)"
        }
        return "Agents"
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
        } detail: {
            // The terminal host must always be present in the tree — even
            // with no session selected — because reparenting or recreating
            // a live TerminalView blanks its Metal surface. The empty state
            // is an overlay on top, never a conditional swap.
            ZStack {
                TerminalHostView(store: store, center: center)

                if store.selection == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "terminal")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("Add a project to get started")
                            .font(.title3)
                        Text("⌘T for a new session")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                }
            }
        }
        .navigationTitle(windowTitle)
        .sheet(isPresented: $uiState.showShortcutHelp) {
            ShortcutHelpView()
        }
        .alert(
            "Workspace Error",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { isPresented in
                    if !isPresented { store.lastError = nil }
                }
            )
        ) {
            Button("OK") {
                store.lastError = nil
            }
        } message: {
            Text(store.lastError ?? "")
        }
        .alert(
            "No main bookmark exists in this repo. Create \u{201C}main\u{201D} at this landed commit?",
            isPresented: Binding(
                get: { store.pendingTrunkBootstrap != nil },
                set: { isPresented in
                    if !isPresented { store.pendingTrunkBootstrap = nil }
                }
            )
        ) {
            Button("Create") {
                if let pending = store.pendingTrunkBootstrap {
                    Task { await store.landWorkspace(pending.workspaceID, message: pending.message, createTrunk: "main") }
                }
                store.pendingTrunkBootstrap = nil
            }
            Button("Cancel", role: .cancel) {
                store.pendingTrunkBootstrap = nil
            }
        }
    }
}
