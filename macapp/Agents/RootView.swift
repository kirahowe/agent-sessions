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
            return "\(session.displayName) — \(project.name)"
        }
        return "Agents"
    }

    /// The agent-set terminal title of the selected session — but only when
    /// it isn't already what the window title shows (see `SessionRow.subtitle`),
    /// so the title never repeats verbatim on the line beneath itself. "" when
    /// there's no selection, no agent title yet, or it would duplicate the
    /// name; an empty string renders no subtitle at all.
    private var windowSubtitle: String {
        guard let selectedID = store.selection,
              let session = store.sessions.first(where: { $0.id == selectedID })
        else { return "" }
        return session.subtitle ?? ""
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
        .navigationSubtitle(windowSubtitle)
        .task {
            // Runs once at launch: a non-blocking, informational check for
            // bb/jj. Terminals work fine without either — only workspace
            // operations need them — so a miss here only queues an alert,
            // never anything that gates app usage.
            let missing = ToolPreflight.missingTools()
            if !missing.isEmpty {
                uiState.missingToolsNotice = ToolPreflight.guidance(for: missing)
            }
        }
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
        .alert(
            "Some features need extra tools",
            isPresented: Binding(
                get: { uiState.missingToolsNotice != nil },
                set: { isPresented in
                    if !isPresented { uiState.missingToolsNotice = nil }
                }
            )
        ) {
            Button("OK") {
                uiState.missingToolsNotice = nil
            }
        } message: {
            Text(uiState.missingToolsNotice ?? "")
        }
    }
}
