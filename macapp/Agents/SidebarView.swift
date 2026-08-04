import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: AppStore
    @Environment(\.appActions) private var actions

    var body: some View {
        List(selection: $store.selection) {
            ForEach(store.projects) { project in
                Section {
                    ForEach(store.sessions.filter { $0.target == .root(projectPath: project.path) }) { session in
                        SessionRowView(store: store, session: session)
                    }

                    ForEach(store.workspaces.filter { $0.projectPath == project.path }) { workspace in
                        WorkspaceRowView(store: store, workspace: workspace)

                        ForEach(sessions(in: workspace)) { session in
                            SessionRowView(store: store, session: session, indent: 16)
                        }
                    }
                } header: {
                    HStack {
                        Text(project.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Menu {
                            projectHeaderMenuItems(project)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .imageScale(.small)
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("More Actions")
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
                        projectHeaderMenuItems(project)
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

    /// Shared with the project header's context menu AND its ellipsis `Menu`
    /// button, so the two presentations can never drift apart.
    @ViewBuilder
    private func projectHeaderMenuItems(_ project: Project) -> some View {
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

/// A session row in the sidebar. Owns its own hover state so its trailing
/// accessories (ellipsis menu, close button) can hover-reveal without
/// disturbing the rest of the row's layout — `.opacity` rather than
/// conditional insertion keeps row height stable as the accessories
/// appear/disappear. No enclosing `Button` here (unlike `WorkspaceRowView`
/// below): this row was already tag-based (`List`'s own selection), so the
/// new Menu/Button accessories are just sibling controls within it and don't
/// risk swallowing the row's tap-to-select the way a wrapping Button would.
private struct SessionRowView: View {
    let store: AppStore
    let session: SessionRow
    var indent: CGFloat = 0

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text(session.name)
            Spacer()
            HStack(spacing: 4) {
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More Actions")

                // Direct store call, not actions.perform: this closes the
                // specific row's session, not the app's global selection
                // (see comment on the context menu below). No confirm here:
                // matches ⌘W's behavior (AppActions' .closeSession case).
                Button {
                    store.closeSession(session.id)
                } label: {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close Session")
            }
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.vertical, 5)
        .padding(.leading, indent)
        .tag(session.id)
        .onHover { isHovered = $0 }
        .contextMenu {
            menuItems
        }
    }

    /// Shared with the ellipsis `Menu` button above, so the two
    /// presentations can never drift apart.
    @ViewBuilder
    private var menuItems: some View {
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

/// A workspace row in the sidebar. Owns its own hover state the same way
/// `SessionRowView` does. Unlike that row, this one's entire tap target IS a
/// `Button` (selects-or-creates a session on tap) — so the trailing
/// accessories live in their own `HStack`, as a SIBLING of that `Button`
/// rather than nested inside its label. Nesting them inside the label would
/// mean two overlapping tap handlers fighting over the same click; keeping
/// them outside means the `Button`'s frame simply doesn't extend under the
/// accessories, so each control only ever receives clicks meant for it.
private struct WorkspaceRowView: View {
    let store: AppStore
    let workspace: WorkspaceRow

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
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

            HStack(spacing: 4) {
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More Actions")

                // Direct store/Dialogs call, not actions.perform: same
                // confirm flow as "Delete Workspace…" in the context menu
                // below, just row-targeted via a visible button instead of
                // a right-click.
                Button {
                    if Dialogs.confirmDeleteWorkspace(workspace) {
                        Task { await store.deleteWorkspace(workspace.id) }
                    }
                } label: {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete Workspace")
            }
            .opacity(isHovered ? 1 : 0)
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            menuItems
        }
    }

    /// Shared with the ellipsis `Menu` button above, so the two
    /// presentations can never drift apart.
    @ViewBuilder
    private var menuItems: some View {
        // Direct store/Dialogs call, not actions.perform: this targets
        // the specific right-clicked workspace, row-targeted the same
        // way the rest of this context menu is.
        Button("Keep Changes…") {
            if let message = Dialogs.promptLandMessage(workspace: workspace) {
                Task { await store.landWorkspace(workspace.id, message: message) }
            }
        }
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
