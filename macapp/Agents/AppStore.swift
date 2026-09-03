import Combine
import Foundation

enum CloseWorkspaceProgress: Equatable {
    case addingChanges
    case closing
}

indirect enum CloseWorkspacePhase: Equatable {
    case preparing
    case ready(changes: [String])
    case summaryRequired(changes: [String])
    case noChanges
    case confirmCloseWithoutAdding(returnTo: CloseWorkspacePhase)
    case applying(CloseWorkspaceProgress)
    /// Overlap with newer project progress. `details` lists the conflicting
    /// changes a read-only preview predicted; `engineMessage` is the engine's
    /// own account of a conflict it hit while actually adding the changes,
    /// shown verbatim beneath the explanation.
    case conflictAttention(message: String, details: [String], engineMessage: String?)
    case projectSetupRequired(changes: [String], needsMessage: Bool)
    case success(addedChanges: Int?, notice: String?)
    case projectAttention(addedChanges: Int?, notice: String?)
    case failure(message: String)
}

struct CloseWorkspacePresentation: Identifiable, Equatable {
    let workspaceID: WorkspaceRow.ID
    let workspaceName: String
    let projectPath: String
    let projectName: String
    /// Distinguishes a replacement sheet for the same workspace across awaits.
    let presentationID = UUID()
    var summary = ""
    var phase: CloseWorkspacePhase
    var id: UUID { presentationID }

