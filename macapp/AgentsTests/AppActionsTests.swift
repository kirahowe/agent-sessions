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

    func test01b_newSessionTrueAndCreatesSessionWithOneProject() {
        let (store, _, _) = TestSupport.makeStore()
        let actions = AppActions(store: store, uiState: UIState(), dialogs: FakeDialogs())
        store.addProject(path: "/tmp/proj-A")
        let countBefore = store.sessions.count

        XCTAssertTrue(actions.perform(.newSession))

        XCTAssertEqual(store.sessions.count, countBefore + 1)
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
}
