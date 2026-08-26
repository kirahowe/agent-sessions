import AppKit
import XCTest
@testable import Agents

/// Polls a synchronous condition via bounded `Task.yield()`s rather than a
/// fixed sleep. `AppActions.perform`'s `.newWorkspace`/`.deleteWorkspace`/
/// `.keepWorkspaceChanges` cases each fire a `Task { await store.xxx(...) }`
/// internally and return `true` synchronously before that Task necessarily
/// runs, so asserting on a fake engine's recorded calls needs to wait for it
/// deterministically rather than assuming it already ran.
private func waitUntil(_ condition: () -> Bool, iterations: Int = 50) async {
    for _ in 0..<iterations {
        if condition() { return }
        await Task.yield()
    }
}

/// Builds AppActions with a synchronous `present` so tests can assert
/// dialog interactions immediately after `perform` returns. The production
/// default defers presentation by a runloop turn (see AppActions.present);
/// test coverage for that deferral is test11 below.
///
/// Deviation from spec: `UIState()`/`FakeDialogs()` can't sit directly in
/// default-parameter position here — a default-value expression is
/// evaluated in a nonisolated context even when the function itself is
/// `@MainActor`, and both inits are main-actor-isolated. Defaulting to
/// `nil` and constructing inside the isolated body sidesteps that while
/// keeping every call site identical (`makeActions(store:)`,
/// `makeActions(store:dialogs:)`, `makeActions(store:uiState:)`).
///
/// `currentEvent` defaults to `{ nil }` — no originating event — so every
/// existing test dispatches on every `perform`, unaffected by the keystroke
/// dedup that section 12 exercises.
@MainActor
private func makeActions(
    store: AppStore,
    uiState: UIState? = nil,
    dialogs: FakeDialogs? = nil,
    currentEvent: @escaping () -> NSEvent? = { nil }
) -> AppActions {
    AppActions(
        store: store,
        uiState: uiState ?? UIState(),
        dialogs: dialogs ?? FakeDialogs(),
        present: { $0() },
        currentEvent: currentEvent
    )
}

/// A ⇧⌘R keydown with a caller-chosen timestamp. `AppActions` keys its
/// dedup on `(action, event.timestamp)`, so the timestamp is the only field
/// these tests actually vary; the rest just make a well-formed event.
private func keyDownEvent(timestamp: TimeInterval) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
        timestamp: timestamp, windowNumber: 0, context: nil,
        characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15
    )!
}

/// Each numbered section exercises one `AppAction` case of
/// `AppActions.perform(_:)`. All store state is built through `AppStore`'s
/// real public API (never by poking `store.projects`/`store.sessions`
/// directly), with a fresh `TestSupport.makeStore()` and a `FakeDialogs` in
/// place of the real AppKit modal loop. `.closeWindow` is deliberately not
/// covered — it depends on `NSApp.keyWindow`, unreliable in the test host.
@MainActor
final class AppActionsTests: XCTestCase {

    // MARK: - 1: .newSession

    func test01a_newSessionFalseWithZeroProjects() {
        let (store, _, _) = TestSupport.makeStore()
        let actions = makeActions(store: store)

        XCTAssertFalse(actions.perform(.newSession))
    }

    func test01b_newSessionTrueAndCreatesAutoNamedSessionAndSelectsIt() {
        let (store, _, _) = TestSupport.makeStore()
        let actions = makeActions(store: store)
        store.addProject(path: "/tmp/proj-A") // "Session 1"
        let countBefore = store.sessions.count

        XCTAssertTrue(actions.perform(.newSession))

        XCTAssertEqual(store.sessions.count, countBefore + 1)
        XCTAssertEqual(store.sessions.first { $0.id == store.selection }?.name, "Session 2")
    }

    // No dialog involved any more — .newSession always calls
    // store.newSession(in: nil) directly, so repeated performs should
    // exercise AppStore's own numbering exactly like repeated direct calls
    // would, with nothing in AppActions' routing able to disturb it.
    func test01c_newSessionTwiceAutoNumbersSequentially() {
        let (store, _, _) = TestSupport.makeStore()
        let actions = makeActions(store: store)
        store.addProject(path: "/tmp/proj-A") // "Session 1"

        XCTAssertTrue(actions.perform(.newSession))
        XCTAssertEqual(store.sessions.first { $0.id == store.selection }?.name, "Session 2")

        XCTAssertTrue(actions.perform(.newSession))
        XCTAssertEqual(store.sessions.first { $0.id == store.selection }?.name, "Session 3")
    }