    var isBusy: Bool {
        switch phase {
        case .preparing, .applying:
            return true
        default:
            return false
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.workspaceID == rhs.workspaceID
            && lhs.workspaceName == rhs.workspaceName
            && lhs.projectPath == rhs.projectPath
            && lhs.projectName == rhs.projectName
            && lhs.summary == rhs.summary
            && lhs.phase == rhs.phase
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var projects: [Project] = []
    @Published var sessions: [SessionRow] = []
    @Published var workspaces: [WorkspaceRow] = []
    @Published var selection: String? {
        didSet { updateAttention() }
    }
    @Published var lastError: String?
    @Published var closeWorkspace: CloseWorkspacePresentation?
    /// What each live session's agents are currently doing, folded to one
    /// state per session for the sidebar/dashboard/badge. Derived — only
    /// `recombineAttention(for:)` writes it — from `paneAttention` below,
    /// where the actual signal reduction happens per pane. Deliberately NOT
    /// part of `PersistedState`/`save()`/`load()`: this describes live
    /// processes' current state, which has no meaningful value to restore
    /// after a relaunch — see `SessionActivity`'s doc comment.
    @Published private(set) var attention: [String: AttentionState] = [:]

    /// The source of truth behind `attention`: one reduced `AttentionState`
    /// per PANE, keyed session → pane. The reducer's unit is one agent's
    /// signal stream, and with split panes that is a pane, not a session —
    /// reducing all of a session's panes into one state would let one
    /// pane's clear erase another pane's still-open blocked indicator, and
    /// would let the first structured pane latch every sibling out of the
    /// classifier path. Written only by `apply(_:toSession:pane:)`,
    /// `setAttended`, and the pane-close pruning.
    private var paneAttention: [String: [UUID: AttentionState]] = [:]
    /// The clock `AttentionState.since` is stamped from. A settable closure
    /// rather than an inline `Date()` so tests can pin it and assert exact
    /// timestamps through `apply` and the pane fold below.
    var now: () -> Date = Date.init
    /// Project working copies whose progress hasn't been reconciled — either
    /// because automatic reconciliation failed, or because it was deferred
    /// while the project root had a live session of its own — keyed by
    /// project path so attention survives dismissal of the close sheet. Like
    /// live session attention, this is intentionally in-memory only.
    @Published private(set) var projectWorkingCopyAttention: Set<String> = []

    /// Shown when the engine hit conflicts while rebasing the workspace's
    /// changes onto the latest project progress. Unlike a predicted overlap,
    /// this one has already moved the workspace: the rebase — conflicts and
    /// all — is sitting in the workspace for the user to finish or undo.
    static let landConflictMessage = "These changes overlap newer project progress. The workspace has been moved onto the latest progress with the conflicts marked — resolve them in the workspace and close it again, or back out with jj undo (git rebase --abort)."

    /// Shown (composed with any `cleanupWarning`) whenever a successful close
    /// left reconciliation deferred rather than reconciling automatically —
    /// see `hasLiveRootSessions(in:)`. A single shared constant so tests
    /// assert against it instead of duplicating the sentence.
    static let deferredReconciliationNotice = "The project's own sessions are still running, so its workspace hasn't been updated with these changes yet. Refresh it from the project menu when you're ready."

    /// Count of sessions currently `.blocked` — agents actively burning the
    /// user's time waiting on a permission prompt, as opposed to `.yourTurn`
    /// sessions, which can sit idle indefinitely with no cost to anyone.
    /// Drives the Dock tile badge (see `dockBadgeLabel(blockedCount:)` below
    /// and its application in RootView.swift) — `.yourTurn` is deliberately
    /// excluded from the count for that same reason, so the badge only ever
    /// screams about the state that's actually costing the user something by
    /// going unnoticed.
    var blockedSessionCount: Int {
        attention.values.filter { $0.activity == .blocked }.count
    }

    /// Sessions the current close sheet will stop — every row targeting the
    /// workspace under review. Live rather than captured with the sheet so a
    /// session closed while the sheet is open is not counted; 0 with no sheet
    /// or when the workspace row is gone.
    var closeWorkspaceSessionCount: Int {
        guard let workspaceID = closeWorkspace?.workspaceID,
              let workspace = workspaces.first(where: { $0.id == workspaceID })
        else { return 0 }
        return workspaceSessionIDs(for: workspace).count
    }

    /// Pure formatting for the Dock tile's badge label, pulled out as a
    /// static so it's directly unit-testable without a running
    /// `NSApplication` — see the call site in RootView.swift for why the
    /// actual `NSApp.dockTile.badgeLabel` assignment has to happen in the
    /// view layer instead of here. `nil` (not `"0"`) is the signal
    /// `NSDockTile.badgeLabel` uses to mean "no badge at all"; returning the
    /// string `"0"` for a zero count would instead show a badge that reads
    /// "0", which is a worse resting state than no badge.
    static func dockBadgeLabel(blockedCount: Int) -> String? {
        blockedCount == 0 ? nil : "\(blockedCount)"
    }

    let terminals: any SessionTerminating
    private let engine: any WorkspaceEngineProviding

    /// Per-target session-number counters, in-memory only. Seeded from
    /// restored session names on launch; on relaunch max+1 is fine, no need
    /// to persist the counter itself. Keyed by `TargetRef.id`.
    private var sessionCounters: [String: Int] = [:]
    /// In-memory identity for each current project-path lifecycle. Every
    /// project-scoped engine operation captures this identity before awaiting;
    /// only a matching token may mutate state after removal or remove-then-readd.
    private var projectLifecycleTokens: [String: UUID] = [:]

    private let stateURL: URL

    /// Set when a corrupt state file exists but can't be moved aside (e.g.
    /// the directory became unwritable). Overwriting the user's last good
    /// state is the one unacceptable outcome, so when we can't secure the
    /// old bytes first, we disable persistence for the rest of the session
    /// rather than risk a save() clobbering them.
    private var saveDisabled = false

    /// Dev and nightly/release builds must never share one state.json: they
    /// run side by side (different bundle identifiers, different app
    /// instances), and last-writer-wins would mean whichever one saves last
    /// clobbers the other's session/workspace list. Keyed off
    /// `Bundle.main.bundleIdentifier` rather than a build-config check so
    /// this stays correct even if something other than Xcode's Debug/Release
    /// distinction ends up driving identity later.
    ///
    /// Migration note: this is a one-way split, not a rename. The existing
    /// "Agents" state directory (and everyone's real state.json in it)
    /// becomes the release/nightly app's state, unchanged, because
    /// com.kirahowe.agents (release) still maps to "Agents" here. The dev
    /// build (com.kirahowe.agents.dev) gets a brand-new "Agents Dev"
    /// directory and starts fresh — there is nothing to migrate for it, it
    /// never had persisted state of its own before this split existed.
    ///
    /// Any OTHER identity — a one-off verification build launched beside
    /// the two real ones, say — gets a directory of its own, named after
    /// its bundle id, rather than falling into the release app's. The
    /// release directory is the one place a stray build must never write:
    /// it holds the user's real rows.
    static func stateDirectoryName(forBundleIdentifier id: String?) -> String {
        switch id {
        case nil, "com.kirahowe.agents": return "Agents"
        case "com.kirahowe.agents.dev": return "Agents Dev"
        case let other?: return "Agents (\(other))"
        }
    }

    /// The app's real persisted-state location: ~/Library/Application
    /// Support/Agents/state.json (or "Agents Dev" for the dev-identity
    /// build — see `stateDirectoryName(forBundleIdentifier:)`).
    static let defaultStateURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let directoryName = stateDirectoryName(forBundleIdentifier: Bundle.main.bundleIdentifier)
        return appSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("state.json")
    }()

    init(
        terminals: any SessionTerminating,
        stateURL: URL,
        engine: any WorkspaceEngineProviding = WorkspaceEngineCLI()
    ) {
        self.terminals = terminals
        self.stateURL = stateURL
        self.engine = engine
        terminals.onProcessExit = { [weak self] id in
            self?.closeSession(id)
        }
        terminals.onSessionSignal = { [weak self] id, paneID, signal in
            self?.apply(signal, toSession: id, pane: paneID)
        }
        terminals.onPaneClosed = { [weak self] id, paneID in
            self?.removePaneAttention(sessionID: id, pane: paneID)
        }
        terminals.onTitleChange = { [weak self] id, title, roles in
            self?.setSessionTitle(title, for: id, roles: roles)
        }
        terminals.onAgentSessionEvent = { [weak self] id, event, paneTitle in
            self?.handleAgentSessionEvent(event, for: id, paneTitle: paneTitle)
        }
        load()
        projectLifecycleTokens = projects.reduce(into: [:]) { tokens, project in
            tokens[project.path] = UUID()
        }
        seedSessionCounters()
    }

    // MARK: - Project management

    func addProject(path: String) {
        let project: Project
        if let existing = projects.first(where: { $0.path == path }) {
            project = existing
        } else {
            project = Project(path: path)
            projects.append(project)
            projectLifecycleTokens[path] = UUID()
        }

        newSession(in: project)
        save()
    }

    func removeProject(_ project: Project) {
        let removedIDs = sessions.filter { $0.projectPath == project.path }.map(\.id)
        for id in removedIDs {
            terminals.closeSession(id)
        }
        sessions.removeAll { $0.projectPath == project.path }
        pruneLiveSessionState()
        projects.removeAll { $0.path == project.path }
        projectLifecycleTokens.removeValue(forKey: project.path)
        projectWorkingCopyAttention.remove(project.path)
        if closeWorkspace?.projectPath == project.path {
            closeWorkspace = nil
        }
        // Removing a project is local bookkeeping only: never destroy its
        // on-disk workspaces.
        workspaces.removeAll { $0.projectPath == project.path }
        if let selection, removedIDs.contains(selection) {
            self.selection = nil
        }
        save()
    }

    // MARK: - Workspace management

    /// `label`, when non-blank after trimming, becomes the new row's sidebar
    /// label. A nil/blank `label` (the default) leaves `label` nil, so
    /// `displayName` falls through to the engine-generated name.
    func createWorkspace(in projectPath: String, label: String? = nil) async {
        guard let lifecycleToken = projectLifecycleTokens[projectPath] else { return }
        do {
            var row = try await engine.createWorkspace(projectPath: projectPath)
            guard projectLifecycleTokens[projectPath] == lifecycleToken else { return }
            let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmedLabel, !trimmedLabel.isEmpty {
                row.label = trimmedLabel
            }
            workspaces.append(row)
            newSession(in: .workspace(projectPath: row.projectPath, name: row.name))
        } catch let error as EngineError {
            guard projectLifecycleTokens[projectPath] == lifecycleToken else { return }
            lastError = error.message
        } catch {
            guard projectLifecycleTokens[projectPath] == lifecycleToken else { return }
            lastError = "\(error)"
        }
    }

    private func isCurrentWorkspaceLifecycle(
        _ workspace: WorkspaceRow,
        token: UUID
    ) -> Bool {
        projectLifecycleTokens[workspace.projectPath] == token
            && workspaces.contains { $0.id == workspace.id && $0.path == workspace.path }
    }

    private func isCurrentClosePresentation(
        _ workspace: WorkspaceRow,
        presentationID: UUID
    ) -> Bool {
        closeWorkspace?.presentationID == presentationID
            && closeWorkspace?.workspaceID == workspace.id
            && closeWorkspace?.projectPath == workspace.projectPath
    }

    /// Starts the single close-workspace experience. The state is installed
    /// before awaiting the preview so RootView can present a stable sheet for
    /// the complete asynchronous operation. A second request is ignored until
    /// the current sheet is dismissed.

    func prepareCloseWorkspace(_ id: WorkspaceRow.ID) async {
        guard closeWorkspace == nil,
              let workspace = workspaces.first(where: { $0.id == id }),
              let lifecycleToken = projectLifecycleTokens[workspace.projectPath]
        else { return }

        let projectName = projects.first(where: { $0.path == workspace.projectPath })?.name
            ?? URL(fileURLWithPath: workspace.projectPath).lastPathComponent
        closeWorkspace = CloseWorkspacePresentation(
            workspaceID: id,
            workspaceName: workspace.displayName,
            projectPath: workspace.projectPath,
            projectName: projectName,
            phase: .preparing
        )
        guard let presentationID = closeWorkspace?.presentationID else { return }

        await refreshCloseWorkspacePreview(
            workspace,
            lifecycleToken: lifecycleToken,
            presentationID: presentationID
        )
    }

    private func refreshCloseWorkspacePreview(
        _ workspace: WorkspaceRow,
        lifecycleToken: UUID,
        presentationID: UUID
    ) async {
        guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
              isCurrentClosePresentation(workspace, presentationID: presentationID)
        else { return }

        do {
            let preview: LandPreview
            var isProjectSetup = false
            do {
                preview = try await engine.previewLand(workspace)
            } catch EngineError.noTrunk {
                guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
                      isCurrentClosePresentation(workspace, presentationID: presentationID)
                else { return }
                do {
                    preview = try await engine.previewLand(workspace, createTrunk: "main")
                } catch {
                    guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
                          isCurrentClosePresentation(workspace, presentationID: presentationID)
                    else { return }
                    throw error
                }
                isProjectSetup = true
            }

            guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
                  isCurrentClosePresentation(workspace, presentationID: presentationID)
            else { return }
            closeWorkspace?.phase = closeWorkspacePhase(
                for: preview,
                isProjectSetup: isProjectSetup
            )
        } catch EngineError.nothingToLand {
            guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
                  isCurrentClosePresentation(workspace, presentationID: presentationID)
            else { return }
            closeWorkspace?.phase = .noChanges
        } catch EngineError.noTrunk {
            guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
                  isCurrentClosePresentation(workspace, presentationID: presentationID)
            else { return }
            closeWorkspace?.phase = .failure(
                message: "The project's starting changes couldn't be prepared. Return to the workspace and try again."
            )
        } catch EngineError.landConflict, EngineError.sharedHistory {
            guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
                  isCurrentClosePresentation(workspace, presentationID: presentationID)
            else { return }
            closeWorkspace?.phase = .conflictAttention(
                message: "These changes overlap newer project progress and need attention.",
                details: [],
                engineMessage: nil
            )
        } catch EngineError.workspaceChanged(let engineMessage) {
            // The engine refused to even look: the workspace is in a state
            // that needs the user's hand first (a jj working copy left stale
            // by activity elsewhere, a git rebase still in progress). Its
            // message says exactly what to do, and nothing generic would.
            guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
                  isCurrentClosePresentation(workspace, presentationID: presentationID)
            else { return }
            closeWorkspace?.phase = .failure(message: engineMessage)
        } catch {
            guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
                  isCurrentClosePresentation(workspace, presentationID: presentationID)
            else { return }
            closeWorkspace?.phase = .failure(
                message: "The workspace's changes couldn't be compared with the project. The workspace remains open. Return to it and try again."
            )
        }
    }

    private func closeWorkspacePhase(
        for preview: LandPreview,
        isProjectSetup: Bool
    ) -> CloseWorkspacePhase {
        var changes = preview.commits.map { change in
            change.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Undescribed change"
                : change.subject
        }
        if preview.needsMessage && !preview.commits.contains(where: {
            $0.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            changes.append("Undescribed change")
        }

        if !preview.conflicts.isEmpty {
            return .conflictAttention(
                message: "These changes overlap newer project progress and need attention.",
                details: preview.conflicts.map { conflict in
                    conflict.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Conflicting change"
                        : conflict.subject
                },
                engineMessage: nil
            )
        }
        if changes.isEmpty && !preview.needsMessage {
            return .noChanges
        }
        if isProjectSetup {
            return .projectSetupRequired(
                changes: changes,
                needsMessage: preview.needsMessage
            )
        }
        if preview.needsMessage {
            return .summaryRequired(changes: changes)
        }
        return .ready(changes: changes)
    }

    func setCloseWorkspaceSummary(_ summary: String) {
        guard closeWorkspace != nil else { return }
        closeWorkspace?.summary = summary
    }

    func cancelCloseWorkspace() {
        guard closeWorkspace?.isBusy == false else { return }
        closeWorkspace = nil
    }

    func requestCloseWithoutAdding() {
        guard let phase = closeWorkspace?.phase else { return }
        switch phase {
        case .ready, .summaryRequired, .conflictAttention, .projectSetupRequired:
            closeWorkspace?.phase = .confirmCloseWithoutAdding(returnTo: phase)
        default:
            break
        }
    }

    func cancelCloseWithoutAdding() {
        guard let phase = closeWorkspace?.phase,
              case .confirmCloseWithoutAdding(let returnTo) = phase
        else { return }
        closeWorkspace?.phase = returnTo
    }

    /// Adds the prepared changes, closes the workspace only after the engine
    /// confirms success, then silently reconciles the project working copy.
    /// A race-time overlap leaves the workspace open — with the conflicted
    /// rebase in it — and changes the sheet to attention.
    func addChangesAndCloseWorkspace() async {
        guard let presentation = closeWorkspace,
              let workspace = workspaces.first(where: { $0.id == presentation.workspaceID })
        else { return }

        let changes: [String]
        let needsMessage: Bool
        let message: String?
        switch presentation.phase {
        case .ready(let preparedChanges):
            changes = preparedChanges
            needsMessage = false
            message = nil
        case .summaryRequired(let preparedChanges):
            guard !presentation.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            changes = preparedChanges
            needsMessage = true
            message = presentation.summary
        default:
            return
        }

        let setupPhase = CloseWorkspacePhase.projectSetupRequired(
            changes: changes,
            needsMessage: needsMessage
        )
        closeWorkspace?.phase = .applying(.addingChanges)
        await applyWorkspaceChanges(
            workspace,
            message: message,
            createTrunk: nil,
            presentationID: presentation.presentationID,
            changeCount: changes.count,
            noTrunkFallback: setupPhase,
            clearSummaryOnStale: needsMessage
        )
    }

    /// Recovery for projects without shared progress yet. The engine keeps
    /// the bootstrap name as an implementation detail; the sheet talks only
    /// about establishing the project's starting progress.
    func setUpProjectAndCloseWorkspace() async {
        guard let presentation = closeWorkspace,
              case .projectSetupRequired(let changes, let needsMessage) = presentation.phase,
              let workspace = workspaces.first(where: { $0.id == presentation.workspaceID })
        else { return }

        let summary = presentation.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if needsMessage && summary.isEmpty { return }

        let setupPhase = CloseWorkspacePhase.projectSetupRequired(
            changes: changes,
            needsMessage: needsMessage
        )
        closeWorkspace?.phase = .applying(.addingChanges)
        await applyWorkspaceChanges(
            workspace,
            message: needsMessage ? summary : nil,
            createTrunk: "main",
            presentationID: presentation.presentationID,
            changeCount: changes.count,
            noTrunkFallback: setupPhase,
            clearSummaryOnStale: needsMessage
        )
    }

    private func applyWorkspaceChanges(
        _ workspace: WorkspaceRow,
        message: String?,
        createTrunk: String?,
        presentationID: UUID,
        changeCount: Int?,
        noTrunkFallback: CloseWorkspacePhase,
        clearSummaryOnStale: Bool
    ) async {
        guard let lifecycleToken = projectLifecycleTokens[workspace.projectPath] else {
            return
        }
        let sessionIDs = workspaceSessionIDs(for: workspace)
        await terminals.quiesceSessions(sessionIDs)
        guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
              isCurrentClosePresentation(workspace, presentationID: presentationID)
        else {
            terminals.resumeSessions(sessionIDs)
            return
        }

        let result: LandResult
        do {
            let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            result = try await engine.landWorkspace(
                workspace,
                message: trimmed?.isEmpty == false ? trimmed : nil,
                createTrunk: createTrunk
            )
        } catch EngineError.workspaceChanged {
            terminals.resumeSessions(sessionIDs)
            guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
                  isCurrentClosePresentation(workspace, presentationID: presentationID)
            else { return }
            if clearSummaryOnStale {
                closeWorkspace?.summary = ""
            }
            closeWorkspace?.phase = .preparing
            await refreshCloseWorkspacePreview(
                workspace,
                lifecycleToken: lifecycleToken,
                presentationID: presentationID
            )
            return
        } catch EngineError.noTrunk {
            terminals.resumeSessions(sessionIDs)
            guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
                  isCurrentClosePresentation(workspace, presentationID: presentationID)
            else { return }
            closeWorkspace?.phase = noTrunkFallback
            return
        } catch EngineError.landConflict(let engineMessage) {
            // The engine rebased onto the latest progress and the result
            // conflicts, so the conflicted rebase is sitting in the workspace
            // now. Sessions come back and the row stays; the sheet explains
            // what is there to resolve.
            terminals.resumeSessions(sessionIDs)
            guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
                  isCurrentClosePresentation(workspace, presentationID: presentationID)
            else { return }
            closeWorkspace?.phase = .conflictAttention(
                message: Self.landConflictMessage,
                details: [],
                engineMessage: engineMessage
            )
            return
        } catch EngineError.sharedHistory {
            terminals.resumeSessions(sessionIDs)
            guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
                  isCurrentClosePresentation(workspace, presentationID: presentationID)
            else { return }
            closeWorkspace?.phase = .conflictAttention(
                message: "These changes overlap newer project progress and need attention.",
                details: [],
                engineMessage: nil
            )
            return
        } catch EngineError.cleanupFailed(let engineMessage) {
            // Project progress moved, but the workspace could not be
            // deregistered — so this close failed. The engine's own account
            // is the only accurate one; closing again will find nothing left
            // to add and offer a plain close.
            terminals.resumeSessions(sessionIDs)
            guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
                  isCurrentClosePresentation(workspace, presentationID: presentationID)
            else { return }
            closeWorkspace?.phase = .failure(message: engineMessage)
            return
        } catch EngineError.nothingToLand {
            terminals.resumeSessions(sessionIDs)
            guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
                  isCurrentClosePresentation(workspace, presentationID: presentationID)
            else { return }
            closeWorkspace?.phase = .noChanges
            return
        } catch {
            terminals.resumeSessions(sessionIDs)
            guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
                  isCurrentClosePresentation(workspace, presentationID: presentationID)
            else { return }
            closeWorkspace?.phase = .failure(
                message: "The changes couldn't be added to the project. The workspace remains open. Return to it and try again."
            )
            return
        }
        guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken) else {
            terminals.resumeSessions(sessionIDs)
            return
        }

        // Success means the engine no longer knows this workspace, so its
        // row, sessions, and selection always go with it.
        tearDownClosedWorkspace(workspace)

        if hasLiveRootSessions(in: workspace.projectPath) {
            // The project root itself is a session target. Rewriting its
            // working copy while one of its own terminals is live would
            // change files underneath that session, so reconciliation is
            // deferred to a manual refresh from the project menu instead of
            // running automatically here.
            projectWorkingCopyAttention.insert(workspace.projectPath)
            guard projectLifecycleTokens[workspace.projectPath] == lifecycleToken,
                  isCurrentClosePresentation(workspace, presentationID: presentationID)
            else { return }
            let notice = [result.cleanupWarning, Self.deferredReconciliationNotice]
                .compactMap { $0 }
                .joined(separator: "\n")
            closeWorkspace?.phase = .success(addedChanges: changeCount, notice: notice)
            return
        }

        let reconciled = await reconcileProjectWorkspace(workspace.projectPath)
        guard projectLifecycleTokens[workspace.projectPath] == lifecycleToken,
              isCurrentClosePresentation(workspace, presentationID: presentationID)
        else { return }
        closeWorkspace?.phase = reconciled
            ? .success(
                addedChanges: changeCount,
                notice: result.cleanupWarning
            )
            : .projectAttention(
                addedChanges: changeCount,
                notice: result.cleanupWarning
            )
    }

    /// Retries reconciliation for a project whose working copy needs attention.
    /// Failures remain silent and keep the project flagged for another retry.
    func refreshProjectWorkspace(_ projectPath: String) async {
        _ = await reconcileProjectWorkspace(projectPath)
    }

    @discardableResult
    private func reconcileProjectWorkspace(_ projectPath: String) async -> Bool {
        guard let lifecycleToken = projectLifecycleTokens[projectPath] else {
            return true
        }

        do {
            _ = try await engine.rebaseOntoTrunk(projectPath: projectPath)
            guard projectLifecycleTokens[projectPath] == lifecycleToken else {
                return true
            }
            projectWorkingCopyAttention.remove(projectPath)
            return true
        } catch {
            guard projectLifecycleTokens[projectPath] == lifecycleToken else {
                return true
            }
            projectWorkingCopyAttention.insert(projectPath)
            return false
        }
    }

    /// Closes without adding. A workspace known to have changes reaches this
    /// operation only through the in-sheet destructive confirmation; the
    /// no-changes state closes directly without an unnecessary second prompt.
    /// Every live and persisted row remains intact until the engine confirms
    /// the irreversible forget. Directory cleanup after that boundary is a
    /// non-fatal notice, not a reason to leave a false retry marker.
    func closeWithoutAddingWorkspace() async {
        guard let presentation = closeWorkspace,
              let workspace = workspaces.first(where: { $0.id == presentation.workspaceID })
        else { return }
        guard let lifecycleToken = projectLifecycleTokens[workspace.projectPath] else {
            return
        }
        let presentationID = presentation.presentationID

        let onlyIfUnchanged: Bool
        switch presentation.phase {
        case .noChanges:
            onlyIfUnchanged = true
        case .confirmCloseWithoutAdding:
            onlyIfUnchanged = false
        default:
            return
        }

        closeWorkspace?.phase = .applying(.closing)
        let sessionIDs = workspaceSessionIDs(for: workspace)
        await terminals.quiesceSessions(sessionIDs)
        guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
              isCurrentClosePresentation(workspace, presentationID: presentationID)
        else {
            terminals.resumeSessions(sessionIDs)
            return
        }

        do {
            let result = try await engine.deleteWorkspace(
                workspace,
                onlyIfUnchanged: onlyIfUnchanged
            )
            guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken) else {
                terminals.resumeSessions(sessionIDs)
                return
            }
            tearDownClosedWorkspace(workspace)
            guard projectLifecycleTokens[workspace.projectPath] == lifecycleToken,
                  isCurrentClosePresentation(workspace, presentationID: presentationID)
            else { return }
            closeWorkspace?.phase = .success(
                addedChanges: 0,
                notice: result.cleanupWarning
            )
        } catch EngineError.workspaceChanged {
            terminals.resumeSessions(sessionIDs)
            guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
                  isCurrentClosePresentation(workspace, presentationID: presentationID)
            else { return }
            closeWorkspace?.phase = .preparing
            await refreshCloseWorkspacePreview(
                workspace,
                lifecycleToken: lifecycleToken,
                presentationID: presentationID
            )
        } catch {
            terminals.resumeSessions(sessionIDs)
            guard isCurrentWorkspaceLifecycle(workspace, token: lifecycleToken),
                  isCurrentClosePresentation(workspace, presentationID: presentationID)
            else { return }
            closeWorkspace?.phase = .failure(
                message: "The workspace couldn't be closed. The workspace remains open. Return to it and try again."
            )
        }
    }

