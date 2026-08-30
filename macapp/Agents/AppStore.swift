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
    case conflictAttention(message: String, details: [String])
    case projectSetupRequired
    case success(addedChanges: Int?, notice: String?)
    case projectAttention(addedChanges: Int?, notice: String?)
    case failure(message: String)
}

struct CloseWorkspacePresentation: Identifiable, Equatable {
    let workspaceID: WorkspaceRow.ID
    let workspaceName: String
    let projectName: String
    var summary = ""
    var phase: CloseWorkspacePhase

    var id: WorkspaceRow.ID { workspaceID }

    var isBusy: Bool {
        switch phase {
        case .preparing, .applying:
            return true
        default:
            return false
        }
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
    /// What each live session's agent is currently doing, resolved from
    /// every signal source (structured hook payloads, classified free-text
    /// notifications, bells, and the user's own focus) by
    /// `SessionAttention.reduce` — see `apply(_:to:)`, the only place this
    /// is written. Deliberately NOT part of `PersistedState`/`save()`/
    /// `load()`: this describes a live process's current state, which has
    /// no meaningful value to restore after a relaunch — see
    /// `SessionActivity`'s doc comment.
    @Published private(set) var attention: [String: AttentionState] = [:]
    /// Project working copies whose progress could not be reconciled, keyed
    /// by project path so attention survives dismissal of the close sheet.
    /// Like live session attention, this is intentionally in-memory only.
    @Published private(set) var projectWorkingCopyAttention: Set<String> = []

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
    static func stateDirectoryName(forBundleIdentifier id: String?) -> String {
        id == "com.kirahowe.agents.dev" ? "Agents Dev" : "Agents"
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
        terminals.onSessionSignal = { [weak self] id, signal in
            self?.apply(signal, to: id)
        }
        terminals.onTitleChange = { [weak self] id, title in
            self?.setSessionTitle(title, for: id)
        }
        terminals.onAgentSessionEvent = { [weak self] id, event in
            self?.handleAgentSessionEvent(event, for: id)
        }
        load()
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
        do {
            var row = try await engine.createWorkspace(projectPath: projectPath)
            let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmedLabel, !trimmedLabel.isEmpty {
                row.label = trimmedLabel
            }
            workspaces.append(row)
            newSession(in: .workspace(projectPath: row.projectPath, name: row.name))
        } catch let error as EngineError {
            lastError = error.message
        } catch {
            lastError = "\(error)"
        }
    }

    /// Starts the single close-workspace experience. The state is installed
    /// before awaiting the preview so RootView can present a stable sheet for
    /// the complete asynchronous operation. A second request is ignored until
    /// the current sheet is dismissed.
    func prepareCloseWorkspace(_ id: WorkspaceRow.ID) async {
        guard closeWorkspace == nil,
              let workspace = workspaces.first(where: { $0.id == id })
        else { return }

        let projectName = projects.first(where: { $0.path == workspace.projectPath })?.name
            ?? URL(fileURLWithPath: workspace.projectPath).lastPathComponent
        closeWorkspace = CloseWorkspacePresentation(
            workspaceID: id,
            workspaceName: workspace.displayName,
            projectName: projectName,
            phase: .preparing
        )

        do {
            let preview = try await engine.previewLand(workspace)
            guard closeWorkspace?.workspaceID == id else { return }
            let changes = preview.commits.map { change in
                change.subject.isEmpty ? "Undescribed change" : change.subject
            }
            if !preview.conflicts.isEmpty {
                closeWorkspace?.phase = .conflictAttention(
                    message: "These changes overlap newer project progress and need attention.",
                    details: preview.conflicts.map { conflict in
                        conflict.subject.isEmpty ? "Conflicting change" : conflict.subject
                    }
                )
            } else if changes.isEmpty {
                closeWorkspace?.phase = .noChanges
            } else if preview.needsMessage {
                closeWorkspace?.phase = .summaryRequired(changes: changes)
            } else {
                closeWorkspace?.phase = .ready(changes: changes)
            }
        } catch EngineError.nothingToLand {
            guard closeWorkspace?.workspaceID == id else { return }
            closeWorkspace?.phase = .noChanges
        } catch EngineError.noTrunk {
            guard closeWorkspace?.workspaceID == id else { return }
            closeWorkspace?.phase = .projectSetupRequired
        } catch let error as EngineError {
            guard closeWorkspace?.workspaceID == id else { return }
            closeWorkspace?.phase = .failure(message: error.message)
        } catch {
            guard closeWorkspace?.workspaceID == id else { return }
            closeWorkspace?.phase = .failure(message: "\(error)")
        }
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
        case .ready, .summaryRequired, .conflictAttention:
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
    /// A race-time overlap changes the sheet to attention without touching the
    /// workspace or any of its sessions.
    func addChangesAndCloseWorkspace() async {
        guard let presentation = closeWorkspace,
              let workspace = workspaces.first(where: { $0.id == presentation.workspaceID })
        else { return }

        let changeCount: Int
        switch presentation.phase {
        case .ready(let changes):
            changeCount = changes.count
        case .summaryRequired(let changes):
            guard !presentation.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            changeCount = changes.count
        default:
            return
        }

        closeWorkspace?.phase = .applying(.addingChanges)
        await applyWorkspaceChanges(
            workspace,
            message: presentation.summary,
            createTrunk: nil,
            changeCount: changeCount
        )
    }

    /// Recovery for projects without shared progress yet. The engine keeps
    /// the bootstrap name as an implementation detail; the sheet talks only
    /// about establishing the project's starting progress.
    func setUpProjectAndCloseWorkspace() async {
        guard let presentation = closeWorkspace,
              case .projectSetupRequired = presentation.phase,
              let workspace = workspaces.first(where: { $0.id == presentation.workspaceID })
        else { return }

        let summary = presentation.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return }

        closeWorkspace?.phase = .applying(.addingChanges)
        await applyWorkspaceChanges(
            workspace,
            message: summary,
            createTrunk: "main",
            changeCount: nil
        )
    }

    private func applyWorkspaceChanges(
        _ workspace: WorkspaceRow,
        message: String,
        createTrunk: String?,
        changeCount: Int?
    ) async {
        let result: LandResult
        do {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            result = try await engine.landWorkspace(
                workspace,
                message: trimmed.isEmpty ? nil : trimmed,
                createTrunk: createTrunk
            )
        } catch EngineError.noTrunk {
            closeWorkspace?.phase = .projectSetupRequired
            return
        } catch EngineError.landConflict {
            closeWorkspace?.phase = .conflictAttention(
                message: "Project progress changed while these changes were being added. The workspace is unchanged and needs attention.",
                details: []
            )
            return
        } catch EngineError.nothingToLand {
            closeWorkspace?.phase = .noChanges
            return
        } catch let error as EngineError {
            closeWorkspace?.phase = .failure(message: error.message)
            return
        } catch {
            closeWorkspace?.phase = .failure(message: "\(error)")
            return
        }

        tearDownClosedWorkspace(workspace)

        let reconciled = await reconcileProjectWorkspace(workspace.projectPath)
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
        do {
            _ = try await engine.rebaseOntoTrunk(projectPath: projectPath)
            projectWorkingCopyAttention.remove(projectPath)
            return true
        } catch {
            projectWorkingCopyAttention.insert(projectPath)
            return false
        }
    }

    /// Closes without adding. A workspace known to have changes reaches this
    /// operation only through the in-sheet destructive confirmation; the
    /// no-changes state closes directly without an unnecessary second prompt.
    /// Session teardown intentionally precedes the engine call, preserving the
    /// existing forget-operation ordering.
    func closeWithoutAddingWorkspace() async {
        guard let presentation = closeWorkspace,
              let workspace = workspaces.first(where: { $0.id == presentation.workspaceID })
        else { return }
        switch presentation.phase {
        case .noChanges, .confirmCloseWithoutAdding:
            break
        default:
            return
        }

        closeWorkspace?.phase = .applying(.closing)
        tearDownWorkspaceSessions(workspace)

        do {
            try await engine.deleteWorkspace(workspace)
            workspaces.removeAll { $0.id == workspace.id }
            save()
            closeWorkspace?.phase = .success(addedChanges: 0, notice: nil)
        } catch let error as EngineError {
            closeWorkspace?.phase = .failure(message: error.message)
            save()
        } catch {
            closeWorkspace?.phase = .failure(message: "\(error)")
            save()
        }
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

    /// The single funnel for every attention signal, from every source —
    /// nothing else in the app may write `attention`. Ignores ids with no
    /// matching row in `sessions` — a signal racing that session's own
    /// teardown is a normal, harmless race, not an error to surface.
    /// Deliberately never calls `save()`: this state is not persisted (see
    /// `attention`'s doc comment).
    func apply(_ signal: AttentionSignal, to sessionID: String) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        attention[sessionID] = SessionAttention.reduce(attention[sessionID] ?? .init(), signal)
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
        if let previous = attendedSessionID {
            apply(.attentionChanged(isAttended: false), to: previous)
        }
        attendedSessionID = next
        if let next {
            apply(.attentionChanged(isAttended: true), to: next)
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
    func setSessionTitle(_ title: String, for sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var changed = false
        if sessions[index].agentTitle != trimmed {
            sessions[index].agentTitle = trimmed
            changed = true
        }
        if var resume = sessions[index].resume,
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
    func handleAgentSessionEvent(_ event: AgentSessionEvent, for sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }

        let rawTitle = sessions[index].agentTitle
        let currentDecoratedTitle = rawTitle.flatMap {
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
        } else {
            next = SessionResumeMetadata(
                agent: event.agent,
                sessionID: event.sessionID,
                title: currentDecoratedTitle,
                prompt: event.query
            )
        }

        guard sessions[index].resume != next else { return }
        sessions[index].resume = next
        save()
    }

    /// Drops live-only attention after session rows are removed.
    private func pruneLiveSessionState() {
        let liveIDs = Set(sessions.map(\.id))
        attention = attention.filter { liveIDs.contains($0.key) }
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
