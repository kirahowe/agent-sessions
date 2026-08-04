import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: AppStore
    @Environment(\.appActions) private var actions

    var body: some View {
        List(selection: $store.selection) {
            ForEach(store.projects) { project in
                Section {
                    ForEach(store.sessions.filter { $0.target == .root(projectPath: project.path) }) { session in
                        sessionRow(session)
                    }

                    ForEach(store.workspaces.filter { $0.projectPath == project.path }) { workspace in
                        workspaceRow(workspace)

                        ForEach(sessions(in: workspace)) { session in
                            sessionRow(session, indent: 16)
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
                        // global selection (see comment on the row context menu below).
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
                        // Direct store call, not actions.perform: this creates a
                        // workspace in the specific right-clicked project, not
                        // whatever project AppActions' .newWorkspace would resolve
                        // from selection (see design rationale in AppActions.swift).
                        Button("New Workspace") {
                            Task { await store.createWorkspace(in: project.path) }
                        }
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

    private func sessions(in workspace: WorkspaceRow) -> [SessionRow] {
        let target = TargetRef.workspace(projectPath: workspace.projectPath, name: workspace.name)
        return store.sessions.filter { $0.target == target }
    }

    @ViewBuilder
    private func sessionRow(_ session: SessionRow, indent: CGFloat = 0) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text(session.name)
        }
        .padding(.vertical, 5)
        .padding(.leading, indent)
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

    @ViewBuilder
    private func workspaceRow(_ workspace: WorkspaceRow) -> some View {
        Button {
            store.selectOrCreateSession(in: .workspace(projectPath: workspace.projectPath, name: workspace.name))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
                Text(workspace.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        // .plain + a Button (rather than a bare HStack + .onTapGesture) is
        // deliberate: this file already proves Buttons reliably receive
        // clicks inside a selection-bound List (see the header's "+"
        // button above), so reusing that proven pattern here avoids any
        // risk of List's own row-click-to-select machinery swallowing an
        // onTapGesture before it fires. Deliberately no .tag anywhere on
        // this row: workspace rows aren't part of the List's own selection
        // mechanism (they don't represent a session) — tapping instead
        // resolves to that workspace's first session, or creates one.
        .buttonStyle(.plain)
        .contextMenu {
            // Direct store call, not actions.perform: this targets the
            // specific right-clicked workspace, row-targeted the same way
            // the session row's context menu above is.
            Button("New Session") {
                store.newSession(in: .workspace(projectPath: workspace.projectPath, name: workspace.name))
            }
            Button("Rename…") {
                if let name = Dialogs.promptRename(currentName: workspace.displayName, title: "Rename Workspace") {
                    store.setWorkspaceLabel(workspace.id, label: name)
                }
            }
            Button("Delete Workspace…") {
                if Dialogs.confirmDeleteWorkspace(workspace) {
                    Task { await store.deleteWorkspace(workspace.id) }
                }
            }
        }
    }
}
