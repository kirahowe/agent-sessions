import XCTest
@testable import Agents

/// Each numbered comment corresponds to the behavior list in the refactor
/// spec. Every test builds its store state through AppStore's real public
/// API (never by poking `store.projects`/`store.sessions` directly) and uses
/// a fresh temp-file stateURL + fresh SpyTerminals so tests are hermetic and
/// never touch the real app's state.json.
@MainActor
final class AppStoreTests: XCTestCase {

    // MARK: - 1

    func test01_addProjectCreatesProjectAndFirstSession() {
        let (store, _, _) = TestSupport.makeStore()
        let path = "/tmp/proj-A"

        store.addProject(path: path)

        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(store.projects.first?.path, path)
        let sessions = store.sessions.filter { $0.projectPath == path }
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.name, "Session 1")
        XCTAssertEqual(store.selection, sessions.first?.id)
    }

    // MARK: - 2

    func test02_addProjectDedupesByPathButAddsNewSession() {
        let (store, _, _) = TestSupport.makeStore()
        let path = "/tmp/proj-A"

        store.addProject(path: path)
        XCTAssertEqual(store.projects.filter { $0.path == path }.count, 1)
        XCTAssertEqual(store.sessions.filter { $0.projectPath == path }.count, 1)

        store.addProject(path: path)

        XCTAssertEqual(store.projects.filter { $0.path == path }.count, 1, "must not duplicate the project row")
        let sessions = store.sessions.filter { $0.projectPath == path }
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.map(\.name)), Set(["Session 1", "Session 2"]))
        XCTAssertEqual(store.selection, sessions.first(where: { $0.name == "Session 2" })?.id)
    }

    // MARK: - 3

    func test03_sessionNumberingIsPerProjectAndNeverReused() {
        let (store, _, _) = TestSupport.makeStore()
        let pathA = "/tmp/proj-A"
        let pathB = "/tmp/proj-B"

        store.addProject(path: pathA) // "Session 1"
        let projectA = store.projects.first(where: { $0.path == pathA })!
        store.newSession(in: projectA) // "Session 2"

        let second = store.sessions.first(where: { $0.projectPath == pathA && $0.name == "Session 2" })!
        store.closeSession(second.id)

        store.newSession(in: projectA) // must be "Session 3", not a reused "Session 2"
        let namesA = store.sessions.filter { $0.projectPath == pathA }.map(\.name)
        XCTAssertTrue(namesA.contains("Session 3"))
        XCTAssertFalse(namesA.contains("Session 2"))

        // An independent project's counter is untouched by A's activity.
        store.addProject(path: pathB)
        let sessionsB = store.sessions.filter { $0.projectPath == pathB }
        XCTAssertEqual(sessionsB.map(\.name), ["Session 1"])
    }

    // MARK: - 4

    func test04a_newSessionNilTargetsSelectedSessionsProject() {
        let (store, _, _) = TestSupport.makeStore()
        let pathA = "/tmp/proj-A"
        let pathB = "/tmp/proj-B"
        store.addProject(path: pathA)
        store.addProject(path: pathB) // selection now points into B

        let sessionA = store.sessions.first(where: { $0.projectPath == pathA })!
        store.selection = sessionA.id

        store.newSession(in: nil)

        let sessionsA = store.sessions.filter { $0.projectPath == pathA }
        let sessionsB = store.sessions.filter { $0.projectPath == pathB }
        XCTAssertEqual(sessionsA.count, 2)
        XCTAssertEqual(sessionsB.count, 1)
        XCTAssertEqual(store.selection, sessionsA.first(where: { $0.name == "Session 2" })?.id)
    }

    func test04b_newSessionNilTargetsFirstProjectWhenNoSelection() {
        let (store, _, _) = TestSupport.makeStore()
        let pathA = "/tmp/proj-A"
        let pathB = "/tmp/proj-B"
        store.addProject(path: pathA)
        store.addProject(path: pathB)
        store.selection = nil

        store.newSession(in: nil)

        XCTAssertEqual(store.sessions.filter { $0.projectPath == pathA }.count, 2)
        XCTAssertEqual(store.sessions.filter { $0.projectPath == pathB }.count, 1)
    }

    func test04c_newSessionNilIsNoOpWithNoProjects() {
        let (store, _, _) = TestSupport.makeStore()

        store.newSession(in: nil)

        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.selection)
    }

    // MARK: - 5

    func test05_closeSessionRemovesRowNotifiesSpyAndMovesToNextSibling() {
        let (store, spy, _) = TestSupport.makeStore()
        let path = "/tmp/proj-A"
        store.addProject(path: path)
        let project = store.projects.first!
        store.newSession(in: project)
        store.newSession(in: project)

        let sessions = store.sessions.filter { $0.projectPath == path }
        let s2 = sessions.first(where: { $0.name == "Session 2" })!
        let s3 = sessions.first(where: { $0.name == "Session 3" })!
        store.selection = s2.id

        store.closeSession(s2.id)

        XCTAssertFalse(store.sessions.contains { $0.id == s2.id })
        XCTAssertEqual(spy.closedIDs, [s2.id])
        XCTAssertEqual(store.selection, s3.id)
    }

    // MARK: - 6

    func test06_closeSessionFallsBackToPreviousSiblingThenToNil() {
        let (store, _, _) = TestSupport.makeStore()
        let path = "/tmp/proj-A"
        store.addProject(path: path)
        let project = store.projects.first!
        store.newSession(in: project)
        store.newSession(in: project)

        let sessions = store.sessions.filter { $0.projectPath == path }
        let s1 = sessions.first(where: { $0.name == "Session 1" })!
        let s2 = sessions.first(where: { $0.name == "Session 2" })!
        let s3 = sessions.first(where: { $0.name == "Session 3" })!
        XCTAssertEqual(store.selection, s3.id)

        // Last session selected, no next sibling -> falls back to previous.
        store.closeSession(s3.id)
        XCTAssertEqual(store.selection, s2.id)

        store.closeSession(s2.id)
        XCTAssertEqual(store.selection, s1.id)

        // Only/last remaining session in the project -> selection clears.
        store.closeSession(s1.id)
        XCTAssertNil(store.selection)
    }

    // MARK: - 7

    func test07_closeSessionOfNonSelectedSessionLeavesSelectionUntouched() {
        let (store, _, _) = TestSupport.makeStore()
        let path = "/tmp/proj-A"
        store.addProject(path: path)
        let project = store.projects.first!
        store.newSession(in: project)

        let sessions = store.sessions.filter { $0.projectPath == path }
        let s1 = sessions.first(where: { $0.name == "Session 1" })!
        let s2 = sessions.first(where: { $0.name == "Session 2" })!
        store.selection = s1.id

        store.closeSession(s2.id)

        XCTAssertEqual(store.selection, s1.id)
        XCTAssertFalse(store.sessions.contains { $0.id == s2.id })
    }

    // MARK: - 8

    func test08_closeSessionWithUnknownIDIsNoOp() {
        let (store, spy, _) = TestSupport.makeStore()
        let path = "/tmp/proj-A"
        store.addProject(path: path)
        let sessionsBefore = store.sessions
        let selectionBefore = store.selection

        store.closeSession("not-a-real-id")

        XCTAssertEqual(store.sessions, sessionsBefore)
        XCTAssertEqual(store.selection, selectionBefore)
        XCTAssertTrue(spy.closedIDs.isEmpty)
    }

    // MARK: - 9

    func test09a_removeProjectTearsDownAllSessionsAndClearsSelectionWhenInside() {
        let (store, spy, _) = TestSupport.makeStore()
        let path = "/tmp/proj-A"
        store.addProject(path: path)
        store.newSession(in: store.projects.first!)
        let project = store.projects.first(where: { $0.path == path })!
        let sessionIDs = store.sessions.filter { $0.projectPath == path }.map(\.id)
        XCTAssertTrue(sessionIDs.contains(store.selection!))

        store.removeProject(project)

        XCTAssertTrue(store.sessions.filter { $0.projectPath == path }.isEmpty)
        XCTAssertFalse(store.projects.contains { $0.path == path })
        XCTAssertNil(store.selection)
        XCTAssertEqual(spy.closedIDs.count, sessionIDs.count)
        XCTAssertEqual(Set(spy.closedIDs), Set(sessionIDs))
    }

    func test09b_removeProjectLeavesUnrelatedSelectionUntouched() {
        let (store, spy, _) = TestSupport.makeStore()
        let pathA = "/tmp/proj-A"
        let pathB = "/tmp/proj-B"
        store.addProject(path: pathA)
        store.addProject(path: pathB) // selection now in B
        let projectA = store.projects.first(where: { $0.path == pathA })!
        let sessionIDsA = store.sessions.filter { $0.projectPath == pathA }.map(\.id)
        let selectionBefore = store.selection

        store.removeProject(projectA)

        XCTAssertEqual(store.selection, selectionBefore)
        XCTAssertFalse(store.projects.contains { $0.path == pathA })
        XCTAssertEqual(Set(spy.closedIDs), Set(sessionIDsA))
    }

    // MARK: - 10

    func test10_renameSessionTrimsWhitespaceAndNoOpsOnBlank() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!

        store.renameSession(session.id, to: "  build server  ")
        XCTAssertEqual(store.sessions.first { $0.id == session.id }?.name, "build server")

        store.renameSession(session.id, to: "   \n\t")
        XCTAssertEqual(store.sessions.first { $0.id == session.id }?.name, "build server")
    }

    // MARK: - 11

    func test11_persistenceRoundTripsThroughASecondStore() throws {
        let url = TestSupport.freshStateURL()
        let spy1 = SpyTerminals()
        let store1 = AppStore(terminals: spy1, stateURL: url)

        let pathA = "/tmp/proj-A"
        let pathB = "/tmp/proj-B"
        store1.addProject(path: pathA)
        store1.newSession(in: store1.projects.first { $0.path == pathA }!)
        store1.addProject(path: pathB)

        let toRename = store1.sessions.first { $0.projectPath == pathA && $0.name == "Session 1" }!
        store1.renameSession(toRename.id, to: "renamed session")
        let toClose = store1.sessions.first { $0.projectPath == pathA && $0.name == "Session 2" }!
        store1.closeSession(toClose.id)

        let spy2 = SpyTerminals()
        let store2 = AppStore(terminals: spy2, stateURL: url)

        XCTAssertEqual(Set(store2.projects), Set(store1.projects))
        XCTAssertEqual(Set(store2.sessions), Set(store1.sessions))
        XCTAssertEqual(store2.selection, store1.selection)

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"version\":2"), "expected literal \"version\":2 in: \(raw)")
    }

    // MARK: - 12

    func test12_corruptStateFileStartsEmptyAndIsNotOverwritten() throws {
        let url = TestSupport.freshStateURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = "not json at all {{{"
        try Data(garbage.utf8).write(to: url)

        let spy = SpyTerminals()
        let store = AppStore(terminals: spy, stateURL: url)

        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.selection)

        // A failed load must not delete or overwrite the unreadable file.
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(contents, garbage)
    }

    // MARK: - 13

    func test13_missingStateFileStartsEmpty() {
        let url = TestSupport.freshStateURL() // deliberately never created
        let spy = SpyTerminals()

        let store = AppStore(terminals: spy, stateURL: url)

        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.selection)
    }

    // MARK: - 14

    func test14_counterSeedsFromRestoredSessionNamesIgnoringRenamed() throws {
        let url = TestSupport.freshStateURL()
        let path = "/tmp/proj-restored"
        let restoredSessions = [
            SessionRow(id: UUID().uuidString, target: .root(projectPath: path), name: "Session 3"),
            SessionRow(id: UUID().uuidString, target: .root(projectPath: path), name: "Session 7"),
            SessionRow(id: UUID().uuidString, target: .root(projectPath: path), name: "build server"),
        ]
        let state = PersistedState(
            version: 2,
            projects: [path],
            sessions: restoredSessions,
            workspaces: [],
            selection: restoredSessions[0].id
        )
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url)

        let spy = SpyTerminals()
        let store = AppStore(terminals: spy, stateURL: url)
        let project = store.projects.first { $0.path == path }!

        store.newSession(in: project)

        XCTAssertTrue(store.sessions.contains { $0.name == "Session 8" })
        XCTAssertFalse(store.sessions.contains { $0.name == "Session 1" })
    }

    // MARK: - 15

    func test15_processExitCallbackRoutesThroughCloseSession() {
        let (store, spy, _) = TestSupport.makeStore()
        let path = "/tmp/proj-A"
        store.addProject(path: path)
        store.newSession(in: store.projects.first!)

        let sessions = store.sessions.filter { $0.projectPath == path }
        let s1 = sessions.first { $0.name == "Session 1" }!
        let s2 = sessions.first { $0.name == "Session 2" }!
        XCTAssertEqual(store.selection, s2.id)

        // Simulate the terminal's real exit callback firing, instead of
        // calling store.closeSession directly, to prove init wired
        // terminals.onProcessExit into closeSession.
        spy.onProcessExit?(s2.id)

        XCTAssertFalse(store.sessions.contains { $0.id == s2.id })
        XCTAssertEqual(store.selection, s1.id)
    }

    // MARK: - 16

    func test16_stateFileWithoutVersionFieldDecodesAsVersion1() throws {
        let url = TestSupport.freshStateURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Live-compat path: state.json files written before the version field must keep loading (decoded as version 1).
        let legacyJSON = """
        {"projects":["/tmp/proj-legacy"],"sessions":[{"id":"legacy-1","projectPath":"/tmp/proj-legacy","name":"Session 1"}],"selection":"legacy-1"}
        """
        try Data(legacyJSON.utf8).write(to: url)

        let spy = SpyTerminals()
        let store = AppStore(terminals: spy, stateURL: url)

        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(store.projects.first?.path, "/tmp/proj-legacy")
        let sessions = store.sessions.filter { $0.projectPath == "/tmp/proj-legacy" }
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.name, "Session 1")
        XCTAssertEqual(sessions.first?.id, "legacy-1")
        XCTAssertEqual(store.selection, "legacy-1")
    }

    // MARK: - 17

    func test17_orderedSessionsGroupsByProjectInSidebarOrderRegardlessOfInsertionInterleaving() {
        let (store, _, _) = TestSupport.makeStore()
        let pathA = "/tmp/proj-A"
        let pathB = "/tmp/proj-B"
        store.addProject(path: pathA) // A: Session 1
        store.addProject(path: pathB) // B: Session 1
        let projectA = store.projects.first(where: { $0.path == pathA })!
        store.newSession(in: projectA) // A: Session 2, inserted into `sessions` after B1

        let ordered = store.orderedSessions.map { ($0.projectPath, $0.name) }
        XCTAssertEqual(ordered.map(\.0), [pathA, pathA, pathB])
        XCTAssertEqual(ordered.map(\.1), ["Session 1", "Session 2", "Session 1"])
    }

    // MARK: - 18

    func test18_selectNextAndPreviousWrapAndHandleNilSelection() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let project = store.projects.first!
        store.newSession(in: project)
        store.newSession(in: project)
        let ordered = store.orderedSessions
        XCTAssertEqual(ordered.count, 3)

        store.selection = nil
        store.selectNext()
        XCTAssertEqual(store.selection, ordered[0].id, "nil selection -> next selects first")

        store.selection = nil
        store.selectPrevious()
        XCTAssertEqual(store.selection, ordered[2].id, "nil selection -> previous selects last")

        store.selection = ordered[2].id
        store.selectNext()
        XCTAssertEqual(store.selection, ordered[0].id, "next wraps last -> first")

        store.selection = ordered[0].id
        store.selectPrevious()
        XCTAssertEqual(store.selection, ordered[2].id, "previous wraps first -> last")
    }

    // MARK: - 19

    func test19_selectSessionAtIndexCrossesProjectBoundariesAndRejectsOutOfRange() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        store.addProject(path: "/tmp/proj-B")
        let ordered = store.orderedSessions
        XCTAssertEqual(ordered.count, 2)

        XCTAssertTrue(store.selectSession(at: 1))
        XCTAssertEqual(store.selection, ordered[1].id)

        XCTAssertFalse(store.selectSession(at: 5))
        XCTAssertEqual(store.selection, ordered[1].id, "out-of-range is a no-op")
    }

    // MARK: - 20

    func test20_navigationWithZeroSessionsIsNoOp() {
        let (store, _, _) = TestSupport.makeStore()

        store.selectNext()
        XCTAssertNil(store.selection)

        store.selectPrevious()
        XCTAssertNil(store.selection)

        XCTAssertFalse(store.selectSession(at: 0))
        XCTAssertNil(store.selection)
    }

    // MARK: - 21

    func test21_v1JSONMigratesToRootTargetsAndSavesAsV2() throws {
        let url = TestSupport.freshStateURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Hand-written v1 shape (flat projectPath sessions, explicit
        // "version":1), matching test16's literal-string style.
        let legacyJSON = """
        {"version":1,"projects":["/tmp/proj-v1"],"sessions":[{"id":"v1-1","projectPath":"/tmp/proj-v1","name":"Session 1"}],"selection":"v1-1"}
        """
        try Data(legacyJSON.utf8).write(to: url)

        let spy = SpyTerminals()
        let store = AppStore(terminals: spy, stateURL: url)

        XCTAssertTrue(store.workspaces.isEmpty)
        let session = store.sessions.first { $0.id == "v1-1" }!
        XCTAssertEqual(session.target, .root(projectPath: "/tmp/proj-v1"))
        XCTAssertEqual(session.projectPath, "/tmp/proj-v1")

        // Any mutating call triggers a save; confirm it's written back as v2.
        store.renameSession("v1-1", to: "renamed")

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"version\":2"), "expected migrated save to be version 2: \(raw)")
        XCTAssertTrue(raw.contains("\"workspaces\""), "expected migrated save to include a workspaces key: \(raw)")
    }

    // MARK: - 22

    func test22_v2RoundTripPreservesWorkspacesSessionTargetsAndLabels() async throws {
        let fake = FakeWorkspaceEngine()
        let (store1, _, url) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store1.addProject(path: pathA)

        let wsRow = WorkspaceRow(projectPath: pathA, name: "feature-x", path: "/tmp/workspaces/feature-x", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store1.createWorkspace(in: pathA)
        let workspace = store1.workspaces.first!
        store1.setWorkspaceLabel(workspace.id, label: "My Feature")

        let spy2 = SpyTerminals()
        let store2 = AppStore(terminals: spy2, stateURL: url, engine: FakeWorkspaceEngine())

        XCTAssertEqual(store2.workspaces, store1.workspaces)
        XCTAssertEqual(store2.workspaces.first?.label, "My Feature")
        XCTAssertEqual(Set(store2.sessions), Set(store1.sessions))
        XCTAssertTrue(store2.sessions.contains { $0.target == .workspace(projectPath: pathA, name: "feature-x") })
    }

    // MARK: - 23

    func test23_createWorkspaceSuccessAppendsRowCreatesAndSelectsSession() async throws {
        let fake = FakeWorkspaceEngine()
        let (store, _, url) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA)

        let expectedRow = WorkspaceRow(projectPath: pathA, name: "calm-river", path: "/tmp/workspaces/calm-river", label: nil)
        fake.nextCreateResult = .success(expectedRow)

        await store.createWorkspace(in: pathA)

        XCTAssertEqual(fake.createCalls, [pathA])
        XCTAssertEqual(store.workspaces, [expectedRow])
        let wsSessions = store.sessions.filter { $0.target == .workspace(projectPath: pathA, name: "calm-river") }
        XCTAssertEqual(wsSessions.count, 1)
        XCTAssertEqual(wsSessions.first?.name, "Session 1")
        XCTAssertEqual(store.selection, wsSessions.first?.id)

        let spy2 = SpyTerminals()
        let store2 = AppStore(terminals: spy2, stateURL: url, engine: FakeWorkspaceEngine())
        XCTAssertEqual(store2.workspaces, [expectedRow])
        XCTAssertTrue(store2.sessions.contains { $0.target == .workspace(projectPath: pathA, name: "calm-river") })
    }

    // MARK: - 24

    func test24_createWorkspaceFailureLeavesStateUntouchedAndSetsLastError() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA)
        let selectionBefore = store.selection
        let sessionsBefore = store.sessions
        let workspacesBefore = store.workspaces

        fake.nextCreateResult = .failure(.nameConflict("jj workspace already exists: agents/calm-river"))

        await store.createWorkspace(in: pathA)

        XCTAssertEqual(store.workspaces, workspacesBefore)
        XCTAssertEqual(store.sessions, sessionsBefore)
        XCTAssertEqual(store.selection, selectionBefore)
        XCTAssertEqual(store.lastError, "jj workspace already exists: agents/calm-river")
    }

    // MARK: - 25

    func test25a_perTargetCounterWorkspaceStartsAtSessionOneRegardlessOfRootCounter() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA) // root: Session 1
        let project = store.projects.first!
        store.newSession(in: project) // root: Session 2
        store.newSession(in: project) // root: Session 3
        XCTAssertTrue(store.sessions.contains { $0.name == "Session 3" && $0.target == .root(projectPath: pathA) })

        let wsRow = WorkspaceRow(projectPath: pathA, name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: pathA)

        let wsSession = store.sessions.first { $0.target == .workspace(projectPath: pathA, name: "ws-a") }!
        XCTAssertEqual(wsSession.name, "Session 1", "a fresh workspace's counter must not inherit the project root's counter")
    }

    func test25b_restoredV2StateSeedsCountersIndependentlyPerTarget() throws {
        let url = TestSupport.freshStateURL()
        let pathA = "/tmp/proj-A"
        let wsRow = WorkspaceRow(projectPath: pathA, name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        let rootSessions = [
            SessionRow(id: UUID().uuidString, target: .root(projectPath: pathA), name: "Session 1"),
            SessionRow(id: UUID().uuidString, target: .root(projectPath: pathA), name: "Session 5"),
        ]
        let wsSessions = [
            SessionRow(id: UUID().uuidString, target: .workspace(projectPath: pathA, name: "ws-a"), name: "Session 1"),
            SessionRow(id: UUID().uuidString, target: .workspace(projectPath: pathA, name: "ws-a"), name: "Session 2"),
        ]
        let state = PersistedState(
            version: 2,
            projects: [pathA],
            sessions: rootSessions + wsSessions,
            workspaces: [wsRow],
            selection: nil
        )
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url)

        let spy = SpyTerminals()
        let store = AppStore(terminals: spy, stateURL: url)

        store.newSession(in: .root(projectPath: pathA))
        store.newSession(in: .workspace(projectPath: pathA, name: "ws-a"))

        XCTAssertTrue(store.sessions.contains { $0.target == .root(projectPath: pathA) && $0.name == "Session 6" })
        XCTAssertTrue(store.sessions.contains { $0.target == .workspace(projectPath: pathA, name: "ws-a") && $0.name == "Session 3" })
    }

    // MARK: - 26

    func test26a_deleteWorkspaceTearsDownSessionsRemovesRowAndClearsSelectionWhenInside() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA)

        let wsRow = WorkspaceRow(projectPath: pathA, name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: pathA) // ws: Session 1, selected
        store.newSession(in: .workspace(projectPath: pathA, name: "ws-a")) // ws: Session 2, selected

        let wsSessionIDs = store.sessions
            .filter { $0.target == .workspace(projectPath: pathA, name: "ws-a") }
            .map(\.id)
        XCTAssertEqual(wsSessionIDs.count, 2)
        XCTAssertTrue(wsSessionIDs.contains(store.selection!))

        await store.deleteWorkspace(wsRow.id)

        XCTAssertEqual(spy.closedIDs.count, wsSessionIDs.count, "each session must be closed exactly once")
        XCTAssertEqual(Set(spy.closedIDs), Set(wsSessionIDs))
        XCTAssertTrue(store.sessions.filter { $0.target == .workspace(projectPath: pathA, name: "ws-a") }.isEmpty)
        XCTAssertFalse(store.workspaces.contains { $0.id == wsRow.id })
        XCTAssertEqual(fake.deleteCalls, [wsRow])
        XCTAssertNil(store.selection)
    }

    func test26b_deleteWorkspaceLeavesUnrelatedRootSelectionUntouched() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA) // root: Session 1, selected
        let rootSelection = store.selection

        let wsRow = WorkspaceRow(projectPath: pathA, name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: pathA) // ws: Session 1, now selected

        // Re-select the root session explicitly: createWorkspace moves
        // selection to its new session, and this variant is about a
        // pre-existing ROOT selection surviving an unrelated workspace's
        // deletion, not about createWorkspace's own selection behavior
        // (already covered by test23).
        store.selection = rootSelection

        await store.deleteWorkspace(wsRow.id)

        XCTAssertEqual(store.selection, rootSelection)
        XCTAssertTrue(store.workspaces.isEmpty)
    }

    // MARK: - 27

    func test27_deleteWorkspaceEngineFailureKeepsWorkspaceRowAsRetryMarker() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA)

        let wsRow = WorkspaceRow(projectPath: pathA, name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: pathA)
        let wsSessionID = store.sessions.first { $0.target == .workspace(projectPath: pathA, name: "ws-a") }!.id

        fake.nextDeleteResult = .failure(.failed("jj workspace forget failed"))

        await store.deleteWorkspace(wsRow.id)

        XCTAssertTrue(spy.closedIDs.contains(wsSessionID), "the session was already torn down before the engine call")
        XCTAssertFalse(store.sessions.contains { $0.id == wsSessionID })
        XCTAssertTrue(store.workspaces.contains { $0.id == wsRow.id }, "engine failure must leave the row as a visible retry marker")
        XCTAssertEqual(store.lastError, "jj workspace forget failed")
    }

    // MARK: - 28

    func test28_orderedTargetsGroupsRootBeforeWorkspacesPerProjectInCreationOrder() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        let pathB = "/tmp/proj-B"
        store.addProject(path: pathA)
        store.addProject(path: pathB)

        fake.nextCreateResult = .success(WorkspaceRow(projectPath: pathA, name: "a1", path: "/tmp/workspaces/a1", label: nil))
        await store.createWorkspace(in: pathA)
        fake.nextCreateResult = .success(WorkspaceRow(projectPath: pathA, name: "a2", path: "/tmp/workspaces/a2", label: nil))
        await store.createWorkspace(in: pathA)
        fake.nextCreateResult = .success(WorkspaceRow(projectPath: pathB, name: "b1", path: "/tmp/workspaces/b1", label: nil))
        await store.createWorkspace(in: pathB)

        let expectedTargets: [TargetRef] = [
            .root(projectPath: pathA),
            .workspace(projectPath: pathA, name: "a1"),
            .workspace(projectPath: pathA, name: "a2"),
            .root(projectPath: pathB),
            .workspace(projectPath: pathB, name: "b1"),
        ]
        XCTAssertEqual(store.orderedTargets, expectedTargets)

        // Each target above has exactly one session ("Session 1"), created
        // in the same order, so orderedSessions must mirror orderedTargets.
        XCTAssertEqual(store.orderedSessions.map(\.target), expectedTargets)
    }

    // MARK: - 29

    func test29_removeProjectDropsWorkspacesLocallyWithoutTouchingEngine() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA)

        let wsRow = WorkspaceRow(projectPath: pathA, name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: pathA)
        let wsSessionID = store.sessions.first { $0.target == .workspace(projectPath: pathA, name: "ws-a") }!.id

        let project = store.projects.first(where: { $0.path == pathA })!
        store.removeProject(project)

        XCTAssertTrue(fake.deleteCalls.isEmpty, "removing a project locally must never touch the engine")
        XCTAssertFalse(store.sessions.contains { $0.id == wsSessionID })
        XCTAssertTrue(store.workspaces.isEmpty)
    }

    // MARK: - 30

    func test30a_newSessionNilWithSelectionInsideWorkspaceTargetsThatWorkspace() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA)

        let wsRow = WorkspaceRow(projectPath: pathA, name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: pathA) // ws: Session 1, selected

        store.newSession(in: nil)

        let wsSessionNames = store.sessions
            .filter { $0.target == .workspace(projectPath: pathA, name: "ws-a") }
            .map(\.name)
            .sorted()
        XCTAssertEqual(wsSessionNames, ["Session 1", "Session 2"])
        XCTAssertEqual(
            store.sessions.filter { $0.target == .root(projectPath: pathA) }.count, 1,
            "the project's root target must be untouched"
        )
    }

    func test30b_newSessionNilWithNoSelectionTargetsFirstOrderedTarget() {
        let (store, _, _) = TestSupport.makeStore()
        let pathA = "/tmp/proj-A"
        let pathB = "/tmp/proj-B"
        store.addProject(path: pathA)
        store.addProject(path: pathB)
        store.selection = nil

        store.newSession(in: nil)

        XCTAssertEqual(store.orderedTargets.first, .root(projectPath: pathA))
        XCTAssertEqual(store.sessions.filter { $0.target == .root(projectPath: pathA) }.count, 2)
        XCTAssertEqual(store.sessions.filter { $0.target == .root(projectPath: pathB) }.count, 1)
    }

    // MARK: - 31

    func test31a_workingDirectoryForRootSessionIsProjectPath() {
        let (store, _, _) = TestSupport.makeStore()
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA)
        let session = store.sessions.first { $0.target == .root(projectPath: pathA) }!

        XCTAssertEqual(store.workingDirectory(for: session), pathA)
    }

    func test31b_workingDirectoryForWorkspaceSessionIsWorkspacePath() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA)

        let wsRow = WorkspaceRow(projectPath: pathA, name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: pathA)
        let wsSession = store.sessions.first { $0.target == .workspace(projectPath: pathA, name: "ws-a") }!

        XCTAssertEqual(store.workingDirectory(for: wsSession), wsRow.path)
    }

    func test31c_workingDirectoryFallsBackToProjectPathWhenWorkspaceRowIsMissing() {
        let (store, _, _) = TestSupport.makeStore()
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA)
        // Deliberately not created through createWorkspace, so no matching
        // WorkspaceRow exists — the "shouldn't happen" desync case.
        let orphan = SessionRow(id: UUID().uuidString, target: .workspace(projectPath: pathA, name: "ghost"), name: "Session 1")

        XCTAssertEqual(store.workingDirectory(for: orphan), pathA)
    }

    // MARK: - 32

    func test32a_selectOrCreateSessionSelectsExistingFirstSessionWithoutCreatingANewOne() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA)

        let wsRow = WorkspaceRow(projectPath: pathA, name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: pathA) // ws: Session 1
        let target = TargetRef.workspace(projectPath: pathA, name: "ws-a")
        let existingSession = store.sessions.first { $0.target == target }!
        store.newSession(in: .root(projectPath: pathA)) // move selection elsewhere
        XCTAssertNotEqual(store.selection, existingSession.id)

        store.selectOrCreateSession(in: target)

        XCTAssertEqual(store.selection, existingSession.id)
        XCTAssertEqual(store.sessions.filter { $0.target == target }.count, 1, "must not create a new session when one already exists")
    }

    func test32b_selectOrCreateSessionCreatesASessionWhenTargetHasNone() {
        let (store, _, _) = TestSupport.makeStore()
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA)
        let target = TargetRef.root(projectPath: pathA)
        let onlySession = store.sessions.first { $0.target == target }!
        store.closeSession(onlySession.id)
        XCTAssertTrue(store.sessions.filter { $0.target == target }.isEmpty)

        store.selectOrCreateSession(in: target)

        let created = store.sessions.first { $0.target == target }
        XCTAssertNotNil(created)
        XCTAssertEqual(store.selection, created?.id)
    }

    // MARK: - 33

    func test33a_landWorkspaceSuccessTearsDownSessionsRemovesRowAndClearsSelectionWhenInside() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, url) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA)

        let wsRow = WorkspaceRow(projectPath: pathA, name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: pathA) // ws: Session 1, selected
        store.newSession(in: .workspace(projectPath: pathA, name: "ws-a")) // ws: Session 2, selected

        let wsSessionIDs = store.sessions
            .filter { $0.target == .workspace(projectPath: pathA, name: "ws-a") }
            .map(\.id)
        XCTAssertEqual(wsSessionIDs.count, 2)
        XCTAssertTrue(wsSessionIDs.contains(store.selection!))

        fake.nextLandResult = .success(LandResult(commitID: "abc123", bookmark: "main"))
        let landed = await store.landWorkspace(wsRow.id, message: "Ship it")

        XCTAssertTrue(landed)
        XCTAssertEqual(fake.landCalls.count, 1)
        XCTAssertEqual(fake.landCalls.first?.workspace, wsRow)
        XCTAssertEqual(fake.landCalls.first?.message, "Ship it")
        XCTAssertNil(fake.landCalls.first?.createTrunk)
        XCTAssertEqual(spy.closedIDs.count, wsSessionIDs.count, "each session must be closed exactly once")
        XCTAssertEqual(Set(spy.closedIDs), Set(wsSessionIDs))
        XCTAssertTrue(store.sessions.filter { $0.target == .workspace(projectPath: pathA, name: "ws-a") }.isEmpty)
        XCTAssertFalse(store.workspaces.contains { $0.id == wsRow.id })
        XCTAssertNil(store.selection)

        // The removal must persist across a fresh AppStore load from the
        // same stateURL, not just live in the in-memory store.
        let spy2 = SpyTerminals()
        let store2 = AppStore(terminals: spy2, stateURL: url, engine: FakeWorkspaceEngine())
        XCTAssertFalse(store2.workspaces.contains { $0.id == wsRow.id })
        XCTAssertTrue(store2.sessions.filter { $0.target == .workspace(projectPath: pathA, name: "ws-a") }.isEmpty)
    }

    func test33b_landWorkspaceSuccessLeavesUnrelatedRootSelectionUntouched() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA) // root: Session 1, selected
        let rootSelection = store.selection

        let wsRow = WorkspaceRow(projectPath: pathA, name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: pathA) // ws: Session 1, now selected

        // Re-select the root session explicitly: createWorkspace moves
        // selection to its new session, and this variant is about a
        // pre-existing ROOT selection surviving an unrelated workspace's
        // landing, not about createWorkspace's own selection behavior.
        store.selection = rootSelection

        fake.nextLandResult = .success(LandResult(commitID: "abc123", bookmark: "main"))
        let landed = await store.landWorkspace(wsRow.id, message: "Ship it")

        XCTAssertTrue(landed)
        XCTAssertEqual(store.selection, rootSelection)
        XCTAssertTrue(store.workspaces.isEmpty)
    }

    // MARK: - 34

    func test34_landWorkspaceConflictFailureLeavesEverythingIntact() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA)

        let wsRow = WorkspaceRow(projectPath: pathA, name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: pathA) // ws: Session 1, selected

        let sessionsBefore = store.sessions
        let workspacesBefore = store.workspaces
        let selectionBefore = store.selection

        fake.nextLandResult = .failure(.landConflict("trunk moved since this workspace was created"))
        let landed = await store.landWorkspace(wsRow.id, message: "Ship it")

        XCTAssertFalse(landed)
        XCTAssertTrue(spy.closedIDs.isEmpty, "a land-conflict must leave the workspace fully intact, sessions included")
        XCTAssertEqual(store.sessions, sessionsBefore)
        XCTAssertEqual(store.workspaces, workspacesBefore)
        XCTAssertEqual(store.selection, selectionBefore)
        XCTAssertEqual(store.lastError, "trunk moved since this workspace was created")
        XCTAssertNil(store.pendingTrunkBootstrap)
    }

    // MARK: - 35

    func test35_landWorkspaceNoTrunkFailureSetsPendingTrunkBootstrapWithoutLastError() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA)

        let wsRow = WorkspaceRow(projectPath: pathA, name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: pathA)

        let sessionsBefore = store.sessions
        let workspacesBefore = store.workspaces
        let selectionBefore = store.selection

        fake.nextLandResult = .failure(.noTrunk("no main/master/trunk bookmark exists"))
        let landed = await store.landWorkspace(wsRow.id, message: "Ship it")

        XCTAssertFalse(landed)
        XCTAssertTrue(spy.closedIDs.isEmpty)
        XCTAssertEqual(store.sessions, sessionsBefore)
        XCTAssertEqual(store.workspaces, workspacesBefore)
        XCTAssertEqual(store.selection, selectionBefore)
        XCTAssertNil(store.lastError, "noTrunk is recoverable via pendingTrunkBootstrap, not a dead-end lastError")
        XCTAssertEqual(store.pendingTrunkBootstrap?.workspaceID, wsRow.id)
        XCTAssertEqual(store.pendingTrunkBootstrap?.message, "Ship it")
    }

    // MARK: - 36

    func test36_retryLandWorkspaceWithCreateTrunkPassesThroughAndSucceeds() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA)

        let wsRow = WorkspaceRow(projectPath: pathA, name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: pathA)

        fake.nextLandResult = .failure(.noTrunk("no main/master/trunk bookmark exists"))
        _ = await store.landWorkspace(wsRow.id, message: "Ship it")
        XCTAssertNotNil(store.pendingTrunkBootstrap, "precondition: a prior noTrunk failure set the pending retry")

        fake.nextLandResult = .success(LandResult(commitID: "def456", bookmark: "main"))
        let landed = await store.landWorkspace(wsRow.id, message: "Ship it", createTrunk: "main")

        XCTAssertEqual(fake.landCalls.last?.createTrunk, "main")
        XCTAssertTrue(landed)
        XCTAssertTrue(store.workspaces.isEmpty)
    }

    // MARK: - 37

    func test37_landWorkspaceNothingToLandFailureSetsLastError() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA)

        let wsRow = WorkspaceRow(projectPath: pathA, name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: pathA)

        let sessionsBefore = store.sessions
        let workspacesBefore = store.workspaces
        let selectionBefore = store.selection

        fake.nextLandResult = .failure(.nothingToLand("workspace has no changes to land"))
        let landed = await store.landWorkspace(wsRow.id, message: "Ship it")

        XCTAssertFalse(landed)
        XCTAssertTrue(spy.closedIDs.isEmpty)
        XCTAssertEqual(store.sessions, sessionsBefore)
        XCTAssertEqual(store.workspaces, workspacesBefore)
        XCTAssertEqual(store.selection, selectionBefore)
        XCTAssertEqual(store.lastError, "workspace has no changes to land")
    }
}