    // MARK: - 2: .closeSession

    func test02a_closeSessionFalseWithNoSelection() {
        let (store, _, _) = TestSupport.makeStore()
        let actions = makeActions(store: store)
        store.selection = nil

        XCTAssertFalse(actions.perform(.closeSession))
    }

    func test02b_closeSessionTrueAndClosesSelectedSession() {
        let (store, spy, _) = TestSupport.makeStore()
        let actions = makeActions(store: store)
        store.addProject(path: "/tmp/proj-A")
        let sessionID = store.selection!

        XCTAssertTrue(actions.perform(.closeSession))

        XCTAssertEqual(spy.closedIDs, [sessionID])
        XCTAssertFalse(store.sessions.contains { $0.id == sessionID })
    }

    // MARK: - 3: .addProject

    func test03a_addProjectCancelReturnsTrueWithoutAddingProject() {
        let (store, _, _) = TestSupport.makeStore()
        let dialogs = FakeDialogs()
        dialogs.nextProjectDirectory = nil
        let actions = makeActions(store: store, dialogs: dialogs)

        XCTAssertTrue(actions.perform(.addProject), "cancel still counts as handled")
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertEqual(dialogs.chooseProjectDirectoryCallCount, 1)
    }

    func test03b_addProjectConfirmAddsProjectWithFirstSession() {
        let (store, _, _) = TestSupport.makeStore()
        let dialogs = FakeDialogs()
        dialogs.nextProjectDirectory = "/tmp/proj-A"
        let actions = makeActions(store: store, dialogs: dialogs)

        XCTAssertTrue(actions.perform(.addProject))

        XCTAssertEqual(store.projects.map(\.path), ["/tmp/proj-A"])
        let sessions = store.sessions.filter { $0.projectPath == "/tmp/proj-A" }
        XCTAssertEqual(sessions.count, 1)
    }

    // MARK: - 4: .removeProject