    /// True when the project root itself (not any workspace) has a live
    /// session — often an agent mid-task whose files would change underneath
    /// it if the working copy were rewritten. Gates automatic reconciliation
    /// in `applyWorkspaceChanges`; deliberately NOT consulted by
    /// `refreshProjectWorkspace`, which is the user's explicit "I'm ready
    /// now" signal and must stay ungated.
    private func hasLiveRootSessions(in projectPath: String) -> Bool {
        sessions.contains { $0.target == .root(projectPath: projectPath) }
    }

    private func workspaceSessionIDs(for workspace: WorkspaceRow) -> Set<String> {
        let target = TargetRef.workspace(
            projectPath: workspace.projectPath,
            name: workspace.name
        )
        return Set(sessions.lazy.filter { $0.target == target }.map(\.id))
    }

    private func tearDownClosedWorkspace(_ workspace: WorkspaceRow) {
        tearDownWorkspaceSessions(workspace)
        workspaces.removeAll { $0.id == workspace.id }
        save()
    }

    private func tearDownWorkspaceSessions(_ workspace: WorkspaceRow) {
        let target = TargetRef.workspace(projectPath: workspace.projectPath, name: workspace.name)
        let removedIDs = sessions.filter { $0.target == target }.map(\.id)
        for sessionID in removedIDs {
            terminals.closeSession(sessionID)
        }
        sessions.removeAll { $0.target == target }
        pruneLiveSessionState()
        if let selection, removedIDs.contains(selection) {
            self.selection = nil
        }
    }

