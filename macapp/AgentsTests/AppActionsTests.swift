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
        let actions = AppActions(store: store, uiState: UIState(), dialogs: FakeDialogs())

        XCTAssertFalse(actions.perform(.newSession))
    }

    func test01b_newSessionTrueAndCreatesAutoNamedSessionAndSelectsIt() {
        let (store, _, _) = TestSupport.makeStore()
        let actions = AppActions(store: store, uiState: UIState(), dialogs: FakeDialogs())
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
        let actions = AppActions(store: store, uiState: UIState(), dialogs: FakeDialogs())
        store.addProject(path: "/tmp/proj-A") // "Session 1"

        XCTAssertTrue(actions.perform(.newSession))
        XCTAssertEqual(store.sessions.first { $0.id == store.selection }?.name, "Session 2")

        XCTAssertTrue(actions.perform(.newSession))
        XCTAssertEqual(store.sessions.first { $0.id == store.selection }?.name, "Session 3")
    }

    // MARK: - 2: .closeSession

    func test02a_closeSessionFalseWithNoSelection() {
        let (store, _, _) = TestSupport.makeStore()
        let actions = AppActions(store: store, uiState: UIState(), dialogs: FakeDialogs())
        store.selection = nil

        XCTAssertFalse(actions.perform(.closeSession))
    }

    func test02b_closeSessionTrueAndClosesSelectedSession() {
        let (store, spy, _) = TestSupport.makeStore()
        let actions = AppActions(store: store, uiState: UIState(), dialogs: FakeDialogs())
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
        let actions = AppActions(store: store, uiState: UIState(), dialogs: dialogs)

        XCTAssertTrue(actions.perform(.addProject), "cancel still counts as handled")
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertEqual(dialogs.chooseProjectDirectoryCallCount, 1)
    }

    func test03b_addProjectConfirmAddsProjectWithFirstSession() {
        let (store, _, _) = TestSupport.makeStore()
        let dialogs = FakeDialogs()
        dialogs.nextProjectDirectory = "/tmp/proj-A"
        let actions = AppActions(store: store, uiState: UIState(), dialogs: dialogs)

        XCTAssertTrue(actions.perform(.addProject))

        XCTAssertEqual(store.projects.map(\.path), ["/tmp/proj-A"])
        let sessions = store.sessions.filter { $0.projectPath == "/tmp/proj-A" }
        XCTAssertEqual(sessions.count, 1)
    }

    // MARK: - 4: .removeProject

    func test04a_removeProjectFalseWhenAmbiguous() {
        let (store, _, _) = TestSupport.makeStore()
        let dialogs = FakeDialogs()
        let actions = AppActions(store: store, uiState: UIState(), dialogs: dialogs)
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
        let actions = AppActions(store: store, uiState: UIState(), dialogs: dialogs)
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
        let actions = AppActions(store: store, uiState: UIState(), dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")
        let project = store.projects.first!

        XCTAssertTrue(actions.perform(.removeProject))

        XCTAssertFalse(store.projects.contains { $0.path == project.path })
        XCTAssertEqual(dialogs.confirmRemoveCalls, [project])
    }

    // MARK: - 5: .newWorkspace (exercises private resolveProject() through perform)

    func test05a_newWorkspaceUsesSelectedSessionsProject() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let actions = AppActions(store: store, uiState: UIState(), dialogs: FakeDialogs())
        store.addProject(path: "/tmp/proj-A")
        store.addProject(path: "/tmp/proj-B") // selection now in B's session

        XCTAssertTrue(actions.perform(.newWorkspace))

        await waitUntil { !fake.createCalls.isEmpty }
        XCTAssertEqual(fake.createCalls, ["/tmp/proj-B"])
    }

    func test05b_newWorkspaceFallsBackToSingleProjectWithNoSelection() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let actions = AppActions(store: store, uiState: UIState(), dialogs: FakeDialogs())
        store.addProject(path: "/tmp/proj-A")
        store.selection = nil

        XCTAssertTrue(actions.perform(.newWorkspace))

        await waitUntil { !fake.createCalls.isEmpty }
        XCTAssertEqual(fake.createCalls, ["/tmp/proj-A"])
    }

    func test05c_newWorkspaceFalseWhenAmbiguous() {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let actions = AppActions(store: store, uiState: UIState(), dialogs: FakeDialogs())
        store.addProject(path: "/tmp/proj-A")
        store.addProject(path: "/tmp/proj-B")
        store.selection = nil

        XCTAssertFalse(actions.perform(.newWorkspace))
        XCTAssertTrue(fake.createCalls.isEmpty)
    }

    func test05d_newWorkspaceCancelReturnsTrueButCreatesNoWorkspace() {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let dialogs = FakeDialogs()
        dialogs.nextNewWorkspaceLabel = nil
        let actions = AppActions(store: store, uiState: UIState(), dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")

        XCTAssertTrue(actions.perform(.newWorkspace), "cancel still counts as handled")

        // A cancelled dialog never even schedules the Task, so this is safe
        // to assert synchronously without the polling helper.
        XCTAssertTrue(fake.createCalls.isEmpty)
    }

    func test05e_newWorkspaceConfirmWithLabelCreatesWorkspaceCarryingThatLabel() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let dialogs = FakeDialogs()
        dialogs.nextNewWorkspaceLabel = "my label"
        let actions = AppActions(store: store, uiState: UIState(), dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")
        let wsRow = WorkspaceRow(projectPath: "/tmp/proj-A", name: "calm-river", path: "/tmp/workspaces/calm-river", label: nil)
        fake.nextCreateResult = .success(wsRow)

        XCTAssertTrue(actions.perform(.newWorkspace))

        // Waits on the store state this test actually asserts, not on the
        // engine call that precedes it: the append happens after the
        // `await engine.createWorkspace`, so a createCalls-based wait would
        // only be safe while the fake happens never to suspend.
        await waitUntil { !store.workspaces.isEmpty }
        XCTAssertEqual(store.workspaces.first?.label, "my label")
    }

    // MARK: - 6: .deleteWorkspace

    func test06a_deleteWorkspaceFalseWhenSelectionIsNotAWorkspaceSession() {
        let (store, _, _) = TestSupport.makeStore()
        let actions = AppActions(store: store, uiState: UIState(), dialogs: FakeDialogs())

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
        let actions = AppActions(store: store, uiState: UIState(), dialogs: dialogs)
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
        let actions = AppActions(store: store, uiState: UIState(), dialogs: dialogs)
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
        let actions = AppActions(store: store, uiState: UIState(), dialogs: FakeDialogs())

        store.selection = nil
        XCTAssertFalse(actions.perform(.keepWorkspaceChanges))

        store.addProject(path: "/tmp/proj-A") // selects a root-targeted session, not a workspace
        XCTAssertFalse(actions.perform(.keepWorkspaceChanges))
    }

    func test07b_keepWorkspaceChangesCancelReturnsTrueWithoutCallingEngine() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let dialogs = FakeDialogs()
        dialogs.nextLandMessage = nil
        let actions = AppActions(store: store, uiState: UIState(), dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")
        let wsRow = WorkspaceRow(projectPath: "/tmp/proj-A", name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: "/tmp/proj-A")

        XCTAssertTrue(actions.perform(.keepWorkspaceChanges), "cancel still counts as handled")

        XCTAssertTrue(fake.landCalls.isEmpty)
        XCTAssertEqual(dialogs.promptLandMessageCalls, [wsRow])
    }

    func test07c_keepWorkspaceChangesConfirmCallsEngineLand() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let dialogs = FakeDialogs()
        dialogs.nextLandMessage = "Ship it"
        let actions = AppActions(store: store, uiState: UIState(), dialogs: dialogs)
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

    // MARK: - 8: .selectSession

    func test08a_selectSessionValidIndexSelectsAndReturnsTrue() {
        let (store, _, _) = TestSupport.makeStore()
        let actions = AppActions(store: store, uiState: UIState(), dialogs: FakeDialogs())
        store.addProject(path: "/tmp/proj-A")
        store.addProject(path: "/tmp/proj-B")
        let ordered = store.orderedSessions

        XCTAssertTrue(actions.perform(.selectSession(1)))
        XCTAssertEqual(store.selection, ordered[1].id)
    }

    func test08b_selectSessionOutOfRangeReturnsFalse() {
        let (store, _, _) = TestSupport.makeStore()
        let actions = AppActions(store: store, uiState: UIState(), dialogs: FakeDialogs())
        store.addProject(path: "/tmp/proj-A")

        XCTAssertFalse(actions.perform(.selectSession(5)))
    }

    // MARK: - 9: .showShortcutHelp

    func test09_showShortcutHelpTogglesBothDirections() {
        let (store, _, _) = TestSupport.makeStore()
        let uiState = UIState()
        let actions = AppActions(store: store, uiState: uiState, dialogs: FakeDialogs())
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
        let actions = AppActions(store: store, uiState: UIState(), dialogs: dialogs)

        XCTAssertFalse(actions.perform(.renameSession))
        XCTAssertTrue(dialogs.promptRenameCalls.isEmpty)
    }

    func test10b_renameSessionCancelReturnsTrueButNameUnchanged() {
        let (store, _, _) = TestSupport.makeStore()
        let dialogs = FakeDialogs()
        dialogs.nextRenameName = nil
        let actions = AppActions(store: store, uiState: UIState(), dialogs: dialogs)
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
        let actions = AppActions(store: store, uiState: UIState(), dialogs: dialogs)
        store.addProject(path: "/tmp/proj-A")
        let sessionID = store.selection!

        XCTAssertTrue(actions.perform(.renameSession))

        XCTAssertEqual(store.sessions.first { $0.id == sessionID }?.name, "renamed")
    }
}
