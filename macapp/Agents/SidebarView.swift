import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: AppStore
    @Environment(\.appActions) private var actions

    var body: some View {
        List(selection: $store.selection) {
            ForEach(store.projects) { project in
                Section {
                    ForEach(store.sessions.filter { $0.projectPath == project.path }) { session in
                        HStack(spacing: 8) {
                            Image(systemName: "terminal")
                                .foregroundStyle(.secondary)
                            Text(session.name)
                        }
                        .padding(.vertical, 5)
                        .tag(session.id)
                        .contextMenu {
                            // Direct store/Dialogs call, not actions.perform: this
                            // targets the specific right-clicked row, not the app's
                            // global selection, so it isn't the same operation as
                            // AppActions' selection-based cases.
                            Button("Rename…") {
                                if let name = Dialogs.promptRename(currentName: session.name) {
                                    store.renameSession(session.id, to: name)
                                }
                            }
                            // Direct store call, not actions.perform: this closes the
                            // specific right-clicked row, not the app's global
                            // selection (see comment above).
                            Button("Close Session") {
                                store.closeSession(session.id)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(project.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        // Direct store call, not actions.perform: this targets the
                        // specific project this header belongs to, not the app's
                        // global selection (see comment on the row context menu above).
                        Button {
                            store.newSession(in: project)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 6)
                    .padding(.trailing, 4)
                    .contextMenu {
                        // Direct store/Dialogs call, not actions.perform: this
                        // targets the specific right-clicked project, not the
                        // resolved-from-selection target AppActions' .removeProject
                        // case would use (see design rationale in AppActions.swift).
                        Button("Remove Project…") {
                            if Dialogs.confirmRemove(project) {
                                store.removeProject(project)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 28)
        .safeAreaInset(edge: .bottom) {
            Button {
                actions?.perform(.addProject)
            } label: {
                Text("Add Project…")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(12)
        }
    }
}
