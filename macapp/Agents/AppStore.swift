import Combine
import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published var projects: [Project] = []
    @Published var sessions: [SessionRow] = []
    @Published var workspaces: [WorkspaceRow] = []
    @Published var selection: String?
    @Published var lastError: String?
    /// Set (instead of `lastError`) when `landWorkspace` fails with
    /// `.noTrunk` — that error is recoverable by creating the trunk bookmark
    /// and retrying, so the UI needs to offer that instead of just showing a
    /// dead-end error message. Carries the original workspace id + message
    /// so the retry doesn't require the user to retype anything.
    @Published var pendingTrunkBootstrap: (workspaceID: String, message: String)?
    /// What each live session's agent is currently doing, as reported by
    /// Claude Code hooks via desktop-notification OSC sequences (see
    /// `SessionActivity`). Deliberately NOT part of `PersistedState`/
    /// `save()`/`load()`: this describes a live process's current state,
    /// which has no meaningful value to restore after a relaunch — see
    /// `SessionActivity`'s doc comment.
    @Published private(set) var sessionActivity: [String: SessionActivity] = [:]

    /// Count of sessions currently `.blocked` — agents actively burning the
    /// user's time waiting on a permission prompt, as opposed to `.yourTurn`
    /// sessions, which can sit idle indefinitely with no cost to anyone.
    /// Drives the Dock tile badge (see `dockBadgeLabel(blockedCount:)` below
    /// and its application in RootView.swift) — `.yourTurn` is deliberately
    /// excluded from the count for that same reason, so the badge only ever
    /// screams about the state that's actually costing the user something by
    /// going unnoticed.
    var blockedSessionCount: Int {
        sessionActivity.values.filter { $0 == .blocked }.count
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
        terminals.onSessionActivity = { [weak self] id, activity in
            self?.setSessionActivity(activity, for: id)
        }
        terminals.onTitleChange = { [weak self] id, title in
            self?.setSessionTitle(title, for: id)
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
        // Local bookkeeping only: removing a project from the app must never
        // destroy the user's on-disk jj workspaces, so we drop our local
        // WorkspaceRow records without ever calling engine.deleteWorkspace.
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
            // newSession already calls save() at the end, so no extra save()
            // call needed here.
        } catch let error as EngineError {
            lastError = error.message
        } catch {
            lastError = "\(error)"
        }
    }

    func deleteWorkspace(_ id: WorkspaceRow.ID) async {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
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

        do {
            try await engine.deleteWorkspace(workspace)
            workspaces.removeAll { $0.id == id }
        } catch let error as EngineError {
            // The terminals/session rows are already torn down above; restoring
            // them would just desync the app from reality. Leave the
            // WorkspaceRow in place instead, as a visible "retry me" marker.
            lastError = error.message
        } catch {
            lastError = "\(error)"
        }
        save()
    }

    /// Lands (squashes onto trunk and advances the bookmark for) a
    /// workspace's changes, then tears down its sessions and removes it.
    /// Returns whether it actually landed.
    ///
    /// ORDER MATTERS here, and is the INVERSE of `deleteWorkspace` above:
    /// the engine call happens FIRST, and local teardown (sessions, rows,
    /// selection) only happens on success. `deleteWorkspace` can safely tear
    /// sessions down before calling the engine because forgetting a
    /// workspace isn't expected to be meaningfully "rejected" — any engine
    /// failure there just leaves the row as a retry marker regardless. But
    /// `land-conflict` is a first-class, EXPECTED outcome here (e.g. trunk
    /// moved since the workspace was created) that leaves the workspace
    /// fully intact on purpose, specifically so the user keeps working in
    /// it. Tearing sessions down before knowing whether the land succeeded
    /// would kill a live terminal for a change that was never actually
    /// landed — so nothing local changes until the engine confirms success.
    @discardableResult
    func landWorkspace(_ id: WorkspaceRow.ID, message: String, createTrunk: String? = nil) async -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return false }

        let result: LandResult
        do {
            result = try await engine.landWorkspace(workspace, message: message, createTrunk: createTrunk)
        } catch EngineError.noTrunk {
            // Not surfaced via lastError: the UI offers to create the trunk
            // bookmark and retry, so this isn't a dead-end the user just
            // dismisses.
            pendingTrunkBootstrap = (workspaceID: id, message: message)
            return false
        } catch let error as EngineError {
            lastError = error.message
            return false
        } catch {
            lastError = "\(error)"
            return false
        }

        let target = TargetRef.workspace(projectPath: workspace.projectPath, name: workspace.name)
        let removedIDs = sessions.filter { $0.target == target }.map(\.id)
        for sessionID in removedIDs {
            terminals.closeSession(sessionID)
        }
        sessions.removeAll { $0.target == target }
        pruneLiveSessionState()
        workspaces.removeAll { $0.id == id }
        if let selection, removedIDs.contains(selection) {
            self.selection = nil
        }
        save()

        // The land itself already succeeded by this point (sessions/rows
        // torn down above) — a cleanupWarning is a non-fatal notice about
        // the leftover directory, not a failure of the land, but it still
        // needs to reach the user. Deliberately rides the existing
        // lastError alert UI (RootView.swift's "Workspace Error" alert is
        // already bound to store.lastError) rather than adding new UI for
        // what's a rare, low-stakes cosmetic case.
        if let cleanupWarning = result.cleanupWarning {
            lastError = cleanupWarning
        }
        return true
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

    /// Sets (or, when `activity` is nil, clears) a session's activity
    /// indicator. Ignores ids with no matching row in `sessions` — a status
    /// update racing that session's own teardown is a normal, harmless
    /// race, not an error to surface. Deliberately never calls `save()`:
    /// this state is not persisted (see `sessionActivity`'s doc comment).
    func setSessionActivity(_ activity: SessionActivity?, for sessionID: String) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        if let activity {
            sessionActivity[sessionID] = activity
        } else {
            sessionActivity.removeValue(forKey: sessionID)
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
        guard !trimmed.isEmpty, sessions[index].agentTitle != trimmed else { return }
        sessions[index].agentTitle = trimmed
        save()
    }

    /// Drops any per-live-session state (`sessionActivity`) whose session no
    /// longer exists. Called from every site that removes rows from
    /// `sessions` (`closeSession`, `removeProject`, `deleteWorkspace`,
    /// `landWorkspace`) so it can never outlive the session it describes. One
    /// shared helper instead of duplicating this removal logic at each call
    /// site. (The agent title needs no pruning here — it lives on the
    /// `SessionRow` itself, so removing the row removes it.)
    private func pruneLiveSessionState() {
        let liveIDs = Set(sessions.map(\.id))
        sessionActivity = sessionActivity.filter { liveIDs.contains($0.key) }
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
