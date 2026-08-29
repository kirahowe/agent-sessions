import AppKit
import Combine
import SwiftUI

struct RootView: View {
    @ObservedObject var store: AppStore
    let center: TerminalCenter
    @ObservedObject var uiState: UIState
    @State private var isDashboardPresented = true

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
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: .infinity)
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
        .inspector(isPresented: $isDashboardPresented) {
            AgentDashboardView(store: store)
                .inspectorColumnWidth(min: 300, ideal: 320, max: 340)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isDashboardPresented.toggle()
                } label: {
                    Label("Agent Dashboard", systemImage: "sidebar.trailing")
                }
                .help(isDashboardPresented ? "Hide Agent Dashboard" : "Show Agent Dashboard")
                .accessibilityLabel(isDashboardPresented ? "Hide Agent Dashboard" : "Show Agent Dashboard")
            }
        }
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .task {
            // Seeds the app-active flag with whatever state already holds at
            // launch: NSApplication.didBecomeActive/didResignActive (below)
            // only fire on a SUBSEQUENT transition, so without this, a
            // session that's already selected when the app launches active
            // would sit un-attended until the user clicked away and back.
            // Same "covers launch" reasoning as the Dock badge's
            // `initial: true` and AgentsApp's appearanceMode `.onChange`.
            store.setAppActive(NSApp.isActive)

            // Runs once at launch: a non-blocking informational check for the
            // wrapper's global prerequisites. Project-specific version-control
            // tools are still resolved when a workspace operation runs.
            uiState.prerequisiteNotice = ToolPreflight.guidance(for: ToolPreflight.check())
        }
        // Feeds NSApplication's real active state into the store, in the
        // view layer for exactly the reason the Dock-badge `.onChange`
        // below already documents: AppStore stays AppKit-free and
        // unit-testable without a running NSApplication, so it can't
        // observe these notifications itself — it just owns the plain
        // `isAppActive` Bool and `setAppActive(_:)` setter, and this is the
        // one place that setter actually gets called from real activation
        // events. The `.task` above seeds the state these notifications
        // don't cover: neither fires for whatever the app's active state
        // already is at the moment this view attaches.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.setAppActive(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            store.setAppActive(false)
        }
        .sheet(isPresented: $uiState.showShortcutHelp) {
            ShortcutHelpView()
        }
        .sheet(
            isPresented: Binding(
                get: { store.closeWorkspace != nil },
                set: { isPresented in
                    if !isPresented { store.cancelCloseWorkspace() }
                }
            )
        ) {
            CloseWorkspaceView(store: store)
        }
        // A blocked session is exactly the case where the user has stepped
        // away from the app entirely (why else would an agent still be
        // stuck on a permission prompt?), so the signal that matters most
        // has to reach them somewhere they'll see it even unfocused — the
        // Dock. This is applied here in the view layer, not from inside
        // AppStore itself, specifically so AppStore can stay AppKit-free and
        // unit-testable without a running NSApplication: `blockedSessionCount`
        // and `dockBadgeLabel(blockedCount:)` are both plain, testable
        // AppStore API, and this modifier is the one place their result
        // actually touches `NSApp`. `initial: true` mirrors the same
        // "covers launch" reasoning as AgentsApp's appearanceMode
        // `.onChange` — without it the badge would only ever update starting
        // from the first change to `blockedSessionCount` *after* this
        // modifier attaches, rather than reflecting whatever count already
        // holds at that moment.
        .onChange(of: store.blockedSessionCount, initial: true) { _, count in
            NSApp.dockTile.badgeLabel = AppStore.dockBadgeLabel(blockedCount: count)
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
            "Workspace prerequisites missing",
            isPresented: Binding(
                get: { uiState.prerequisiteNotice != nil },
                set: { isPresented in
                    if !isPresented { uiState.prerequisiteNotice = nil }
                }
            )
        ) {
            Button("OK") {
                uiState.prerequisiteNotice = nil
            }
        } message: {
            Text(uiState.prerequisiteNotice ?? "")
        }
    }
}

private struct CloseWorkspaceView: View {
    @ObservedObject var store: AppStore

