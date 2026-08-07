import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: AppStore
    @Environment(\.appActions) private var actions

    var body: some View {
        List(selection: $store.selection) {
            ForEach(store.projects) { project in
                Section {
                    ForEach(store.sessions.filter { $0.target == .root(projectPath: project.path) }) { session in
                        SessionRowView(store: store, session: session, activity: store.sessionActivity[session.id])
                    }

                    ForEach(store.workspaces.filter { $0.projectPath == project.path }) { workspace in
                        WorkspaceRowView(store: store, workspace: workspace)

                        ForEach(sessions(in: workspace)) { session in
                            SessionRowView(store: store, session: session, activity: store.sessionActivity[session.id], indent: 16)
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
                        // Direct store call, not actions.perform: this targets
                        // the specific project this header belongs to, not the app's
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
        // Direct store/Dialogs call, not actions.perform: this creates a
        // workspace in the specific right-clicked project, not
        // whatever project AppActions' .newWorkspace would resolve
        // from selection (see design rationale in AppActions.swift).
        Button("New Workspace") {
            if let label = Dialogs.promptNewWorkspaceLabel() {
                Task { await store.createWorkspace(in: project.path, label: label) }
            }
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
/// ellipsis menu can hover-reveal without disturbing the rest of the row's
/// layout — `.opacity` rather than conditional insertion keeps row height
/// stable as the menu appears/disappears. No enclosing `Button` here (unlike
/// `WorkspaceRowView` below): this row was already tag-based (`List`'s own
/// selection), so the Menu accessory is just a sibling control within it and
/// doesn't risk swallowing the row's tap-to-select the way a wrapping Button
/// would.
private struct SessionRowView: View {
    let store: AppStore
    let session: SessionRow
    var activity: SessionActivity?
    var indent: CGFloat = 0

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text(session.name)
            if let activity {
                // Placed before the trailing Spacer()/ellipsis-menu area
                // (not after) so this dot never collides with the
                // ellipsis "More Actions" menu, which hover-reveals in
                // that trailing space — the two occupy disjoint regions
                // of the row.
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(activity.tint)
                    .accessibilityLabel(activity.accessibilityLabel)
            }
            Spacer()
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
/// `Button` (selects-or-creates a session on tap) — so the trailing ellipsis
/// menu is a SIBLING of that `Button` rather than nested inside its label.
/// Nesting it inside the label would mean two overlapping tap handlers
/// fighting over the same click; keeping it outside means the `Button`'s
/// frame simply doesn't extend under the menu, so each control only ever
/// receives clicks meant for it.
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
        // Passes workspace.label (not displayName): an unlabelled workspace
        // should open this dialog with an empty field, not pre-filled with
        // a generated name the user never chose.
        Button("Change Label…") {
            if let label = Dialogs.promptWorkspaceLabel(currentLabel: workspace.label) {
                store.setWorkspaceLabel(workspace.id, label: label)
            }
        }
        Button("Delete Workspace…") {
            if Dialogs.confirmDeleteWorkspace(workspace) {
                Task { await store.deleteWorkspace(workspace.id) }
            }
        }
    }
}

/// Colour + accessibility mapping for the sidebar's activity dot. Lives
/// here (not in SessionActivity.swift) because SessionActivity.swift is
/// deliberately Foundation-only/SwiftUI-free so it stays trivially
/// unit-testable.
private extension SessionActivity {
    // These exact RGB values are deliberate, not arbitrary: they match
    // the user's existing iTerm2 tab-colour script, so the two tools
    // signal the same states with the same colours.
    var tint: Color {
        switch self {
        case .yourTurn: return Color(red: 210 / 255, green: 158 / 255, blue: 90 / 255)
        case .blocked: return Color(red: 200 / 255, green: 50 / 255, blue: 50 / 255)
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .yourTurn: return "Waiting for you"
        case .blocked: return "Blocked on you"
        }
    }
}