    func test04a_removeProjectFalseWhenAmbiguous() {
        let (store, _, _) = TestSupport.makeStore()
        let dialogs = FakeDialogs()
        let actions = makeActions(store: store, dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")
        store.addProject(path: "/tmp/proj-B")
        // addProject auto-selects the newest project's session; explicitly
        // clear it to get the "no selection, 2+ projects" ambiguous case.
        store.selection = nil

        XCTAssertFalse(actions.perform(.removeProject))
        XCTAssertTrue(dialogs.confirmRemoveCalls.isEmpty)
    }

    func test04b_removeProjectCancelReturnsTrueButProjectRemains() {
        let (store, _, _) = TestSupport.makeStore()
        let dialogs = FakeDialogs()
        dialogs.nextConfirmRemove = false
        let actions = makeActions(store: store, dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A") // single project -> resolveProject's fallback branch
        let project = store.projects.first!

        XCTAssertTrue(actions.perform(.removeProject), "cancel still counts as handled")

        XCTAssertTrue(store.projects.contains { $0.path == project.path })
        XCTAssertEqual(dialogs.confirmRemoveCalls, [project])
    }

    func test04c_removeProjectConfirmRemovesProject() {
        let (store, _, _) = TestSupport.makeStore()
        let dialogs = FakeDialogs()
        dialogs.nextConfirmRemove = true
        let actions = makeActions(store: store, dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")
        let project = store.projects.first!

        XCTAssertTrue(actions.perform(.removeProject))

        XCTAssertFalse(store.projects.contains { $0.path == project.path })
        XCTAssertEqual(dialogs.confirmRemoveCalls, [project])
    }

    // MARK: - 5: .newWorkspace

    func test05a_newWorkspacePassesOpenProjectsAndSelectedProjectAsDefault() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let dialogs = FakeDialogs()
        let actions = makeActions(store: store, dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")
        store.addProject(path: "/tmp/proj-B") // selection now belongs to B
        dialogs.nextNewWorkspaceResult = NewWorkspacePromptResult(
            projectPath: "/tmp/proj-B",
            label: ""
        )

        XCTAssertTrue(actions.perform(.newWorkspace))

        XCTAssertEqual(dialogs.promptNewWorkspaceCalls.count, 1)
        XCTAssertEqual(dialogs.promptNewWorkspaceCalls[0].projects, store.projects)
        XCTAssertEqual(dialogs.promptNewWorkspaceCalls[0].defaultProject?.path, "/tmp/proj-B")
        await waitUntil { !fake.createCalls.isEmpty }
        XCTAssertEqual(fake.createCalls, ["/tmp/proj-B"])
    }

    func test05b_newWorkspaceUsesPromptProjectInsteadOfSelectedDefault() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let dialogs = FakeDialogs()
        let actions = makeActions(store: store, dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")
        store.addProject(path: "/tmp/proj-B") // selection now belongs to B
        dialogs.nextNewWorkspaceResult = NewWorkspacePromptResult(
            projectPath: "/tmp/proj-A",
            label: ""
        )

        XCTAssertTrue(actions.perform(.newWorkspace))

        XCTAssertEqual(dialogs.promptNewWorkspaceCalls[0].defaultProject?.path, "/tmp/proj-B")
        await waitUntil { !fake.createCalls.isEmpty }
        XCTAssertEqual(fake.createCalls, ["/tmp/proj-A"])
    }

    func test05c_newWorkspaceWithNoSelectionOffersAllProjectsWithoutADefault() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let dialogs = FakeDialogs()
        let actions = makeActions(store: store, dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")
        store.addProject(path: "/tmp/proj-B")
        store.selection = nil
        dialogs.nextNewWorkspaceResult = NewWorkspacePromptResult(
            projectPath: "/tmp/proj-A",
            label: ""
        )

        XCTAssertTrue(actions.perform(.newWorkspace))

        XCTAssertEqual(dialogs.promptNewWorkspaceCalls.count, 1)
        XCTAssertEqual(dialogs.promptNewWorkspaceCalls[0].projects, store.projects)
        XCTAssertNil(dialogs.promptNewWorkspaceCalls[0].defaultProject)
        await waitUntil { !fake.createCalls.isEmpty }
        XCTAssertEqual(fake.createCalls, ["/tmp/proj-A"])
    }

    func test05d_newWorkspaceFalseOnlyWhenNoProjectsAreOpen() {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let dialogs = FakeDialogs()
        let actions = makeActions(store: store, dialogs: dialogs)

        XCTAssertFalse(actions.perform(.newWorkspace))
        XCTAssertTrue(dialogs.promptNewWorkspaceCalls.isEmpty)
        XCTAssertTrue(fake.createCalls.isEmpty)
    }

    func test05e_newWorkspaceCancelReturnsTrueButCreatesNoWorkspace() {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let dialogs = FakeDialogs()
        dialogs.nextNewWorkspaceResult = nil
        let actions = makeActions(store: store, dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")

        XCTAssertTrue(actions.perform(.newWorkspace), "cancel still counts as handled")

        XCTAssertEqual(dialogs.promptNewWorkspaceCalls.count, 1)
        XCTAssertEqual(dialogs.promptNewWorkspaceCalls[0].projects, store.projects)
        XCTAssertEqual(dialogs.promptNewWorkspaceCalls[0].defaultProject?.path, "/tmp/proj-A")
        // A cancelled dialog never schedules the creation task.
        XCTAssertTrue(fake.createCalls.isEmpty)
    }

    func test05f_newWorkspacePreservesPromptLabelForCreation() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let dialogs = FakeDialogs()
        dialogs.nextNewWorkspaceResult = NewWorkspacePromptResult(
            projectPath: "/tmp/proj-A",
            label: "my label"
        )
        let actions = makeActions(store: store, dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")
        let wsRow = WorkspaceRow(
            projectPath: "/tmp/proj-A",
            name: "calm-river",
            path: "/tmp/workspaces/calm-river",
            label: nil
        )
        fake.nextCreateResult = .success(wsRow)

        XCTAssertTrue(actions.perform(.newWorkspace))

        await waitUntil { !store.workspaces.isEmpty }
        XCTAssertEqual(store.workspaces.first?.label, "my label")
    }

    // MARK: - 6: .deleteWorkspace

    func test06a_deleteWorkspaceFalseWhenSelectionIsNotAWorkspaceSession() {
        let (store, _, _) = TestSupport.makeStore()
        let actions = makeActions(store: store)

        store.selection = nil
        XCTAssertFalse(actions.perform(.deleteWorkspace))

        store.addProject(path: "/tmp/proj-A") // selects a root-targeted session, not a workspace
        XCTAssertFalse(actions.perform(.deleteWorkspace))
    }

    func test06b_deleteWorkspaceCancelReturnsTrueWithoutCallingEngine() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let dialogs = FakeDialogs()
        dialogs.nextConfirmDeleteWorkspace = false
        let actions = makeActions(store: store, dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")
        let wsRow = WorkspaceRow(projectPath: "/tmp/proj-A", name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: "/tmp/proj-A") // also selects the new workspace session

        XCTAssertTrue(actions.perform(.deleteWorkspace), "cancel still counts as handled")

        // A cancelled dialog never even schedules the Task, so this is safe
        // to assert synchronously without the polling helper.
        XCTAssertTrue(fake.deleteCalls.isEmpty)
        XCTAssertEqual(dialogs.confirmDeleteWorkspaceCalls, [wsRow])
    }

    func test06c_deleteWorkspaceConfirmCallsEngineDelete() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let dialogs = FakeDialogs()
        dialogs.nextConfirmDeleteWorkspace = true
        let actions = makeActions(store: store, dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")
        let wsRow = WorkspaceRow(projectPath: "/tmp/proj-A", name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: "/tmp/proj-A")

        XCTAssertTrue(actions.perform(.deleteWorkspace))

        await waitUntil { !fake.deleteCalls.isEmpty }
        XCTAssertEqual(fake.deleteCalls, [wsRow])
    }

    // MARK: - 7: .keepWorkspaceChanges

    func test07a_keepWorkspaceChangesFalseWhenSelectionIsNotAWorkspaceSession() {
        let (store, _, _) = TestSupport.makeStore()
        let actions = makeActions(store: store)

        store.selection = nil
        XCTAssertFalse(actions.perform(.keepWorkspaceChanges))

        store.addProject(path: "/tmp/proj-A") // selects a root-targeted session, not a workspace
        XCTAssertFalse(actions.perform(.keepWorkspaceChanges))
    }

    // `.keepWorkspaceChanges` no longer presents a dialog synchronously at
    // all — it resolves the workspace, starts a Task running
    // AppStore.reviewAndLandWorkspace (preview -> confirmLand -> land), and
    // returns true immediately regardless of what that Task eventually
    // decides. So "cancel still counts as handled" now means something
    // slightly different than it does for the other cases above: `perform`
    // returns true before the preview has even started, not just before the
    // user has answered a dialog. These tests poll for the eventual dialog/
    // engine call instead of asserting on it synchronously.
    func test07b_keepWorkspaceChangesCancelReturnsTrueWithoutCallingEngine() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let dialogs = FakeDialogs()
        dialogs.nextLandDecision = .cancel
        let actions = makeActions(store: store, dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")
        let wsRow = WorkspaceRow(projectPath: "/tmp/proj-A", name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: "/tmp/proj-A")

        XCTAssertTrue(actions.perform(.keepWorkspaceChanges), "cancel still counts as handled")

        await waitUntil { !dialogs.confirmLandCalls.isEmpty }
        XCTAssertTrue(fake.landCalls.isEmpty)
        XCTAssertEqual(dialogs.confirmLandCalls.first?.workspace, wsRow)
    }

    func test07c_keepWorkspaceChangesConfirmCallsEngineLand() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let dialogs = FakeDialogs()
        dialogs.nextLandDecision = .land(message: "Ship it")
        let actions = makeActions(store: store, dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")
        let wsRow = WorkspaceRow(projectPath: "/tmp/proj-A", name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: "/tmp/proj-A")
        fake.nextLandResult = .success(LandResult(commitID: "abc123", bookmark: "main"))

        XCTAssertTrue(actions.perform(.keepWorkspaceChanges))

        await waitUntil { !fake.landCalls.isEmpty }
        XCTAssertEqual(fake.landCalls.first?.workspace, wsRow)
        XCTAssertEqual(fake.landCalls.first?.message, "Ship it")
    }

    // The bug that motivated replacing `promptLandMessage`'s `String?` with
    // `LandDecision`: confirming with a blank/absent message must still
    // land, not silently no-op. `.land(message: nil)` is exactly what
    // `Dialogs.confirmLand` now returns for "confirmed, field left blank"
    // (see LandDecision's doc comment in DialogPresenting.swift) — this
    // pins that AppStore actually calls through to the engine for it,
    // passing an empty string rather than treating nil as cancel.
    func test07d_keepWorkspaceChangesConfirmWithNilMessageStillLands() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let dialogs = FakeDialogs()
        dialogs.nextLandDecision = .land(message: nil)
        let actions = makeActions(store: store, dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")
        let wsRow = WorkspaceRow(projectPath: "/tmp/proj-A", name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: "/tmp/proj-A")
        fake.nextLandResult = .success(LandResult(commitID: "abc123", bookmark: "main"))

        XCTAssertTrue(actions.perform(.keepWorkspaceChanges))

        await waitUntil { !fake.landCalls.isEmpty }
        XCTAssertEqual(fake.landCalls.first?.workspace, wsRow, "the land must actually go through the engine, not silently no-op")
        // "No message" must reach the engine AS nil, so the CLI invocation
        // omits --message entirely. Asserting "" here would be asserting the
        // very bug this rewrite fixed: agents-cli rejects a blank flag value
        // as a missing required flag, so an empty string would fail the land
        // outright against the real CLI while passing against this fake.
        XCTAssertNil(fake.landCalls.first?.message, "a nil LandDecision message stays nil — never coerced to a blank flag value")
    }

    // MARK: - 8: .selectSession

    func test08a_selectSessionValidIndexSelectsAndReturnsTrue() {
        let (store, _, _) = TestSupport.makeStore()
        let actions = makeActions(store: store)
        store.addProject(path: "/tmp/proj-A")
        store.addProject(path: "/tmp/proj-B")
        let ordered = store.orderedSessions

        XCTAssertTrue(actions.perform(.selectSession(1)))
        XCTAssertEqual(store.selection, ordered[1].id)
    }

    func test08b_selectSessionOutOfRangeReturnsFalse() {
        let (store, _, _) = TestSupport.makeStore()
        let actions = makeActions(store: store)
        store.addProject(path: "/tmp/proj-A")

        XCTAssertFalse(actions.perform(.selectSession(5)))
    }

    // MARK: - 9: .showShortcutHelp

    func test09_showShortcutHelpTogglesBothDirections() {
        let (store, _, _) = TestSupport.makeStore()
        let uiState = UIState()
        let actions = makeActions(store: store, uiState: uiState)
        XCTAssertFalse(uiState.showShortcutHelp)

        XCTAssertTrue(actions.perform(.showShortcutHelp))
        XCTAssertTrue(uiState.showShortcutHelp)

        XCTAssertTrue(actions.perform(.showShortcutHelp))
        XCTAssertFalse(uiState.showShortcutHelp)
    }

    // MARK: - 10: .renameSession

    func test10a_renameSessionFalseWithNoSelection() {
        let (store, _, _) = TestSupport.makeStore()
        let dialogs = FakeDialogs()
        let actions = makeActions(store: store, dialogs: dialogs)

        XCTAssertFalse(actions.perform(.renameSession))
        XCTAssertTrue(dialogs.promptRenameCalls.isEmpty)
    }

    func test10b_renameSessionCancelReturnsTrueButNameUnchanged() {
        let (store, _, _) = TestSupport.makeStore()
        let dialogs = FakeDialogs()
        dialogs.nextRenameName = nil
        let actions = makeActions(store: store, dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!

        XCTAssertTrue(actions.perform(.renameSession), "cancel still counts as handled")

        XCTAssertEqual(dialogs.promptRenameCalls, [session.name])
        XCTAssertEqual(store.sessions.first?.name, session.name)
    }

    func test10c_renameSessionConfirmRenamesSelectedSession() {
        let (store, _, _) = TestSupport.makeStore()
        let dialogs = FakeDialogs()
        dialogs.nextRenameName = "renamed"
        let actions = makeActions(store: store, dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")
        let sessionID = store.selection!

        XCTAssertTrue(actions.perform(.renameSession))

        // A rename writes `customName`, so the observable result is the
        // display name — `name` stays the "Session N" counter seed.
        XCTAssertEqual(store.sessions.first { $0.id == sessionID }?.displayName, "renamed")
    }

    // MARK: - 11: dialog presentation is deferred (the double-Escape bug)

    // Pins down the fix itself, using AppActions' real default `present`
    // (DispatchQueue.main.async) instead of the synchronous one makeActions
    // injects everywhere else. If perform ever went back to presenting the
    // dialog inline — the bug that made Escape reopen the rename alert,
    // because the modal loop ran while the triggering keydown's dispatch was
    // still suspended in the ShortcutRouter monitor callback — the first
    // assertion here would fail the moment promptRename was called too
    // early.
    func test11_renameSessionDefersDialogPresentationByOneRunloopTurn() async {
        let (store, _, _) = TestSupport.makeStore()
        let dialogs = FakeDialogs()
        dialogs.nextRenameName = nil
        let actions = AppActions(store: store, uiState: UIState(), dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!

        XCTAssertTrue(actions.perform(.renameSession))
        XCTAssertTrue(dialogs.promptRenameCalls.isEmpty, "dialog must not be presented synchronously inside perform")

        // Drains the main queue: FIFO ordering guarantees the deferred
        // dialog block, enqueued during perform above, runs before this
        // continuation's block does.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { c.resume() }
        }

        XCTAssertEqual(dialogs.promptRenameCalls, [session.name])
    }

    // MARK: - 12: one keystroke performs an action once (the double-dialog bug)

    // The regression test for the reported bug. One ⇧⌘R press reaches
    // AppActions twice — once from ShortcutRouter's local NSEvent monitor,
    // once from the menu item's own key equivalent, which .keymapShortcut
    // attaches and which the monitor's nil return does not actually
    // suppress. Both calls arrive inside the same sendEvent:, so both see
    // the same NSApp.currentEvent, modelled here by a fixed keydown. Before
    // the fix that queued two rename alerts, and dismissing the dialog
    // appeared to need two Escapes.
    func test12a_sameKeystrokeDispatchedTwicePerformsOnce() {
        let (store, _, _) = TestSupport.makeStore()
        let dialogs = FakeDialogs()
        dialogs.nextRenameName = nil
        let event = keyDownEvent(timestamp: 1000)
        let actions = makeActions(store: store, dialogs: dialogs, currentEvent: { event })
        store.addProject(path: "/tmp/proj-A")

        XCTAssertTrue(actions.perform(.renameSession))
        XCTAssertTrue(actions.perform(.renameSession), "the duplicate still reports handled — it must not fall through to a beep")

        XCTAssertEqual(dialogs.promptRenameCalls.count, 1)
    }

    // The guard keys on the individual keystroke, not on the action, so it
    // can't wedge an action permanently after its first use — and holding
    // ⇧⌘R to auto-repeat still opens a dialog per repeat.
    func test12b_distinctKeystrokesEachPerform() {
        let (store, _, _) = TestSupport.makeStore()
        let dialogs = FakeDialogs()
        dialogs.nextRenameName = nil
        var event = keyDownEvent(timestamp: 1000)
        let actions = makeActions(store: store, dialogs: dialogs, currentEvent: { event })
        store.addProject(path: "/tmp/proj-A")

        XCTAssertTrue(actions.perform(.renameSession))
        event = keyDownEvent(timestamp: 2000)
        XCTAssertTrue(actions.perform(.renameSession))

        XCTAssertEqual(dialogs.promptRenameCalls.count, 2)
    }

    // Only a dispatch that actually handled the action is recorded. A first
    // attempt that returned false (⇧⌘R with nothing selected) must not
    // consume the keystroke and block a second attempt on the same event —
    // which is exactly the ordering when the router's dispatch declines and
    // the menu's key equivalent then finds valid state.
    func test12c_unhandledDispatchIsNotRecorded() {
        let (store, _, _) = TestSupport.makeStore()
        let dialogs = FakeDialogs()
        dialogs.nextRenameName = nil
        let event = keyDownEvent(timestamp: 1000)
        let actions = makeActions(store: store, dialogs: dialogs, currentEvent: { event })

        XCTAssertFalse(actions.perform(.renameSession), "no selection — nothing to rename")
        XCTAssertTrue(dialogs.promptRenameCalls.isEmpty)

        store.addProject(path: "/tmp/proj-A") // now there is a selection
        let session = store.sessions.first!

        XCTAssertTrue(actions.perform(.renameSession))
        XCTAssertEqual(dialogs.promptRenameCalls, [session.name])
    }

    // Menu items chosen with the mouse carry a non-keyDown current event,
    // so nothing is deduplicated: picking Rename Session… from the menu
    // twice must present the dialog twice.
    func test12d_nonKeyDownCurrentEventNeverDedups() {
        let (store, _, _) = TestSupport.makeStore()
        let dialogs = FakeDialogs()
        dialogs.nextRenameName = nil
        let click = NSEvent.mouseEvent(
            with: .leftMouseUp, location: .zero, modifierFlags: [],
            timestamp: 1000, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )!
        let actions = makeActions(store: store, dialogs: dialogs, currentEvent: { click })
        store.addProject(path: "/tmp/proj-A")

        XCTAssertTrue(actions.perform(.renameSession))
        XCTAssertTrue(actions.perform(.renameSession))

        XCTAssertEqual(dialogs.promptRenameCalls.count, 2)
    }
}
