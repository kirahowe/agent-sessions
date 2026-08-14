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

    func test10_renameSessionSetsAStickyCustomNameAndNoOpsOnBlank() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!

        store.renameSession(session.id, to: "  build server  ")
        let renamed = store.sessions.first { $0.id == session.id }!
        XCTAssertEqual(renamed.customName, "build server")
        XCTAssertEqual(renamed.displayName, "build server")
        // The auto label stays intact underneath as the counter seed/fallback.
        XCTAssertEqual(renamed.name, "Session 1")

        store.renameSession(session.id, to: "   \n\t")
        XCTAssertEqual(store.sessions.first { $0.id == session.id }?.customName, "build server",
                       "a blank rename is a no-op and must not clear the custom name")
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

    func test12_corruptStateFileStartsEmptyAndIsMovedAside() throws {
        let url = TestSupport.freshStateURL()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = "not json at all {{{"
        try Data(garbage.utf8).write(to: url)

        let spy = SpyTerminals()
        let store = AppStore(terminals: spy, stateURL: url)

        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.selection)

        // The garbage must no longer sit at stateURL...
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // ...but must survive, untouched, as exactly one moved-aside sibling.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("state.json.corrupt-") }
        XCTAssertEqual(siblings.count, 1, "expected exactly one corrupt-sibling, found: \(siblings)")
        let corruptContents = try String(contentsOf: directory.appendingPathComponent(siblings[0]), encoding: .utf8)
        XCTAssertEqual(corruptContents, garbage)
    }

    func test12b_mutationAfterCorruptLoadWritesFreshStateWithoutTouchingCorruptSibling() throws {
        let url = TestSupport.freshStateURL()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = "not json at all {{{"
        try Data(garbage.utf8).write(to: url)

        let spy = SpyTerminals()
        let store = AppStore(terminals: spy, stateURL: url)

        // The clobber-protection contract: a mutation after a failed load
        // must produce a fresh, valid state.json, and must never touch the
        // preserved corrupt sibling.
        store.addProject(path: "/tmp/proj-A")

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"version\":2"), "expected fresh save to be version 2: \(raw)")

        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("state.json.corrupt-") }
        XCTAssertEqual(siblings.count, 1)
        let corruptContents = try String(contentsOf: directory.appendingPathComponent(siblings[0]), encoding: .utf8)
        XCTAssertEqual(corruptContents, garbage, "the original garbage must still be intact in the corrupt sibling")
    }

    func test12c_undecodableButValidJSONIsAlsoMovedAside() throws {
        let url = TestSupport.freshStateURL()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Valid JSON, but "projects" doesn't decode as PersistedState expects
        // — pins that a decode failure (not just unreadable bytes) also
        // triggers move-aside protection.
        let wrongShape = #"{"version":2,"projects":"nope"}"#
        try Data(wrongShape.utf8).write(to: url)

        let spy = SpyTerminals()
        let store = AppStore(terminals: spy, stateURL: url)

        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("state.json.corrupt-") }
        XCTAssertEqual(siblings.count, 1)
        let corruptContents = try String(contentsOf: directory.appendingPathComponent(siblings[0]), encoding: .utf8)
        XCTAssertEqual(corruptContents, wrongShape)
    }

    // MARK: - 13

    func test13_missingStateFileStartsEmpty() throws {
        let url = TestSupport.freshStateURL() // deliberately never created
        let spy = SpyTerminals()

        let store = AppStore(terminals: spy, stateURL: url)

        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.selection)

        // A merely-missing file must not create any corrupt-sibling corpses.
        store.addProject(path: "/tmp/proj-A")

        let directory = url.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("state.json.corrupt-") }
        XCTAssertTrue(siblings.isEmpty, "expected no corrupt siblings, found: \(siblings)")
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

    // MARK: - 21b

    // The upgrade path for existing users: a v2 state.json written before
    // `customName`/`agentTitle` existed omits those keys entirely. Decoding
    // must treat them as nil rather than throwing — a throw would move the
    // file aside as "corrupt" and silently wipe the user's projects/sessions
    // on the very first launch after the update.
    func test21b_v2JSONWithoutCustomNameOrAgentTitleDecodesThoseAsNil() throws {
        let url = TestSupport.freshStateURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let preFieldsJSON = """
        {"version":2,"projects":["/tmp/proj-A"],"sessions":[{"id":"s-1","target":{"root":{"projectPath":"/tmp/proj-A"}},"name":"Session 1"}],"workspaces":[],"selection":"s-1"}
        """
        try Data(preFieldsJSON.utf8).write(to: url)

        let spy = SpyTerminals()
        let store = AppStore(terminals: spy, stateURL: url)

        let session = store.sessions.first { $0.id == "s-1" }!
        XCTAssertNil(session.customName)
        XCTAssertNil(session.agentTitle)
        // With neither present the display name falls back to the auto label.
        XCTAssertEqual(session.displayName, "Session 1")
        XCTAssertNil(session.subtitle)
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
        XCTAssertNil(store.lastError, "a nil cleanupWarning must leave lastError untouched")

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

    /// The land itself succeeded (jj already forgot the workspace and
    /// advanced the bookmark, irreversibly) even though the leftover
    /// directory couldn't be trashed — so teardown must still fully happen,
    /// and the warning must surface as a non-fatal lastError rather than
    /// making landWorkspace look like it failed.
    func test33c_landWorkspaceCleanupWarningSurfacesAsLastErrorButTeardownStillHappens() async {
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

        fake.nextLandResult = .success(LandResult(commitID: "abc123", bookmark: "main", cleanupWarning: "some warning"))
        let landed = await store.landWorkspace(wsRow.id, message: "Ship it")

        XCTAssertTrue(landed)
        XCTAssertEqual(spy.closedIDs.count, wsSessionIDs.count, "each session must be closed exactly once")
        XCTAssertEqual(Set(spy.closedIDs), Set(wsSessionIDs))
        XCTAssertTrue(store.sessions.filter { $0.target == .workspace(projectPath: pathA, name: "ws-a") }.isEmpty)
        XCTAssertFalse(store.workspaces.contains { $0.id == wsRow.id })
        XCTAssertNil(store.selection)
        XCTAssertEqual(store.lastError, "some warning")
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

    // MARK: - 38

    func test38_newSessionWithCustomNameProducesRowWithThatName() {
        let (store, _, _) = TestSupport.makeStore()
        let path = "/tmp/proj-A"
        store.addProject(path: path)
        let project = store.projects.first!

        store.newSession(in: project, name: "custom")

        XCTAssertEqual(store.sessions.first { $0.id == store.selection }?.name, "custom")
    }

    // MARK: - 39

    func test39_newSessionWithBlankNameFallsBackToNumberedDefault() {
        let (store, _, _) = TestSupport.makeStore()
        let path = "/tmp/proj-A"
        store.addProject(path: path)
        let project = store.projects.first!

        store.newSession(in: project, name: "   ")

        XCTAssertEqual(store.sessions.first { $0.id == store.selection }?.name, "Session 2")
    }

    // MARK: - 40

    func test40_customNamedSessionDoesNotConsumeCounterNumber() {
        let (store, _, _) = TestSupport.makeStore()
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA) // root target: "Session 1" — a separate target/counter from the one below
        // A fresh workspace target with its own, untouched counter.
        let target = TargetRef.workspace(projectPath: pathA, name: "ws-a")

        store.newSession(in: target, name: "custom")
        store.newSession(in: target)

        let names = store.sessions.filter { $0.target == target }.map(\.name)
        XCTAssertEqual(Set(names), Set(["custom", "Session 1"]), "the custom name must not have consumed counter value 1")
    }

    // MARK: - 41

    func test41_addProjectStillAutoCreatesDefaultNamedFirstSession() {
        let (store, _, _) = TestSupport.makeStore()
        let path = "/tmp/proj-A"

        store.addProject(path: path)

        let sessions = store.sessions.filter { $0.projectPath == path }
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.name, "Session 1")
    }

    // MARK: - 42

    func test42_createWorkspaceWithLabelSetsLabelAndDisplayNameReturnsIt() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA)
        let expectedRow = WorkspaceRow(projectPath: pathA, name: "calm-river", path: "/tmp/workspaces/calm-river", label: nil)
        fake.nextCreateResult = .success(expectedRow)

        await store.createWorkspace(in: pathA, label: "my label")

        let workspace = store.workspaces.first { $0.name == "calm-river" }
        XCTAssertEqual(workspace?.label, "my label")
        XCTAssertEqual(workspace?.displayName, "my label")
    }

    // MARK: - 43

    func test43_createWorkspaceWithBlankLabelLeavesLabelNilAndDisplayNameFallsBackToGeneratedName() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA)
        let expectedRow = WorkspaceRow(projectPath: pathA, name: "calm-river", path: "/tmp/workspaces/calm-river", label: nil)
        fake.nextCreateResult = .success(expectedRow)

        await store.createWorkspace(in: pathA, label: "   ")

        let workspace = store.workspaces.first { $0.name == "calm-river" }
        XCTAssertNil(workspace?.label)
        XCTAssertEqual(workspace?.displayName, "calm-river")
    }

    // MARK: - 44

    func test44_createWorkspaceLabelSurvivesSaveReloadRoundTrip() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, url) = TestSupport.makeStore(engine: fake)
        let pathA = "/tmp/proj-A"
        store.addProject(path: pathA)
        let expectedRow = WorkspaceRow(projectPath: pathA, name: "calm-river", path: "/tmp/workspaces/calm-river", label: nil)
        fake.nextCreateResult = .success(expectedRow)

        await store.createWorkspace(in: pathA, label: "my label")

        let spy2 = SpyTerminals()
        let store2 = AppStore(terminals: spy2, stateURL: url, engine: FakeWorkspaceEngine())
        XCTAssertEqual(store2.workspaces.first { $0.name == "calm-river" }?.label, "my label")
    }

    // MARK: - 45

    func test45_applyStructuredSetOnRealSessionIsReadableViaStore() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!

        store.apply(.structured(.set(.blocked)), to: session.id)

        XCTAssertEqual(store.attention[session.id]?.activity, .blocked)
    }

    // MARK: - 46

    func test46_applyStructuredClearClearsActivityButLeavesTheLatchedEntry() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!
        store.apply(.structured(.set(.yourTurn)), to: session.id)

        store.apply(.structured(.clear), to: session.id)

        XCTAssertNil(store.attention[session.id]?.activity)
        // Unlike the old setSessionActivity(nil:) API, a structured clear
        // does NOT remove the dictionary entry — it leaves an AttentionState
        // with a nil activity and isStructured still true. That latch is the
        // whole point: it's what keeps a later unstructured notification
        // (e.g. a stray bell) from reclassifying a session the hook has
        // already proven it's authoritative for.
        XCTAssertEqual(
            store.attention[session.id]?.isStructured, true,
            "a structured clear must latch isStructured just like a structured set — losing that would let an unstructured signal reclassify a session the hook already speaks for"
        )
    }

    // MARK: - 47

    func test47_applyStructuredUnknownIDIsIgnored() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")

        store.apply(.structured(.set(.blocked)), to: "not-a-real-id")

        XCTAssertTrue(store.attention.isEmpty)
    }

    // MARK: - 48

    func test48_closingSessionDropsItsAttentionEntry() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!
        store.apply(.structured(.set(.blocked)), to: session.id)

        store.closeSession(session.id)

        XCTAssertNil(store.attention[session.id])
    }

    // MARK: - 49

    func test49_removeProjectDropsAttentionForAllItsSessions() {
        let (store, _, _) = TestSupport.makeStore()
        let path = "/tmp/proj-A"
        store.addProject(path: path)
        store.newSession(in: store.projects.first!)
        let sessions = store.sessions.filter { $0.projectPath == path }
        for session in sessions {
            store.apply(.structured(.set(.yourTurn)), to: session.id)
        }
        XCTAssertEqual(store.attention.count, sessions.count)

        store.removeProject(store.projects.first!)

        XCTAssertTrue(store.attention.isEmpty)
    }

    // MARK: - 50

    func test50_attentionDoesNotSurviveSaveReloadRoundTrip() {
        let url = TestSupport.freshStateURL()
        let spy1 = SpyTerminals()
        let store1 = AppStore(terminals: spy1, stateURL: url)
        store1.addProject(path: "/tmp/proj-A")
        let session = store1.sessions.first!
        store1.apply(.structured(.set(.blocked)), to: session.id)
        XCTAssertFalse(store1.attention.isEmpty)

        let spy2 = SpyTerminals()
        let store2 = AppStore(terminals: spy2, stateURL: url)

        XCTAssertTrue(store2.attention.isEmpty, "attention must never be persisted")
    }

    // MARK: - 51

    func test51_onSessionSignalCallbackWiredInInitReachesStore() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!

        spy.onSessionSignal?(session.id, .structured(.set(.blocked)))

        XCTAssertEqual(store.attention[session.id]?.activity, .blocked)
    }

    // MARK: - 52

    func test52_onTitleChangeBecomesTheDisplayName() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!

        spy.onTitleChange?(session.id, "building the widget")

        let row = store.sessions.first { $0.id == session.id }!
        XCTAssertEqual(row.agentTitle, "building the widget")
        // With no manual rename, the agent title becomes the display name.
        XCTAssertEqual(row.displayName, "building the widget")
    }

    // MARK: - 53

    func test53_setSessionTitleUnknownIDIsIgnored() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")

        store.setSessionTitle("building the widget", for: "not-a-real-id")

        XCTAssertTrue(store.sessions.allSatisfy { $0.agentTitle == nil })
    }

    // MARK: - 54

    func test54_setSessionTitleTrimsAndABlankTitleKeepsTheLastRemembered() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!

        store.setSessionTitle("  building the widget  \n", for: session.id)
        XCTAssertEqual(store.sessions.first { $0.id == session.id }?.agentTitle, "building the widget")

        // A blank title must NOT clear the remembered one — "remember the last
        // title" means a shell quietly resetting its title keeps the name.
        store.setSessionTitle("   \n", for: session.id)
        XCTAssertEqual(store.sessions.first { $0.id == session.id }?.agentTitle, "building the widget")
    }

    // MARK: - 55

    func test55_manualRenameWinsOverALaterAgentTitle() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!

        store.renameSession(session.id, to: "my work")
        store.setSessionTitle("building the widget", for: session.id)

        let row = store.sessions.first { $0.id == session.id }!
        // The agent title is still recorded (it drives the subtitle)…
        XCTAssertEqual(row.agentTitle, "building the widget")
        // …but the sticky manual name still wins the display name.
        XCTAssertEqual(row.displayName, "my work")
        // …and the differing agent title shows through as the subtitle.
        XCTAssertEqual(row.subtitle, "building the widget")
    }

    // MARK: - 56

    func test56_displayNameFallsBackToLabelAndSubtitleHidesWhenItEqualsName() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!

        // No agent title, no rename: falls back to the auto label, no subtitle.
        var row = store.sessions.first { $0.id == session.id }!
        XCTAssertEqual(row.displayName, "Session 1")
        XCTAssertNil(row.subtitle)

        // Agent title present, no rename: it IS the name, so the subtitle would
        // just repeat it and is therefore suppressed.
        store.setSessionTitle("building the widget", for: session.id)
        row = store.sessions.first { $0.id == session.id }!
        XCTAssertEqual(row.displayName, "building the widget")
        XCTAssertNil(row.subtitle)
    }

    // MARK: - 57

    func test57_agentTitleSurvivesSaveReloadRoundTrip() {
        let url = TestSupport.freshStateURL()
        let spy1 = SpyTerminals()
        let store1 = AppStore(terminals: spy1, stateURL: url)
        store1.addProject(path: "/tmp/proj-A")
        let session = store1.sessions.first!
        store1.setSessionTitle("building the widget", for: session.id)

        let spy2 = SpyTerminals()
        let store2 = AppStore(terminals: spy2, stateURL: url)

        let reloaded = store2.sessions.first { $0.id == session.id }!
        XCTAssertEqual(reloaded.agentTitle, "building the widget",
                       "the agent title must persist so the name is stable across relaunches")
        XCTAssertEqual(reloaded.displayName, "building the widget")
    }

    // MARK: - 58

    func test58_moveSessionsReordersOneProjectBucketWithoutDisturbingInterleavedTargets() {
        let (store, _, _) = TestSupport.makeStore()
        let pathA = "/tmp/proj-A"
        let pathB = "/tmp/proj-B"
        store.addProject(path: pathA) // A1
        store.addProject(path: pathB) // B1
        let projectA = store.projects.first { $0.path == pathA }!
        store.newSession(in: projectA) // A2, globally after B1

        store.moveSessions(
            in: .root(projectPath: pathA),
            fromOffsets: IndexSet(integer: 1),
            toOffset: 0
        )

        let sessionsA = store.sessions
            .filter { $0.target == .root(projectPath: pathA) }
            .map(\.name)
        XCTAssertEqual(sessionsA, ["Session 2", "Session 1"])
        XCTAssertEqual(
            store.sessions.map(\.projectPath),
            [pathA, pathB, pathA],
            "reordering a target should rewrite only that target's slots inside the persisted array"
        )
        XCTAssertEqual(
            store.orderedSessions.map(\.name),
            ["Session 2", "Session 1", "Session 1"],
            "sidebar navigation order should follow the reordered bucket"
        )
    }

    // MARK: - 59

    func test59_moveSessionsPersistsWorkspaceOrderAcrossReload() async {
        let fake = FakeWorkspaceEngine()
        let (store1, _, url) = TestSupport.makeStore(engine: fake)
        let path = "/tmp/proj-A"
        store1.addProject(path: path)

        fake.nextCreateResult = .success(
            WorkspaceRow(projectPath: path, name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        )
        await store1.createWorkspace(in: path)
        let target = TargetRef.workspace(projectPath: path, name: "ws-a")
        store1.newSession(in: target) // Session 2
        store1.newSession(in: target) // Session 3

        store1.moveSessions(in: target, fromOffsets: IndexSet(integer: 2), toOffset: 0)

        let store2 = AppStore(terminals: SpyTerminals(), stateURL: url, engine: fake)
        let reloaded = store2.sessions
            .filter { $0.target == target }
            .map(\.name)
        XCTAssertEqual(reloaded, ["Session 3", "Session 1", "Session 2"])
    }

    // MARK: - 60

    func test60_moveSessionsRejectsUnknownTargetsInvalidOffsetsAndNoOpMoves() {
        let (store, _, _) = TestSupport.makeStore()
        let path = "/tmp/proj-A"
        store.addProject(path: path)
        let project = store.projects.first!
        store.newSession(in: project)
        store.newSession(in: project)
        let target = TargetRef.root(projectPath: path)
        let before = store.sessions

        store.moveSessions(
            in: .workspace(projectPath: path, name: "missing"),
            fromOffsets: IndexSet(integer: 0),
            toOffset: 0
        )
        XCTAssertEqual(store.sessions, before)

        store.moveSessions(in: target, fromOffsets: IndexSet(integer: 9), toOffset: 0)
        XCTAssertEqual(store.sessions, before)

        store.moveSessions(in: target, fromOffsets: IndexSet(integer: 0), toOffset: 9)
        XCTAssertEqual(store.sessions, before)

        store.moveSessions(in: target, fromOffsets: IndexSet(integer: 1), toOffset: 2)
        XCTAssertEqual(store.sessions, before, "moving an item to its current trailing slot should be a no-op")
    }

    // MARK: - 61

    func test61_blockedSessionCountIsZeroWithNoActivitySet() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")

        XCTAssertEqual(
            store.blockedSessionCount, 0,
            "a freshly created session has no activity at all yet, so blockedSessionCount must read 0 — a nonzero count here would put a phantom badge on the Dock before any agent has ever reported being blocked"
        )
    }

    // MARK: - 62

    func test62_blockedSessionCountIgnoresYourTurnSessions() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let project = store.projects.first!
        store.newSession(in: project)
        store.newSession(in: project)
        for session in store.sessions {
            store.apply(.structured(.set(.yourTurn)), to: session.id)
        }

        XCTAssertEqual(
            store.blockedSessionCount, 0,
            "sessions merely waiting for the user's next prompt (.yourTurn) can sit idle indefinitely at no cost, so they must never inflate blockedSessionCount — counting them would put an alarming Dock badge on the app for a state that isn't actually burning anyone's time"
        )
    }

    // MARK: - 63

    func test63_blockedSessionCountCountsOnlyBlockedAmongMixedActivity() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let project = store.projects.first!
        store.newSession(in: project)
        store.newSession(in: project)
        let sessions = store.sessions
        store.apply(.structured(.set(.blocked)), to: sessions[0].id)
        store.apply(.structured(.set(.yourTurn)), to: sessions[1].id)
        store.apply(.structured(.set(.blocked)), to: sessions[2].id)

        XCTAssertEqual(
            store.blockedSessionCount, 2,
            "blockedSessionCount must count only the .blocked entries among a mix of activity states — miscounting here means the Dock badge either undercounts real blockages the user hasn't noticed yet, or overcounts and cries wolf on sessions that are merely waiting on the user's own schedule"
        )
    }

    // MARK: - 64

    func test64_blockedSessionCountReflectsSeveralBlockedSessions() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let project = store.projects.first!
        store.newSession(in: project)
        store.newSession(in: project)
        for session in store.sessions {
            store.apply(.structured(.set(.blocked)), to: session.id)
        }

        XCTAssertEqual(
            store.blockedSessionCount, 3,
            "every one of three sessions is .blocked, so blockedSessionCount must read 3 — the Dock badge exists precisely to surface how many agents are stuck waiting, and an undercount here would leave the user unaware some of them need attention"
        )
    }

    // MARK: - 65

    func test65_closingABlockedSessionDropsBlockedSessionCount() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let project = store.projects.first!
        store.newSession(in: project)
        let sessions = store.sessions
        store.apply(.structured(.set(.blocked)), to: sessions[0].id)
        store.apply(.structured(.set(.blocked)), to: sessions[1].id)
        XCTAssertEqual(store.blockedSessionCount, 2)

        store.closeSession(sessions[0].id)

        XCTAssertEqual(
            store.blockedSessionCount, 1,
            "closing a blocked session must drop it out of blockedSessionCount immediately (pruneLiveSessionState already removes its attention entry) — otherwise the Dock badge would keep counting a session that no longer exists, permanently overstating how many agents actually need the user's attention"
        )
    }

    // MARK: - 66

    func test66_dockBadgeLabelIsNilForZeroAndTheCountOtherwise() {
        XCTAssertNil(
            AppStore.dockBadgeLabel(blockedCount: 0),
            "a zero blocked count must produce nil, not the string \"0\" — nil is the value NSDockTile.badgeLabel treats as \"clear the badge\", so returning \"0\" here would leave a permanent, meaningless badge on the Dock icon at rest"
        )
        XCTAssertEqual(
            AppStore.dockBadgeLabel(blockedCount: 1), "1",
            "a single blocked session must render as the literal string \"1\" on the Dock badge"
        )
        XCTAssertEqual(
            AppStore.dockBadgeLabel(blockedCount: 7), "7",
            "dockBadgeLabel must pass an arbitrary blocked count straight through as its decimal string, so the Dock badge always shows the user exactly how many sessions are blocked rather than some capped or rounded approximation"
        )
    }

    // MARK: - 67: reviewAndLandWorkspace

    /// Sets up a workspace and a scripted preview result, ready for
    /// `store.reviewAndLandWorkspace` to be called against it. Shared setup
    /// for the whole `reviewAndLandWorkspace` section below, mirroring how
    /// `test33a` etc. above hand-roll the same create-then-land setup for
    /// `landWorkspace` — pulled into a helper here because this section has
    /// many more variants to cover (dialog decision x preview shape x
    /// engine outcome) than `landWorkspace`'s own section needed.
    private func makeLandableWorkspace(
        store: AppStore, fake: FakeWorkspaceEngine, pathA: String = "/tmp/proj-A"
    ) async -> WorkspaceRow {
        store.addProject(path: pathA)
        let wsRow = WorkspaceRow(projectPath: pathA, name: "ws-a", path: "/tmp/workspaces/ws-a", label: nil)
        fake.nextCreateResult = .success(wsRow)
        await store.createWorkspace(in: pathA)
        return wsRow
    }

    /// THE regression test for the bug that motivated replacing
    /// `promptLandMessage`'s `String?` with `LandDecision`: confirming with
    /// a blank/absent message must still land — not silently no-op the way
    /// the old `nil`-collapsing prompt did (see `LandDecision`'s doc
    /// comment in DialogPresenting.swift). `.land(message: nil)` is exactly
    /// what `Dialogs.confirmLand` returns for "confirmed, field left blank
    /// or not shown at all"; this asserts the engine's `landWorkspace` was
    /// actually invoked for it, with teardown following through exactly as
    /// a normal successful land does.
    func test67_reviewAndLandWorkspaceConfirmedWithNilMessageStillLandsAndTearsDown() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let wsRow = await makeLandableWorkspace(store: store, fake: fake)
        let wsSessionID = store.sessions.first { $0.target == .workspace(projectPath: wsRow.projectPath, name: wsRow.name) }!.id

        let dialogs = FakeDialogs()
        dialogs.nextLandDecision = .land(message: nil)
        fake.nextLandResult = .success(LandResult(commitID: "abc123", bookmark: "main"))

        await store.reviewAndLandWorkspace(wsRow.id, dialogs: dialogs)

        XCTAssertEqual(fake.landCalls.count, 1, "the engine's landWorkspace must actually be called — this is the bug that must never regress")
        XCTAssertNil(fake.landCalls.first?.message, "a nil LandDecision message stays nil — never coerced to a blank flag value the CLI would reject")
        XCTAssertTrue(spy.closedIDs.contains(wsSessionID))
        XCTAssertFalse(store.workspaces.contains { $0.id == wsRow.id })
    }

    // MARK: - 68

    func test68_reviewAndLandWorkspaceCancelDoesNotLand() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let wsRow = await makeLandableWorkspace(store: store, fake: fake)

        let dialogs = FakeDialogs()
        dialogs.nextLandDecision = .cancel

        await store.reviewAndLandWorkspace(wsRow.id, dialogs: dialogs)

        XCTAssertTrue(fake.landCalls.isEmpty)
        XCTAssertTrue(spy.closedIDs.isEmpty)
        XCTAssertTrue(store.workspaces.contains { $0.id == wsRow.id })
    }

    // MARK: - 69

    /// Pins the entire point of this change: when the preview says no
    /// message is needed, the dialog must not even be ASKED for one — this
    /// asserts the preview `Dialogs.confirmLand` actually received carries
    /// `needsMessage == false`, and that a land can still complete with a
    /// nil message despite there having been no field to fill in at all.
    func test69_reviewAndLandWorkspaceNeedsMessageFalsePassesThatThroughToTheDialog() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let wsRow = await makeLandableWorkspace(store: store, fake: fake)

        fake.nextPreviewResult = .success(
            LandPreview(bookmark: "main", bookmarkCommit: "efdd547", commits: [LandCommit(id: "abc", subject: "do a thing")], conflicts: [], needsMessage: false, diverging: [])
        )
        let dialogs = FakeDialogs()
        dialogs.nextLandDecision = .land(message: nil)
        fake.nextLandResult = .success(LandResult(commitID: "abc123", bookmark: "main"))

        await store.reviewAndLandWorkspace(wsRow.id, dialogs: dialogs)

        XCTAssertEqual(dialogs.confirmLandCalls.count, 1)
        XCTAssertEqual(dialogs.confirmLandCalls.first?.preview.needsMessage, false)
        XCTAssertNil(fake.landCalls.first?.message, "needsMessage false means no field was shown, so nothing to send — and nil, not \"\", is what omits the flag")
    }

    // MARK: - 70

    /// A `noTrunk` failure from the PREVIEW (not from `landWorkspace`
    /// itself) must feed the same `pendingTrunkBootstrap` recovery path —
    /// see `reviewAndLandWorkspace`'s doc comment for why its `message` is
    /// always empty in this case (there's no dialog to have sourced one
    /// from yet). The retry itself — RootView's "Create" button — calls
    /// `landWorkspace` directly with `createTrunk` set, exactly as it did
    /// before this change; this test drives that same call to confirm nothing
    /// about the retry path broke.
    func test70_noTrunkFromPreviewSetsPendingTrunkBootstrapAndTheExistingRetryStillLands() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let wsRow = await makeLandableWorkspace(store: store, fake: fake)

        fake.nextPreviewResult = .failure(.noTrunk("no main/master/trunk bookmark exists"))
        let dialogs = FakeDialogs()

        await store.reviewAndLandWorkspace(wsRow.id, dialogs: dialogs)

        XCTAssertTrue(dialogs.confirmLandCalls.isEmpty, "no preview means there's nothing for confirmLand to show")
        XCTAssertNil(store.lastError, "noTrunk is recoverable via pendingTrunkBootstrap, not a dead-end lastError")
        XCTAssertEqual(store.pendingTrunkBootstrap?.workspaceID, wsRow.id)
        // nil, not "": the preview failed before any dialog ran, so no
        // message was ever collected — and the retry must not send a blank
        // --message the CLI would reject as missing.
        XCTAssertNil(store.pendingTrunkBootstrap?.message)

        // The retry: RootView's "Create" button calls landWorkspace directly.
        fake.nextLandResult = .success(LandResult(commitID: "def456", bookmark: "main"))
        let landed = await store.landWorkspace(wsRow.id, message: store.pendingTrunkBootstrap!.message, createTrunk: "main")

        XCTAssertTrue(landed)
        XCTAssertEqual(fake.landCalls.last?.createTrunk, "main")
        // Teardown itself is already thoroughly covered by test33a/test36 —
        // this test's own focus is the bootstrap hand-off (pendingTrunkBootstrap's
        // empty message flowing correctly into the retry call), so a light
        // touch here is enough to confirm the retry actually completed.
        XCTAssertFalse(store.workspaces.contains { $0.id == wsRow.id })
        XCTAssertFalse(spy.closedIDs.isEmpty)
    }

    // MARK: - 71

    func test71_nothingToLandFromPreviewSurfacesAsLastErrorWithoutTeardown() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let wsRow = await makeLandableWorkspace(store: store, fake: fake)
        let sessionsBefore = store.sessions
        let workspacesBefore = store.workspaces

        fake.nextPreviewResult = .failure(.nothingToLand("workspace has no changes to land"))
        let dialogs = FakeDialogs()

        await store.reviewAndLandWorkspace(wsRow.id, dialogs: dialogs)

        XCTAssertEqual(store.lastError, "workspace has no changes to land")
        XCTAssertTrue(spy.closedIDs.isEmpty)
        XCTAssertEqual(store.sessions, sessionsBefore)
        XCTAssertEqual(store.workspaces, workspacesBefore)
    }

    // MARK: - 72

    func test72_sharedHistoryFromPreviewSurfacesAsLastErrorWithoutTeardown() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let wsRow = await makeLandableWorkspace(store: store, fake: fake)
        let sessionsBefore = store.sessions
        let workspacesBefore = store.workspaces

        fake.nextPreviewResult = .failure(.sharedHistory("workspace shares history with another workspace"))
        let dialogs = FakeDialogs()

        await store.reviewAndLandWorkspace(wsRow.id, dialogs: dialogs)

        XCTAssertEqual(store.lastError, "workspace shares history with another workspace")
        XCTAssertTrue(spy.closedIDs.isEmpty)
        XCTAssertEqual(store.sessions, sessionsBefore)
        XCTAssertEqual(store.workspaces, workspacesBefore)
    }

    // MARK: - 73

    func test73_divergingPreviewOffersRebaseAndConfirmingCallsEngine() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let wsRow = await makeLandableWorkspace(store: store, fake: fake)

        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "main", bookmarkCommit: "efdd547",
                commits: [LandCommit(id: "abc", subject: "do a thing")],
                conflicts: [], needsMessage: false,
                diverging: [LandCommit(id: "def", subject: "unrelated local work"), LandCommit(id: "ghi", subject: "more local work")]
            )
        )
        let dialogs = FakeDialogs()
        dialogs.nextLandDecision = .land(message: nil)
        dialogs.nextConfirmRebaseOntoTrunk = true
        fake.nextLandResult = .success(LandResult(commitID: "abc123", bookmark: "main"))
        fake.nextRebaseResult = .success(2)

        await store.reviewAndLandWorkspace(wsRow.id, dialogs: dialogs)

        XCTAssertEqual(dialogs.confirmRebaseOntoTrunkCalls.count, 1)
        XCTAssertEqual(dialogs.confirmRebaseOntoTrunkCalls.first?.count, 2)
        XCTAssertEqual(dialogs.confirmRebaseOntoTrunkCalls.first?.bookmark, "main")
        XCTAssertEqual(fake.rebaseOntoTrunkCalls, [wsRow.projectPath])
    }

    // MARK: - 74

    func test74_divergingPreviewDecliningRebaseDoesNotCallEngine() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let wsRow = await makeLandableWorkspace(store: store, fake: fake)

        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "main", bookmarkCommit: "efdd547",
                commits: [LandCommit(id: "abc", subject: "do a thing")],
                conflicts: [], needsMessage: false,
                diverging: [LandCommit(id: "def", subject: "unrelated local work")]
            )
        )
        let dialogs = FakeDialogs()
        dialogs.nextLandDecision = .land(message: nil)
        dialogs.nextConfirmRebaseOntoTrunk = false
        fake.nextLandResult = .success(LandResult(commitID: "abc123", bookmark: "main"))

        await store.reviewAndLandWorkspace(wsRow.id, dialogs: dialogs)

        XCTAssertEqual(dialogs.confirmRebaseOntoTrunkCalls.count, 1, "the offer must still be made")
        XCTAssertTrue(fake.rebaseOntoTrunkCalls.isEmpty, "declining must not call the engine")
    }

    // MARK: - 75

    /// A failed rebase must never retroactively make a successful land look
    /// failed — same asymmetry `landWorkspace`'s own `cleanupWarning`
    /// handling documents for the leftover-directory case (see its doc
    /// comment). Teardown (sessions/rows/selection) already happened as
    /// part of the land succeeding; the rebase is a separate, optional step
    /// the user opted into AFTERWARD.
    func test75_rebaseFailureSetsLastErrorButLandTeardownStaysIntact() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let wsRow = await makeLandableWorkspace(store: store, fake: fake)
        let wsSessionID = store.sessions.first { $0.target == .workspace(projectPath: wsRow.projectPath, name: wsRow.name) }!.id

        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "main", bookmarkCommit: "efdd547",
                commits: [LandCommit(id: "abc", subject: "do a thing")],
                conflicts: [], needsMessage: false,
                diverging: [LandCommit(id: "def", subject: "unrelated local work")]
            )
        )
        let dialogs = FakeDialogs()
        dialogs.nextLandDecision = .land(message: nil)
        dialogs.nextConfirmRebaseOntoTrunk = true
        fake.nextLandResult = .success(LandResult(commitID: "abc123", bookmark: "main"))
        fake.nextRebaseResult = .failure(.rebaseConflict("rebase hit a conflict"))

        await store.reviewAndLandWorkspace(wsRow.id, dialogs: dialogs)

        XCTAssertEqual(store.lastError, "rebase hit a conflict")
        XCTAssertTrue(spy.closedIDs.contains(wsSessionID), "the land's own teardown must still have happened")
        XCTAssertFalse(store.sessions.contains { $0.id == wsSessionID })
        XCTAssertFalse(store.workspaces.contains { $0.id == wsRow.id }, "the land itself must still read as successful")
    }

    // MARK: - 76

    /// This is the headline win of the whole design: an agent that never
    /// installed `hooks/agents-status.sh` — the common case for anyone who
    /// isn't a clone of this repo — still lights up the sidebar, purely off
    /// a free-text OSC notification classified by `AttentionClassifier`.
    func test76_freeTextNotificationViaOnSessionSignalRaisesAnIndicatorWithNoHookInvolved() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!

        spy.onSessionSignal?(session.id, .notification(title: "Claude Code", body: "Claude needs your permission to use Bash"))

        XCTAssertEqual(
            store.attention[session.id]?.activity, .blocked,
            "a permission-prompt notification from an agent with no hook installed must still raise the red indicator — otherwise the entire point of this stage (lighting up agents that never ran the hook) silently doesn't work"
        )
    }

    // MARK: - 77

    func test77_freeTextNotificationForUnknownSessionIsIgnored() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")

        spy.onSessionSignal?("not-a-real-id", .notification(title: "Claude Code", body: "Claude is waiting for your input"))

        XCTAssertTrue(
            store.attention.isEmpty,
            "a notification racing a session's own teardown must be a harmless no-op, not a phantom entry keyed on an id nothing in the sidebar can ever look up again"
        )
    }

    // MARK: - 78

    func test78_blockedSessionCountCountsAClassifiedBlockJustLikeAHookBlock() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!

        spy.onSessionSignal?(session.id, .notification(title: "Claude Code", body: "Claude needs your permission to use Bash"))

        XCTAssertEqual(
            store.blockedSessionCount, 1,
            "the Dock badge must count a session blocked by classification exactly the same as one blocked by the hook — a badge that only reacts to the hook path would undercount for every agent that doesn't have it installed"
        )
    }
}
