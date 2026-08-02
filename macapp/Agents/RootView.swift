import SwiftUI

struct RootView: View {
    @ObservedObject var store: AppStore

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
                TerminalHostView(store: store)

                if store.selection == nil {
                    VStack(spacing: 8) {
                        Text("Add a project to get started")
                        Text("⌘T for a new session")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
            }
        }
        .navigationTitle(windowTitle)
    }
}