    private var presentation: CloseWorkspacePresentation? {
        store.closeWorkspace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let presentation {
                Text("Close Workspace")
                    .font(.title2.weight(.semibold))

                Text("\u{201C}\(presentation.workspaceName)\u{201D} in \(presentation.projectName)")
                    .foregroundStyle(.secondary)

                content(for: presentation)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(presentation?.isBusy == true)
    }

    @ViewBuilder
    private func content(for presentation: CloseWorkspacePresentation) -> some View {
        switch presentation.phase {
        case .preparing:
            progress("Preparing workspace changes…")

        case .ready(let changes):
            changeReview(changes)
            actionButtons(addEnabled: true)

        case .summaryRequired(let changes):
            changeReview(changes)
            VStack(alignment: .leading, spacing: 8) {
                Text("Add a summary for the undescribed changes:")
                    .font(.callout)
                TextField(
                    "Change summary",
                    text: Binding(
                        get: { store.closeWorkspace?.summary ?? "" },
                        set: { store.setCloseWorkspaceSummary($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }
            actionButtons(
                addEnabled: !presentation.summary
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )

        case .noChanges:
            Text("This workspace has no changes to add.")
            HStack {
                Spacer()
                Button("Cancel") {
                    store.cancelCloseWorkspace()
                }
                Button("Close Workspace") {
                    Task { await store.closeWithoutAddingWorkspace() }
                }
                .keyboardShortcut(.defaultAction)
            }

        case .confirmCloseWithoutAdding:
            Label("Close without adding these changes?", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("The workspace will be closed without adding these changes to the project.")
            HStack {
                Spacer()
                Button("Cancel") {
                    store.cancelCloseWithoutAdding()
                }
                .keyboardShortcut(.cancelAction)
                Button("Close Without Adding", role: .destructive) {
                    Task { await store.closeWithoutAddingWorkspace() }
                }
            }

        case .applying(let progressState):
            progress(
                progressState == .addingChanges
                    ? "Adding changes and closing workspace…"
                    : "Closing workspace…"
            )

        case .conflictAttention(let message, let details):
            Label("Changes Need Attention", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message)
            if !details.isEmpty {
                changeList(details)
            }
            HStack {
                Button("Close Without Adding…", role: .destructive) {
                    store.requestCloseWithoutAdding()
                }
                Spacer()
                Button("Return to Workspace") {
                    store.cancelCloseWorkspace()
                }
                .keyboardShortcut(.defaultAction)
            }

        case .projectSetupRequired(let changes, let needsMessage):
            Text("This project does not have shared progress yet. Set it up with these changes as the starting point?")
            changeReview(changes)
            if needsMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add a summary for the starting changes:")
                        .font(.callout)
                    TextField(
                        "Change summary",
                        text: Binding(
                            get: { store.closeWorkspace?.summary ?? "" },
                            set: { store.setCloseWorkspaceSummary($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Button("Close Without Adding…", role: .destructive) {
                    store.requestCloseWithoutAdding()
                }
                Spacer()
                Button("Cancel") {
                    store.cancelCloseWorkspace()
                }
                Button("Set Up Project & Close") {
                    Task { await store.setUpProjectAndCloseWorkspace() }
                }
                .disabled(
                    needsMessage
                        && presentation.summary
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                )
                .keyboardShortcut(.defaultAction)
            }

        case .success(let addedChanges, let notice):
            successSummary(addedChanges: addedChanges)
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            doneButton()

        case .workspaceRetained(let addedChanges, let notice):
            Label(
                addedChanges.map {
                    $0 == 1
                        ? "1 change added. Workspace remains open."
                        : "\($0) changes added. Workspace remains open."
                } ?? "Changes added. Workspace remains open.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.headline)
            .foregroundStyle(.orange)
            Text("This workspace needs attention before it can close.")
            if let notice {
                Text(notice)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Return to Workspace") {
                    store.cancelCloseWorkspace()
                }
                .keyboardShortcut(.defaultAction)
            }

        case .projectAttention(let addedChanges, let notice):
            successSummary(addedChanges: addedChanges)
            Label(
                "The project workspace needs attention before it can follow the latest project progress.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
            if let notice {
                Text(notice)
                    .foregroundStyle(.secondary)
            }
            doneButton()

        case .failure(let message):
            Label("Workspace Couldn’t Close", systemImage: "xmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(message)
            HStack {
                Spacer()
                Button("Close") {
                    store.cancelCloseWorkspace()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func changeReview(_ changes: [String]) -> some View {
        Text(changes.count == 1 ? "1 change will be added to the project:" : "\(changes.count) changes will be added to the project:")
            .font(.headline)
        changeList(changes)
    }

    private func changeList(_ changes: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(changes.enumerated()), id: \.offset) { _, summary in
                    Label(summary, systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
    }

    private func actionButtons(addEnabled: Bool) -> some View {
        HStack {
            Button("Close Without Adding…", role: .destructive) {
                store.requestCloseWithoutAdding()
            }
            Spacer()
            Button("Cancel") {
                store.cancelCloseWorkspace()
            }
            .keyboardShortcut(.cancelAction)
            Button("Add Changes & Close") {
                Task { await store.addChangesAndCloseWorkspace() }
            }
            .disabled(!addEnabled)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func progress(_ label: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(label)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
    }

    @ViewBuilder
    private func successSummary(addedChanges: Int?) -> some View {
        Label(
            addedChanges.map {
                $0 == 0
                    ? "Workspace closed."
                    : $0 == 1
                        ? "1 change added and workspace closed."
                        : "\($0) changes added and workspace closed."
            } ?? "Changes added and workspace closed.",
            systemImage: "checkmark.circle.fill"
        )
        .font(.headline)
        .foregroundStyle(.green)
    }

    private func doneButton() -> some View {
        HStack {
            Spacer()
            Button("Done") {
                store.cancelCloseWorkspace()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}
