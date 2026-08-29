import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: AppStore
    @Environment(\.appActions) private var actions

    var body: some View {
        List(selection: $store.selection) {
            ForEach(store.projects) { project in
                Section {
                    ForEach(store.sessions.filter { $0.target == .root(projectPath: project.path) }) { session in
                        SessionRowView(store: store, session: session, activity: store.attention[session.id]?.activity)
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
                            SessionRowView(store: store, session: session, activity: store.attention[session.id]?.activity, indent: 16)
                        }
                        .onMove { offsets, destination in
                            store.moveSessions(
                                in: .workspace(projectPath: workspace.projectPath, name: workspace.name),
                                fromOffsets: offsets,
                                toOffset: destination
                            )
                        }
                    }
                } header: {
                    HStack {
                        Text(project.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        if store.projectWorkingCopyAttention.contains(project.path) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .imageScale(.small)
                                .foregroundStyle(.orange)
                                .help("Project workspace hasn't followed the latest project progress yet. Refresh it from the project menu.")
                                .accessibilityLabel("Project workspace hasn't followed the latest project progress")
                        }
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
        // `spacing: 0` plus an opaque bar behind the whole inset: without a
        // background the List scrolls *through* the button, and a long session
        // list ends up rendering rows on top of the label. The Divider is the
        // usual macOS bottom-bar hairline marking where scrollable content ends.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    actions?.perform(.addProject)
                } label: {
                    Label("Add Project…", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                // Explicit, because a Button inside a `.sidebar` List otherwise
                // inherits a borderless style and renders as bare accent text.
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(12)
            }
            .background(.bar)
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
        if store.projectWorkingCopyAttention.contains(project.path) {
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

/// Renders one session's activity glyph in its sidebar row. Pulled out into
/// its own view — rather than inlined in `SessionRowView` as a plain `Image`
/// the way it used to be — specifically so it can own its `pulsing` `@State`
/// itself. If that state lived on `SessionRowView` instead, it would be
/// shared across every activity this row ever shows: a `.blocked` pulse that
/// was mid-cycle when the state cleared (agent got unblocked) and then came
/// back later (blocked again) could resume from whatever phase the old
/// animation left `pulsing` in, or — worse — a `repeatForever` animation
/// started for an earlier `.blocked` value could keep silently running
/// against a view that no longer shows it. Giving this its own small view
/// means SwiftUI tears down and recreates its `@State` fresh every time the
/// row starts showing an indicator again, so the animation always restarts
/// cleanly from the beginning and never lingers past the activity it was
/// animating.
struct SessionActivityIndicator: View {
    let activity: SessionActivity

    /// Reduce Motion must suppress the pulse entirely, not just slow it
    /// down or tone it back — a repeating opacity animation firing every
    /// ~1.1s indefinitely is exactly the kind of motion that accessibility
    /// setting exists to eliminate for users who find it distracting or
    /// disorienting. When it's on, `.blocked` still gets its larger
    /// exclamation-mark glyph (that's a static shape change, not motion),
    /// just rendered at a constant full opacity.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Image(systemName: activity.symbolName)
            .font(.system(size: activity.pointSize))
            .foregroundStyle(activity.tint)
            .opacity(currentOpacity)
            .accessibilityLabel(activity.accessibilityLabel)
            .onAppear {
                // Only `.blocked` pulses — `.yourTurn` stays a small static
                // dot at full opacity always, so there's nothing to animate
                // or to gate on Reduce Motion for that case.
                guard activity == .blocked, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }

    /// `.yourTurn` and a Reduce-Motion `.blocked` both render at a constant
    /// full opacity; a motion-enabled `.blocked` alternates between full
    /// opacity and 0.45 as `pulsing` toggles, driven by the `withAnimation`
    /// call in `onAppear` above.
    private var currentOpacity: Double {
        guard activity == .blocked, !reduceMotion else { return 1.0 }
        return pulsing ? 1.0 : 0.45
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

/// Colour + symbol + size + accessibility mapping for the sidebar's activity
/// indicator — the single place all of that visual mapping lives, so
/// `SessionActivityIndicator` above never hardcodes a per-case choice itself
/// and the two states can never drift apart from what's documented here.
/// Lives here (not in SessionActivity.swift) because SessionActivity.swift is
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

    /// `.blocked` deliberately gets a DIFFERENT SHAPE, not just a different
    /// colour: a small filled circle differing only in hue from `.yourTurn`
    /// failed two ways at once — it read as no real escalation between "your
    /// move whenever" and "actively burning time waiting on you," and it was
    /// invisible as a distinction to anyone with colour-vision deficiency.
    /// The exclamation mark is a shape change everyone can read regardless of
    /// colour perception, on top of (not instead of) the colour and the pulse
    /// `SessionActivityIndicator` layers on for `.blocked`.
    var symbolName: String {
        switch self {
        case .yourTurn: return "circle.fill"
        case .blocked: return "exclamationmark.circle.fill"
        }
    }

    /// `.blocked` also renders larger (11pt vs. 7pt) for the same reason its
    /// symbol changed: size is a second, colour-independent channel carrying
    /// the same "this one is more urgent" signal.
    var pointSize: CGFloat {
        switch self {
        case .yourTurn: return 7
        case .blocked: return 11
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .yourTurn: return "Waiting for you"
        case .blocked: return "Blocked on you"
        }
    }
}