    func setWorkspaceLabel(_ id: WorkspaceRow.ID, label: String?) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaces[index].label = (trimmed?.isEmpty ?? true) ? nil : trimmed
        save()
    }

    // MARK: - Session management

    /// Primary API: create a session on an explicit target, or (nil) resolve
    /// one — selection's target, else the first ordered target, else no-op.
    /// `name`, when non-blank after trimming, is used as-is for the new
    /// row's name. A nil/blank `name` (the default) falls back to today's
    /// numbered "Session N" naming from `sessionCounters`.
    func newSession(in target: TargetRef?, name: String? = nil) {
        let resolvedTarget: TargetRef?
        if let target {
            resolvedTarget = target
        } else if let selection,
                  let owningRow = sessions.first(where: { $0.id == selection })
        {
            resolvedTarget = owningRow.target
        } else {
            resolvedTarget = orderedTargets.first
        }
        guard let resolvedTarget else { return }

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rowName: String
        if let trimmedName, !trimmedName.isEmpty {
            // A custom name deliberately does NOT consume a counter number:
            // the counter exists only to keep the *numbered* names
            // sequential, and seedSessionCounters() below only ever parses
            // "Session N" names anyway — a custom name was never going to
            // contribute to it.
            rowName = trimmedName
        } else {
            let number = sessionCounters[resolvedTarget.id, default: 1]
            sessionCounters[resolvedTarget.id] = number + 1
            rowName = "Session \(number)"
        }

        let row = SessionRow(id: UUID().uuidString, target: resolvedTarget, name: rowName)
        sessions.append(row)
        selection = row.id
        save()
    }

    /// Compat shim for existing call sites that still think in terms of
    /// `Project` (SidebarView's per-project "+" button, `addProject`). Always
    /// resolves to that project's root target. Deliberately non-optional Project
    /// (not Project?) — an optional-Project overload here would make the
    /// existing bare `store.newSession(in: nil)` call sites in AppActions.swift
    /// ambiguous against the TargetRef? overload above.
    func newSession(in project: Project, name: String? = nil) {
        newSession(in: .root(projectPath: project.path), name: name)
    }

    /// Used by the sidebar's workspace-row tap: selects that workspace's
    /// first (`sessions` array order) session if it has one, else creates a
    /// fresh one via `newSession(in:)` (which also selects and saves).
    func selectOrCreateSession(in target: TargetRef) {
        if let first = sessions.first(where: { $0.target == target }) {
            selection = first.id
            save()
        } else {
            newSession(in: target)
        }
    }

    func closeSession(_ id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let row = sessions[index]
        let wasSelected = selection == id

        terminals.closeSession(id)
        sessions.remove(at: index)
        pruneLiveSessionState()

        if wasSelected {
            let siblings = sessions.enumerated().filter { $0.element.target == row.target }
            if siblings.isEmpty {
                selection = nil
            } else if let next = siblings.first(where: { $0.offset >= index }) {
                selection = next.element.id
            } else {
                selection = siblings.last?.element.id
            }
        }
        save()
    }

    /// The single funnel for every pane attention signal, from every source
    /// — nothing else in the app may write `paneAttention`. Ignores ids
    /// with no matching row in `sessions` — a signal racing that session's
    /// own teardown is a normal, harmless race, not an error to surface.
    /// Deliberately never calls `save()`: this state is not persisted (see
    /// `attention`'s doc comment).
    ///
    /// A pane's very first signal seeds its state with the session's
    /// current attended flag rather than the default `false`: `isAttended`
    /// suppression exists so a row the user is already looking at never
    /// raises, and a freshly split pane in the selected session is exactly
    /// as looked-at as its siblings — its first bell must not light the row.
    func apply(_ signal: AttentionSignal, toSession sessionID: String, pane paneID: UUID) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        let seed = AttentionState(
            activity: nil, isStructured: false, isAttended: attendedSessionID == sessionID
        )
        var panes = paneAttention[sessionID] ?? [:]
        panes[paneID] = SessionAttention.reduce(panes[paneID] ?? seed, signal, at: now())
        paneAttention[sessionID] = panes
        recombineAttention(for: sessionID)
    }

    /// Drops a closed pane's contribution — wired to
    /// `SessionTerminating.onPaneClosed`. Without this, a pane closed while
    /// blocked would keep its session's row red forever.
    private func removePaneAttention(sessionID: String, pane paneID: UUID) {
        guard paneAttention[sessionID]?.removeValue(forKey: paneID) != nil else { return }
        if paneAttention[sessionID]?.isEmpty == true {
            paneAttention.removeValue(forKey: sessionID)
        }
        recombineAttention(for: sessionID)
    }

    /// Folds a session's pane states into the one `attention` entry its row
    /// renders. The fold is a pure severity max: any pane blocked → the row
    /// is blocked; else any pane your-turn → your-turn; else nothing. The
    /// combined `isStructured` is "any pane speaks the protocol" (only
    /// meaningful to observers; each pane's own latch lives in its own
    /// state), `isAttended` restates the session-level attended fact, and
    /// `since` is the earliest pane to reach the winning state. With one pane — every session until its first split — this fold is
    /// the identity, so nothing about single-pane behavior changes.
    private func recombineAttention(for sessionID: String) {
        let isAttended = attendedSessionID == sessionID
        guard let states = paneAttention[sessionID].map(Array.init), !states.isEmpty else {
            // No pane has ever signaled. Attended sessions still materialize
            // an entry: `isAttended` must be readable the moment the user
            // selects a row, signals or not.
            attention[sessionID] = isAttended
                ? AttentionState(activity: nil, isStructured: false, isAttended: true)
                : nil
            return
        }
        let activities = states.map(\.value.activity)
        let activity: SessionActivity? = activities.contains(.blocked)
            ? .blocked
            : activities.contains(.yourTurn) ? .yourTurn : nil
        // The row has been in its winning state since the EARLIEST pane
        // reached it: two panes both blocked means the user has been holding
        // up the older one that long. Panes in a lesser state don't vote — a
        // pane your-turn since 9:50 says nothing about how long the row has
        // been blocked.
        let since = states.compactMap { $0.value.activity == activity ? $0.value.since : nil }.min()
        attention[sessionID] = AttentionState(
            activity: activity,
            isStructured: states.contains { $0.value.isStructured },
            isAttended: isAttended,
            since: since
        )
    }

    /// Applies the attended/un-attended transition to every pane stream of
    /// a session (suppression and clears happen per pane, in the reducer),
    /// then refolds the row's entry.
    private func setAttended(_ sessionID: String, _ isAttended: Bool) {
        if var panes = paneAttention[sessionID] {
            for (paneID, state) in panes {
                panes[paneID] = SessionAttention.reduce(
                    state, .attentionChanged(isAttended: isAttended), at: now()
                )
            }
            paneAttention[sessionID] = panes
        }
        recombineAttention(for: sessionID)
    }

    /// Whether the app itself is frontmost. AppStore stays AppKit-free (only
    /// `Combine` and `Foundation` are imported at the top of this file, on
    /// purpose — see the same reasoning applied to `blockedSessionCount` in
    /// RootView.swift's Dock-badge comment), so it has no way to observe
    /// NSApplication activation itself. The view layer feeds this in via
    /// `setAppActive(_:)` from real `NSApplication.didBecomeActive`/
    /// `didResignActive` notifications, plus one seed call at launch (see
    /// RootView.swift's `.task`).
    ///
    /// Deliberately NOT `@Published`: nothing renders from this value
    /// directly — it exists purely to feed `updateAttention()` below.
    private(set) var isAppActive = false

    /// Called by the view layer on NSApplication activate/resign, and once
    /// at launch to seed the state neither notification fires for (see
    /// RootView.swift). Guards on the actual change for the same reason
    /// `updateAttention()` itself guards on the transition rather than the
    /// input — see that method's doc comment.
    func setAppActive(_ isActive: Bool) {
        guard isAppActive != isActive else { return }
        isAppActive = isActive
        updateAttention()
    }

    /// The session currently attended, i.e. the one `.attentionChanged(true)`
    /// was last sent for. Tracked separately from `selection` because
    /// `updateAttention()` needs the PREVIOUS attended session, not just the
    /// current one — `selection` alone can't answer "what was attended a
    /// moment ago," and that's exactly what has to be un-attended below.
    private var attendedSessionID: String?

    /// The one place `.attentionChanged` is ever emitted — reached from two
    /// independent inputs: `selection`'s `didSet` and `setAppActive(_:)`.
    ///
    /// The un-attend leg (the `if let previous` branch) is NOT optional. A
    /// session that was attended when the user switched away must have
    /// `isAttended` cleared, or every later notification for it would be
    /// silently dropped forever as "they're already looking at it" (see
    /// `SessionAttention.reduce`'s `.notification`/`.bell` cases) — that
    /// row could never light up again for the rest of its life. This is the
    /// single most consequential line in this stage.
    ///
    /// This keys on the session id and nothing coarser — never the project
    /// or workspace it belongs to. cmux (#5095) auto-withdrew attention at a
    /// level coarser than the unit of attention and silently ate
    /// notifications for a second, unattended agent sharing the same
    /// container; the unit of attention here is one session, full stop (see
    /// design/session-attention.md section D).
    ///
    /// The guard is on the TRANSITION (`next != attendedSessionID`), not on
    /// each input, because `didSet` fires on same-value writes too (SwiftUI's
    /// sidebar rewrites `selection` through the `List` binding even when the
    /// value doesn't change) and this function is reached from two
    /// independent call sites — without the guard, a same-value selection
    /// write or a redundant `setAppActive` call would re-run the un-attend/
    /// attend pair on a session nothing actually changed for.
    ///
    /// The stale-id case needs no special handling here: `apply(_:to:)`
    /// above already ignores ids with no live session, so an un-attend aimed
    /// at a session that was just closed is a harmless no-op.
    private func updateAttention() {
        let next = isAppActive ? selection : nil
        guard next != attendedSessionID else { return }
        let previous = attendedSessionID
        // Flag first, transitions second: `recombineAttention` (inside
        // `setAttended`) derives each row's `isAttended` from this field,
        // so both refolds below must already see the new attended session.
        attendedSessionID = next
        if let previous {
            setAttended(previous, false)
        }
        if let next {
            setAttended(next, true)
        }
    }

    /// Records a session's latest agent-set OSC terminal title onto its row
    /// as `agentTitle` — the sidebar/window name for any session the user
    /// hasn't manually renamed. Persisted (via `save()`), so the name stays
    /// stable across relaunches rather than flashing back to "Session N"
    /// until the agent re-announces.
    ///
    /// A blank/whitespace-only title is IGNORED, not treated as a clear:
    /// "remember the last title" means a shell that quietly resets its title
    /// (e.g. the agent exits and the bare prompt takes over) must not wipe
    /// the name. A title identical to the one already stored is a no-op too,
    /// so agents that re-emit the same title on every turn don't churn a
    /// state.json write each time. Ids with no matching row (a title racing
    /// that session's teardown) are a harmless no-op.
    ///
    /// `roles` gates which facts this title may update (see
    /// `SessionTerminating.onTitleChange`): only a `.display` title touches
    /// `agentTitle`, and only a `.resume` title — the resume-designate
    /// pane's — may relabel `resume.title`. In a split, the focused pane's
    /// title arriving with `.display` alone is what keeps a sibling's task
    /// name out of another agent's resume record. The default covers every
    /// single-pane emit, where one pane holds both roles.
    func setSessionTitle(
        _ title: String, for sessionID: String, roles: SessionTitleRoles = [.display, .resume]
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var changed = false
        if roles.contains(.display), sessions[index].agentTitle != trimmed {
            sessions[index].agentTitle = trimmed
            changed = true
        }
        if roles.contains(.resume),
           var resume = sessions[index].resume,
           let cleanTitle = SessionResumeMetadata.normalizedTitle(trimmed, agent: resume.agent),
           resume.title != cleanTitle
        {
            resume.title = cleanTitle
            sessions[index].resume = resume
            changed = true
        }
        guard changed else { return }
        save()
    }

    /// Persists the resumable agent session announced for one terminal row,
    /// whichever harness announced it. "Same session" now means the same
    /// (agent, session id) pair: a changed id, or a changed harness
    /// entirely (e.g. Claude Code taking over a row OMP last ran in),
    /// replaces the prior snapshot; subsequent events for the same pair
    /// only fill or update the title/prompt fields.
    func handleAgentSessionEvent(
        _ event: AgentSessionEvent, for sessionID: String, paneTitle: String?
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }

        // Seed the label from `paneTitle` — the AUTHORING pane's own OSC
        // title, attached to the event by TerminalCenter — and only that:
        // `agentTitle` is the focused pane's, which in a split may be a
        // sibling agent's task name, and a lying label is worse than none.
        // Nil (fresh pane, or first event after a relaunch before the shell
        // titles itself) leaves the label empty until the authoring pane's
        // next `.resume`-role title fills it in via setSessionTitle.
        let currentDecoratedTitle = paneTitle.flatMap {
            SessionResumeMetadata.normalizedTitle($0, agent: event.agent)
        }
        var next: SessionResumeMetadata
        if let existing = sessions[index].resume,
           existing.agent == event.agent, existing.sessionID == event.sessionID
        {
            next = existing
            if next.title == nil {
                next.title = currentDecoratedTitle
            }
            if let query = event.query {
                next.prompt = query
            }
            if let home = event.home {
                next.home = home
            }
        } else {
            next = SessionResumeMetadata(
                agent: event.agent,
                sessionID: event.sessionID,
                title: currentDecoratedTitle,
                prompt: event.query,
                home: event.home
            )
            // Logged only when the identity changes, not on every prompt:
            // this is the one line that says a row became resumable as a
            // particular session, which is what to look for when a restored
            // row prints no banner.
            NSLog("Agents: session \(sessionID) is now resumable as \(event.agent) \(event.sessionID)")
        }

        guard sessions[index].resume != next else { return }
        sessions[index].resume = next
        save()
    }

    /// Drops live-only attention after session rows are removed.
    private func pruneLiveSessionState() {
        let liveIDs = Set(sessions.map(\.id))
        attention = attention.filter { liveIDs.contains($0.key) }
        paneAttention = paneAttention.filter { liveIDs.contains($0.key) }
    }

    /// A manual rename writes `customName`, not `name`: it must win over —
    /// and survive — any agent-set `agentTitle`, and it deliberately leaves
    /// the auto "Session N" (`name`) intact as the counter seed and fallback.
    /// A blank name is a no-op (it does NOT clear an existing custom name):
    /// clearing would need its own affordance, and silently reverting to the
    /// agent title on an accidental empty submit would be surprising.
    func renameSession(_ id: String, to name: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessions[index].customName = trimmed
        save()
    }

    /// Reorders sessions within one sidebar bucket (project root or one
    /// workspace). Cross-target moves are intentionally unsupported: the
    /// sidebar only ever drags within the target-specific `ForEach`, and a
    /// session's terminal working directory/identity is defined by its
    /// existing `TargetRef`, not by drag destination.
    func moveSessions(in target: TargetRef, fromOffsets: IndexSet, toOffset: Int) {
        let targetIndices = sessions.indices.filter { sessions[$0].target == target }
        guard !targetIndices.isEmpty else { return }

        let targetSessions = targetIndices.map { sessions[$0] }
        guard let reordered = reorderedTargetSessions(
            targetSessions,
            fromOffsets: fromOffsets,
            toOffset: toOffset
        ), reordered != targetSessions else {
            return
        }

        for (globalIndex, session) in zip(targetIndices, reordered) {
            sessions[globalIndex] = session
        }
        save()
    }

    // MARK: - Navigation

    /// For each project in `projects` order: its root target, then its
    /// workspaces in `workspaces` array order (not re-sorted).
    var orderedTargets: [TargetRef] {
        projects.flatMap { project -> [TargetRef] in
            let root = TargetRef.root(projectPath: project.path)
            let workspaceTargets = workspaces
                .filter { $0.projectPath == project.path }
                .map { TargetRef.workspace(projectPath: $0.projectPath, name: $0.name) }
            return [root] + workspaceTargets
        }
    }

    /// Sidebar display order: for each ordered target, that target's
    /// sessions in `sessions` array order. Mirrors exactly what SidebarView
    /// renders — project A's sessions all before project B's, even when
    /// insertion interleaved the two projects. With zero workspaces this
    /// produces exactly what the old project-based version did.
    var orderedSessions: [SessionRow] {
        orderedTargets.flatMap { target in
            sessions.filter { $0.target == target }
        }
    }

    func selectNext() {
        let ordered = orderedSessions
        guard !ordered.isEmpty else { return }
        guard let currentID = selection,
              let index = ordered.firstIndex(where: { $0.id == currentID })
        else {
            selection = ordered.first?.id
            save()
            return
        }
        let nextIndex = ordered.index(after: index)
        selection = nextIndex == ordered.endIndex ? ordered[ordered.startIndex].id : ordered[nextIndex].id
        save()
    }

    func selectPrevious() {
        let ordered = orderedSessions
        guard !ordered.isEmpty else { return }
        guard let currentID = selection,
              let index = ordered.firstIndex(where: { $0.id == currentID })
        else {
            selection = ordered.last?.id
            save()
            return
        }
        if index == ordered.startIndex {
            selection = ordered.last?.id
        } else {
            selection = ordered[ordered.index(before: index)].id
        }
        save()
    }

    @discardableResult
    func selectSession(at index: Int) -> Bool {
        let ordered = orderedSessions
        guard ordered.indices.contains(index) else { return false }
        selection = ordered[index].id
        save()
        return true
    }

    // MARK: - Terminal working directory

    /// Resolves the working directory a session's terminal should spawn
    /// into: the project root for a root-targeted session, or the matching
    /// `WorkspaceRow`'s `path` for a workspace-targeted one. Falls back to
    /// the project path if the `WorkspaceRow` is missing — shouldn't happen
    /// in practice, but a terminal must still spawn somewhere sane rather
    /// than crash/fail if local state ever desyncs from the workspace list.
    func workingDirectory(for session: SessionRow) -> String {
        switch session.target {
        case .root(let projectPath):
            return projectPath
        case .workspace(let projectPath, let name):
            if let workspace = workspaces.first(where: { $0.projectPath == projectPath && $0.name == name }) {
                return workspace.path
            }
            return projectPath
        }
    }

    // MARK: - Persistence

    /// A file that plain doesn't exist yet (first launch, or the app's
    /// Application Support directory was never created) is not corruption —
    /// starting fresh there has no side effects to protect against. Only a
    /// file that EXISTS but fails to read or decode is treated as data to
    /// preserve, because every mutating store method calls save(): silently
    /// starting empty in that case would mean the user's very next action
    /// overwrites their last good state.json with nothing.
    private func load() {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }

        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else {
            moveAsideCorruptStateFile()
            return
        }

        projects = state.projects.map { Project(path: $0) }
        sessions = state.sessions
        workspaces = state.workspaces
        selection = state.selection
    }

    /// Renames an unreadable/undecodable state.json to a sibling file
    /// instead of deleting or (via the next save()) overwriting it, so the
    /// old bytes stay recoverable. The timestamp plus UUID suffix means two
    /// failures in the same second can never collide on a name.
    private func moveAsideCorruptStateFile() {
        let directory = stateURL.deletingLastPathComponent()
        let timestamp = Self.corruptStampFormatter.string(from: Date())
        let uniqueSuffix = UUID().uuidString.prefix(8)
        let corruptURL = directory.appendingPathComponent(
            "\(stateURL.lastPathComponent).corrupt-\(timestamp)-\(uniqueSuffix)"
        )

        do {
            try FileManager.default.moveItem(at: stateURL, to: corruptURL)
            NSLog("Agents: state file at \(stateURL.path) was unreadable or undecodable; moved aside to \(corruptURL.path)")
        } catch {
            // Can't secure the old file, so refuse to write at all this
            // session — see `saveDisabled`'s doc comment for why.
            NSLog("Agents: failed to move aside corrupt state file at \(stateURL.path): \(error); persistence disabled for this session")
            saveDisabled = true
        }
    }

    private static let corruptStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private func save() {
        // See `saveDisabled`'s doc comment: a corrupt state file we couldn't
        // move aside means the old bytes are still sitting at stateURL, so
        // writing here would destroy them. Skip the write entirely.
        guard !saveDisabled else { return }

        let state = PersistedState(
            version: 2,
            projects: projects.map(\.path),
            sessions: sessions,
            workspaces: workspaces,
            selection: selection
        )
        do {
            let directory = stateURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            NSLog("Agents: failed to save state: \(error)")
        }
    }

    private func seedSessionCounters() {
        for target in orderedTargets {
            let maxNumber = sessions
                .filter { $0.target == target }
                .compactMap { row -> Int? in
                    guard row.name.hasPrefix("Session ") else { return nil }
                    return Int(row.name.dropFirst("Session ".count))
                }
                .max() ?? 0
            sessionCounters[target.id] = maxNumber + 1
        }
    }

    private func reorderedTargetSessions(
        _ targetSessions: [SessionRow],
        fromOffsets: IndexSet,
        toOffset: Int
    ) -> [SessionRow]? {
        guard !fromOffsets.isEmpty else { return nil }
        guard fromOffsets.allSatisfy(targetSessions.indices.contains),
              (0...targetSessions.count).contains(toOffset)
        else {
            return nil
        }

        let movingSessions = fromOffsets.map { targetSessions[$0] }
        var remainingSessions: [SessionRow] = []
        remainingSessions.reserveCapacity(targetSessions.count - movingSessions.count)
        for (index, session) in targetSessions.enumerated() where !fromOffsets.contains(index) {
            remainingSessions.append(session)
        }

        let removedBeforeDestination = fromOffsets.count(in: 0..<toOffset)
        let insertionIndex = min(
            max(toOffset - removedBeforeDestination, 0),
            remainingSessions.count
        )
        remainingSessions.insert(contentsOf: movingSessions, at: insertionIndex)
        return remainingSessions
    }
}
