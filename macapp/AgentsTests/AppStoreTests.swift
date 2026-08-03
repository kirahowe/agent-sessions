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
        store1.newSession(in: store1.projects.first { $0.path == pathA })
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
        XCTAssertTrue(raw.contains("\"version\":1"), "expected literal \"version\":1 in: \(raw)")
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
            SessionRow(id: UUID().uuidString, projectPath: path, name: "Session 3"),
            SessionRow(id: UUID().uuidString, projectPath: path, name: "Session 7"),
            SessionRow(id: UUID().uuidString, projectPath: path, name: "build server"),
        ]
        let state = PersistedState(
            version: 1,
            projects: [path],
            sessions: restoredSessions,
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
}
