import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var overlays: OverlayCenter
    @Environment(\.appActions) private var actions

    /// The activity glyph for a session row. A review open in an unselected
    /// session shows as `.blocked` — the agent genuinely is blocked, waiting
    /// on feedback the user cannot see — and self-clears the moment the
    /// session is selected and the review is back on screen. Derived here
    /// from `OverlayCenter`'s live state rather than routed through
    /// `SessionAttention.reduce`: that reducer arbitrates *terminal* signals
    /// and its structured-protocol latch would suppress exactly this raise
    /// for hook-speaking agents, whereas the app knows an open hidden review
    /// first-hand and needs no arbitration to say so.
    private func activity(for sessionID: String) -> SessionActivity? {
        if overlays.reviewSessionIDs.contains(sessionID), store.selection != sessionID {
            return .blocked
        }
        return store.attention[sessionID]?.activity
    }

    /// Collapsed by default: the section exists to get parked projects out
    /// of the way, so it must not take back the space they just freed.
    @State private var isArchivedExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.selection) {
                ForEach(store.projects) { project in
                    // One Section per project keeps the spacing between
                    // projects, but the project is named by the Section's
                    // first ROW, not a header: swipe actions attach to rows
                    // only, so a header could never carry the Archive
                    // swipe. The same row is where project reordering and
                    // collapse will hang later.
                    Section {
                        ProjectRowView(
                            store: store,
                            project: project,
                            needsWorkingCopyAttention: store.projectWorkingCopyAttention.contains(project.path)
                        )

                        ForEach(store.sessions.filter { $0.target == .root(projectPath: project.path) }) { session in
                            SessionRowView(store: store, session: session, activity: activity(for: session.id))
                        }
                        .onMove { offsets, destination in
                            store.moveSessions(
                                in: .root(projectPath: project.path),
                                fromOffsets: offsets,
                                toOffset: destination
                            )
                        }

                        ForEach(store.workspaces.filter { $0.projectPath == project.path }) { workspace in
                            WorkspaceRowView(store: store, workspace: workspace)

                            ForEach(sessions(in: workspace)) { session in
                                SessionRowView(store: store, session: session, activity: activity(for: session.id), indent: 16)
                            }
                            .onMove { offsets, destination in
                                store.moveSessions(
                                    in: .workspace(projectPath: workspace.projectPath, name: workspace.name),
                                    fromOffsets: offsets,
                                    toOffset: destination
                                )
                            }
                        }
                    }
                }

                // Present only while something is parked: an empty "Archived
                // (0)" would be a permanent reminder of a feature not in use.
                if !store.archivedProjects.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $isArchivedExpanded) {
                            ForEach(store.archivedProjects) { archived in
                                ArchivedProjectRowView(store: store, archived: archived)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "archivebox")
                                    .foregroundStyle(.secondary)
                                Text("Archived")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Text("\(store.archivedProjects.count)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 5)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 28)

            // Bottom-left, borderless, and secondary-styled on purpose: a
            // full-width footer bar here read as too heavy for the panel,
            // and putting this in the window toolbar instead made it look
            // like it belonged to the terminal window, not the project list.
            // Living inside the sidebar panel keeps it scoped to what it acts on.
            HStack {
                Button {
                    actions?.perform(.addProject)
                } label: {
                    Label("Add Project", systemImage: "plus")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Add Project…")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func sessions(in workspace: WorkspaceRow) -> [SessionRow] {
        let target = TargetRef.workspace(projectPath: workspace.projectPath, name: workspace.name)
        return store.sessions.filter { $0.target == target }
    }
}

/// The row that names a project — what used to be the Section header, with
/// the same name, working-copy triangle, ellipsis menu and "+" button, now
/// as a row so it can be swiped. Built like `WorkspaceRowView`: a
/// plain-style Button is the tap target and the trailing controls are its
/// siblings, so no two handlers ever fight over one click. Tapping selects
/// the project's first root session, or creates one, exactly as tapping a
/// workspace row does for that workspace. The ellipsis and "+" stay always
/// visible rather than hover-revealed, as they were on the header: this line
/// is the project's toolbar, not a row among siblings.
private struct ProjectRowView: View {
    let store: AppStore
    let project: Project
    let needsWorkingCopyAttention: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button {
                store.selectOrCreateSession(in: .root(projectPath: project.path))
            } label: {
                HStack(spacing: 8) {
                    Text(project.name)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if needsWorkingCopyAttention {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .imageScale(.small)
                            .foregroundStyle(.orange)
                            .help("The project's workspace hasn't caught up with the latest project progress. If an update conflicted, resolve the marked conflicts there, then refresh it from the project menu.")
                            .accessibilityLabel("Project workspace hasn't followed the latest project progress")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
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
            // Direct store call, not actions.perform: this targets the
            // specific project this row belongs to, not the app's global
            // selection (see comment on the session row's context menu).
            Button {
                store.newSession(in: project)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
        }
        .padding(.trailing, 4)
        .contextMenu {
            menuItems
        }
        // Trailing edge, full swipe allowed, like archiving in Mail. No
        // confirmation: an archive is undone in one click from the Archived
        // section, and the parked rows keep their resume hints.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                store.archiveProject(project)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(Theme.accent)
        }
    }

    /// Shared with the row's ellipsis `Menu` button AND its context menu,
    /// so the two presentations can never drift apart.
    @ViewBuilder
    private var menuItems: some View {
        if needsWorkingCopyAttention {
            Button("Refresh Project Workspace") {
                Task {
                    await store.refreshProjectWorkspace(project.path)
                }
            }
            Divider()
        }
        // This project provides the initial selection, while the prompt still
        // offers every open project as a possible workspace location.
        Button("New Workspace") {
            if let result = Dialogs.promptNewWorkspace(
                projects: store.projects,
                defaultProject: project
            ) {
                Task {
                    await store.createWorkspace(
                        in: result.projectPath,
                        label: result.label
                    )
                }
            }
        }
        // Direct store/Dialogs calls, not actions.perform: these target the
        // specific right-clicked project, not the resolved-from-selection
        // target AppActions' .archiveProject/.removeProject cases would use
        // (see design rationale in AppActions.swift).
        Button("Archive Project") {
            store.archiveProject(project)
        }
        Button("Remove Project…") {
            if Dialogs.confirmRemove(project) {
                store.removeProject(project)
            }
        }
    }
}

/// A parked project in the Archived section. The whole row is the restore
/// Button (the `WorkspaceRowView` pattern again), with a leading Restore
/// swipe as the mirror of the project row's trailing Archive swipe. The
/// hover-revealed ellipsis and the context menu also carry Remove, which
/// keeps its confirmation — that one really does forget the rows. The path
/// sits under the name because two parked projects can easily share one.
private struct ArchivedProjectRowView: View {
    let store: AppStore
    let archived: ArchivedProject

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                store.restoreProject(archived.path)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(archived.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text((archived.path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Restore \u{201C}\(archived.name)\u{201D}")

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
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                store.restoreProject(archived.path)
            } label: {
                Label("Restore", systemImage: "tray.and.arrow.up")
            }
            .tint(Theme.accent)
        }
    }

    /// Shared with the ellipsis `Menu` button above, so the two
    /// presentations can never drift apart.
    @ViewBuilder
    private var menuItems: some View {
        Button("Restore Project") {
            store.restoreProject(archived.path)
        }
        Button("Remove Project…") {
            if Dialogs.confirmRemove(archived.project) {
                store.removeProject(archived.project)
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
            // Pinned to one line: displayName is now often the agent-set
            // terminal title, which can be a full sentence — without this a
            // long title would wrap and grow the row's height out of step
            // with its siblings. The tooltip surfaces the full text when the
            // tail is truncated.
            Text(session.displayName)
                .lineLimit(1)
                .help(session.displayName)
            if let activity {
                // Placed before the trailing Spacer()/ellipsis-menu area
                // (not after) so this dot never collides with the
                // ellipsis "More Actions" menu, which hover-reveals in
                // that trailing space — the two occupy disjoint regions
                // of the row.
                SessionActivityIndicator(activity: activity)
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
            // Prefill with what the user currently sees (agent title or an
            // existing custom name) — the natural starting point to edit.
            if let name = Dialogs.promptRename(currentName: session.displayName) {
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
        // Row-targeted so a context menu always closes the workspace that was
        // clicked, regardless of the currently selected session.
        Button("Close Workspace…") {
            Task { await store.prepareCloseWorkspace(workspace.id) }
        }
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
    }
}
