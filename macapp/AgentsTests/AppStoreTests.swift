import XCTest
@testable import Agents

/// The pane id used wherever a test drives `store.apply` directly and only
/// cares about session-level behavior: one shared id keeps every such test
/// on a single reduction stream per session (matching a real single-pane
/// session), and sharing it ACROSS sessions is harmless because pane states
/// are keyed session-first. Tests about multi-pane folding pass their own
/// explicit pane ids instead — see the 51b section.
private let testPane = UUID()

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

    // The upgrade path for existing users: an older v2 state.json omits
    // `customName`, `agentTitle`, and `resume`. Decoding must treat them as
    // nil rather than throwing — a throw would move the file aside as
    // "corrupt" and silently wipe the user's projects/sessions on the very
    // first launch after the update.
    func test21b_oldV2JSONWithoutOptionalSessionMetadataDecodesItAsNil() throws {
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
        XCTAssertNil(session.resume)
        // With neither present the display name falls back to the auto label.
        XCTAssertEqual(session.displayName, "Session 1")
        XCTAssertNil(session.subtitle)
    }

    // MARK: - 21c

    // The narrower upgrade path this refactor itself introduces: a v2
    // state.json written by the pre-refactor app carries the row's resume
    // metadata under the old key `ompResume`, with no `agent` field (every
    // session that key could ever describe was necessarily OMP's, the only
    // harness that spoke the protocol at the time). Decoding must recover
    // that as `agent == "omp"`, and every subsequent save must persist it
    // under the new `resume` key (with `agent`) and drop `ompResume`
    // entirely — never write both, and never keep writing the old key.
    func test21c_legacyOmpResumeKeyDecodesAsOmpAgentAndSavesUnderNewKey() throws {
        let url = TestSupport.freshStateURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let legacyResumeJSON = """
        {"version":2,"projects":["/tmp/proj-A"],"sessions":[{"id":"s-1","target":{"root":{"projectPath":"/tmp/proj-A"}},"name":"Session 1","ompResume":{"sessionID":"omp-9","title":"Old task","prompt":"P"}}],"workspaces":[],"selection":"s-1"}
        """
        try Data(legacyResumeJSON.utf8).write(to: url)

        let spy = SpyTerminals()
        let store = AppStore(terminals: spy, stateURL: url)

        let expected = SessionResumeMetadata(agent: "omp", sessionID: "omp-9", title: "Old task", prompt: "P")
        XCTAssertEqual(
            store.sessions.first { $0.id == "s-1" }?.resume, expected,
            "a legacy ompResume payload has no agent field because it predates the concept — every row it could describe ran OMP, so decoding must fill that in rather than leaving the row unresumable"
        )

        // Trigger a save (renameSession always saves) and confirm the
        // on-disk shape has fully migrated: new key present with an agent,
        // old key gone for good.
        store.renameSession("s-1", to: "Renamed")

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"resume\""), "a fresh save must write the resume key: \(raw)")
        XCTAssertTrue(raw.contains("\"agent\":\"omp\""), "a fresh save must persist which harness this snapshot belongs to: \(raw)")
        XCTAssertFalse(raw.contains("\"ompResume\""), "a fresh save must never re-write the retired key, or every future load would keep needing this same migration: \(raw)")

        let restored = AppStore(terminals: SpyTerminals(), stateURL: url, engine: FakeWorkspaceEngine())
        XCTAssertEqual(restored.sessions.first { $0.id == "s-1" }?.resume, expected)
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

    // MARK: - 26: close without adding

    /// Builds one workspace ready for the close flow, with NO live session on
    /// the project root: `addProject(path:)` creates a root "Session 1", but
    /// a live root session is exactly the condition that defers automatic
    /// reconciliation (see `hasLiveRootSessions(in:)`), and most close-flow
    /// tests are about the reconcile-immediately path. Callers that want the
    /// deferred path re-add a root session themselves after calling this.
    private func makeClosableWorkspace(
        store: AppStore,
        fake: FakeWorkspaceEngine,
        path: String = "/tmp/proj-A"
    ) async -> WorkspaceRow {
        store.addProject(path: path)
        let workspace = WorkspaceRow(
            projectPath: path,
            name: "ws-a",
            path: "/tmp/workspaces/ws-a",
            label: nil
        )
        fake.nextCreateResult = .success(workspace)
        await store.createWorkspace(in: path)
        if let rootSession = store.sessions.first(where: { $0.target == .root(projectPath: path) }) {
            store.closeSession(rootSession.id)
        }
        return workspace
    }

    func test26_closeWithoutAddingForgetFailurePreservesAllLiveAndPersistedState() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, stateURL) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        // The helper already closed the project's default root session; that
        // is setup noise, not something this test is about, so it's carried
        // forward as a baseline rather than asserted away.
        let closedIDsAfterSetup = spy.closedIDs
        let sessionID = store.sessions.first {
            $0.target == .workspace(projectPath: workspace.projectPath, name: workspace.name)
        }!.id
        fake.nextPreviewResult = .failure(.nothingToLand("nothing to add"))
        await store.prepareCloseWorkspace(workspace.id)
        fake.nextDeleteResult = .failure(.failed("forget failed"))

        let sessionsBefore = store.sessions
        let workspacesBefore = store.workspaces
        let selectionBefore = store.selection
        let persistedBefore = try! Data(contentsOf: stateURL)
        fake.onDeleteWorkspace = {
            XCTAssertEqual(spy.closedIDs, closedIDsAfterSetup)
            XCTAssertEqual(store.sessions, sessionsBefore)
            XCTAssertEqual(store.workspaces, workspacesBefore)
            XCTAssertEqual(store.selection, selectionBefore)
            XCTAssertEqual(try! Data(contentsOf: stateURL), persistedBefore)
        }

        await store.closeWithoutAddingWorkspace()

        XCTAssertEqual(spy.closedIDs, closedIDsAfterSetup)
        XCTAssertEqual(spy.resumeCalls, [Set([sessionID])])
        XCTAssertEqual(store.sessions, sessionsBefore)
        XCTAssertEqual(store.workspaces, workspacesBefore)
        XCTAssertEqual(store.selection, selectionBefore)
        XCTAssertEqual(try! Data(contentsOf: stateURL), persistedBefore)
        XCTAssertTrue(store.sessions.contains { $0.id == sessionID })
        XCTAssertEqual(fake.deleteCalls, [workspace])
        XCTAssertEqual(fake.deleteOnlyIfUnchangedCalls, [true])
        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .failure(
                message: "The workspace couldn't be closed. The workspace remains open. Return to it and try again."
            )
        )

        let restored = AppStore(
            terminals: SpyTerminals(),
            stateURL: stateURL,
            engine: FakeWorkspaceEngine()
        )
        XCTAssertEqual(restored.sessions, sessionsBefore)
        XCTAssertEqual(restored.workspaces, workspacesBefore)
        XCTAssertEqual(restored.selection, selectionBefore)
    }

    func test26b_closeWithoutAddingTearsDownOnlyAfterForgetThenPersists() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, stateURL) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        // The helper already closed the project's default root session; that
        // is setup noise, not something this test is about, so it's carried
        // forward as a baseline rather than asserted away.
        let closedIDsAfterSetup = spy.closedIDs
        let sessionID = store.sessions.first {
            $0.target == .workspace(projectPath: workspace.projectPath, name: workspace.name)
        }!.id
        fake.nextPreviewResult = .failure(.nothingToLand("nothing to add"))
        await store.prepareCloseWorkspace(workspace.id)

        let sessionsBefore = store.sessions
        let workspacesBefore = store.workspaces
        let selectionBefore = store.selection
        let persistedBefore = try! Data(contentsOf: stateURL)
        var events: [String] = []
        spy.quiesceSessionsHandler = { ids in
            events.append("terminal-quiesce")
            XCTAssertEqual(ids, Set([sessionID]))
        }
        fake.onDeleteWorkspace = {
            events.append("engine-forget")
            XCTAssertEqual(spy.quiesceCalls, [Set([sessionID])])
            XCTAssertEqual(spy.closedIDs, closedIDsAfterSetup)
            XCTAssertEqual(store.sessions, sessionsBefore)
            XCTAssertEqual(store.workspaces, workspacesBefore)
            XCTAssertEqual(store.selection, selectionBefore)
            XCTAssertEqual(try! Data(contentsOf: stateURL), persistedBefore)
        }
        spy.onCloseSession = { closedID in
            events.append("terminal-close")
            XCTAssertEqual(closedID, sessionID)
            XCTAssertTrue(store.sessions.contains { $0.id == sessionID })
            XCTAssertTrue(store.workspaces.contains { $0.id == workspace.id })
            XCTAssertEqual(store.selection, selectionBefore)
            XCTAssertEqual(try! Data(contentsOf: stateURL), persistedBefore)
        }

        await store.closeWithoutAddingWorkspace()

        XCTAssertEqual(events, ["terminal-quiesce", "engine-forget", "terminal-close"])
        XCTAssertEqual(spy.closedIDs, closedIDsAfterSetup + [sessionID])
        XCTAssertFalse(store.sessions.contains { $0.id == sessionID })
        XCTAssertFalse(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertNil(store.selection)
        XCTAssertEqual(store.closeWorkspace?.phase, .success(addedChanges: 0, notice: nil))

        let restored = AppStore(
            terminals: SpyTerminals(),
            stateURL: stateURL,
            engine: FakeWorkspaceEngine()
        )
        XCTAssertFalse(restored.sessions.contains { $0.id == sessionID })
        XCTAssertFalse(restored.workspaces.contains { $0.id == workspace.id })
        XCTAssertNil(restored.selection)
    }

    func test26c_closeWithoutAddingCleanupWarningIsSuccessfulAndNotRetryable() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        // The helper already closed the project's default root session; that
        // is setup noise, not something this test is about, so it's carried
        // forward as a baseline rather than asserted away.
        let closedIDsAfterSetup = spy.closedIDs
        let sessionID = store.sessions.first {
            $0.target == .workspace(projectPath: workspace.projectPath, name: workspace.name)
        }!.id
        fake.nextPreviewResult = .failure(.nothingToLand("nothing to add"))
        await store.prepareCloseWorkspace(workspace.id)
        fake.nextDeleteResult = .success(
            DeleteResult(cleanupWarning: "The closed workspace folder remains on disk.")
        )

        await store.closeWithoutAddingWorkspace()

        XCTAssertEqual(spy.closedIDs, closedIDsAfterSetup + [sessionID])
        XCTAssertFalse(store.sessions.contains { $0.id == sessionID })
        XCTAssertFalse(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .success(
                addedChanges: 0,
                notice: "The closed workspace folder remains on disk."
            )
        )
    }

    func test27_changedWorkspaceRequiresInSheetConfirmationBeforeClosingWithoutAdding() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "ignored",
                bookmarkCommit: "ignored",
                commits: [LandCommit(id: "1", subject: "A useful change")],
                conflicts: [],
                needsMessage: false
            )
        )
        await store.prepareCloseWorkspace(workspace.id)

        await store.closeWithoutAddingWorkspace()
        XCTAssertTrue(fake.deleteCalls.isEmpty)

        store.requestCloseWithoutAdding()
        guard case .confirmCloseWithoutAdding(let returnTo)? = store.closeWorkspace?.phase else {
            return XCTFail("expected destructive confirmation state")
        }
        XCTAssertEqual(returnTo, .ready(changes: ["A useful change"]))

        await store.closeWithoutAddingWorkspace()
        XCTAssertEqual(fake.deleteCalls, [workspace])
        XCTAssertFalse(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertEqual(store.closeWorkspace?.phase, .success(addedChanges: 0, notice: nil))
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

    // MARK: - 33: unified close flow

    func test33_cleanAddClosesWorkspaceThenAutomaticallyReconcilesProject() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        // The helper already closed the project's default root session; that
        // is setup noise, not something this test is about, so it's carried
        // forward as a baseline rather than asserted away.
        let closedIDsAfterSetup = spy.closedIDs
        let workspaceSessionIDs = store.sessions.filter {
            $0.target == .workspace(projectPath: workspace.projectPath, name: workspace.name)
        }.map(\.id)
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "ignored",
                bookmarkCommit: "ignored",
                commits: [
                    LandCommit(id: "1", subject: "First change"),
                    LandCommit(id: "2", subject: "Second change"),
                ],
                conflicts: [],
                needsMessage: false
            )
        )
        var workspaceWasRemovedBeforeReconciliation = false
        fake.onRebaseOntoTrunk = {
            workspaceWasRemovedBeforeReconciliation = !store.workspaces.contains {
                $0.id == workspace.id
            }
        }

        await store.prepareCloseWorkspace(workspace.id)
        await store.addChangesAndCloseWorkspace()

        XCTAssertEqual(fake.landCalls.count, 1)
        XCTAssertNil(fake.landCalls.first?.message)
        XCTAssertEqual(fake.rebaseOntoTrunkCalls, [workspace.projectPath])
        XCTAssertTrue(workspaceWasRemovedBeforeReconciliation)
        XCTAssertEqual(Set(spy.closedIDs), Set(closedIDsAfterSetup + workspaceSessionIDs))
        XCTAssertFalse(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .success(addedChanges: 2, notice: nil)
        )
    }

    func test34_staleLandTaskTearsDownOldWorkspaceButPreservesNewerSheet() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        // The helper already closed the project's default root session; that
        // is setup noise, not something this test is about, so it's carried
        // forward as a baseline rather than asserted away.
        let closedIDsAfterSetup = spy.closedIDs
        let oldSessionIDs = store.sessions.filter {
            $0.target == .workspace(projectPath: workspace.projectPath, name: workspace.name)
        }.map(\.id)
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "ignored",
                bookmarkCommit: "ignored",
                commits: [LandCommit(id: "1", subject: "Change")],
                conflicts: [],
                needsMessage: false
            )
        )
        await store.prepareCloseWorkspace(workspace.id)
        let newerSheet = CloseWorkspacePresentation(
            workspaceID: UUID().uuidString,
            workspaceName: "newer",
            projectPath: workspace.projectPath,
            projectName: "project",
            phase: .ready(changes: ["Newer change"])
        )
        fake.onLandWorkspace = { store.closeWorkspace = newerSheet }

        await store.addChangesAndCloseWorkspace()

        XCTAssertFalse(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertTrue(oldSessionIDs.allSatisfy { id in !store.sessions.contains { $0.id == id } })
        XCTAssertEqual(Set(spy.closedIDs), Set(closedIDsAfterSetup + oldSessionIDs))
        XCTAssertEqual(fake.rebaseOntoTrunkCalls, [workspace.projectPath])
        XCTAssertEqual(store.closeWorkspace, newerSheet)
    }

    func test34a_landConflictRaceLeavesWorkspaceAndSessionsAndShowsAttention() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        // The helper already closed the project's default root session; that
        // is setup noise, not something this test is about, so it's carried
        // forward as a baseline rather than asserted away.
        let closedIDsAfterSetup = spy.closedIDs
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "ignored",
                bookmarkCommit: "ignored",
                commits: [LandCommit(id: "1", subject: "Change")],
                conflicts: [],
                needsMessage: false
            )
        )
        await store.prepareCloseWorkspace(workspace.id)
        let sessionsBefore = store.sessions
        fake.nextLandResult = .failure(.landConflict("implementation detail"))

        await store.addChangesAndCloseWorkspace()

        XCTAssertEqual(spy.closedIDs, closedIDsAfterSetup)
        XCTAssertEqual(store.sessions, sessionsBefore)
        XCTAssertTrue(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertTrue(fake.rebaseOntoTrunkCalls.isEmpty)
        // The engine left the conflicted rebase in the workspace, so the
        // sheet says that — and shows the engine's own account of it rather
        // than swallowing the detail the user needs to resolve it.
        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .conflictAttention(
                message: AppStore.landConflictMessage,
                details: [],
                engineMessage: "implementation detail"
            )
        )
    }

    /// The engine advanced the trunk but could not deregister the workspace.
    /// The close failed, so its row and sessions stay; only the engine can
    /// describe that half-finished state accurately, so its message is shown
    /// verbatim.
    func test34c_cleanupFailedDuringLandIsAFailureCarryingTheEngineMessage() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        let closedIDsAfterSetup = spy.closedIDs
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "ignored",
                bookmarkCommit: "ignored",
                commits: [LandCommit(id: "1", subject: "Change")],
                conflicts: [],
                needsMessage: false
            )
        )
        await store.prepareCloseWorkspace(workspace.id)
        let sessionsBefore = store.sessions
        let sessionIDs = Set(sessionsBefore.filter {
            $0.target == .workspace(projectPath: workspace.projectPath, name: workspace.name)
        }.map(\.id))
        fake.nextLandResult = .failure(
            .cleanupFailed("The changes were added to main, but the workspace could not be forgotten.")
        )

        await store.addChangesAndCloseWorkspace()

        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .failure(message: "The changes were added to main, but the workspace could not be forgotten.")
        )
        XCTAssertEqual(spy.resumeCalls, [sessionIDs])
        XCTAssertEqual(spy.closedIDs, closedIDsAfterSetup)
        XCTAssertEqual(store.sessions, sessionsBefore)
        XCTAssertTrue(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertTrue(fake.rebaseOntoTrunkCalls.isEmpty)
    }

    func test34b_sharedHistoryDuringLandShowsAttentionWithoutTearingDown() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "ignored",
                bookmarkCommit: "ignored",
                commits: [LandCommit(id: "1", subject: "Change")],
                conflicts: [],
                needsMessage: false
            )
        )
        fake.nextLandResult = .failure(.sharedHistory("raw engine advice"))

        await store.prepareCloseWorkspace(workspace.id)
        let sessionsBefore = store.sessions
        await store.addChangesAndCloseWorkspace()

        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .conflictAttention(
                message: "These changes overlap newer project progress and need attention.",
                details: [],
                engineMessage: nil
            )
        )
        XCTAssertEqual(store.sessions, sessionsBefore)
        XCTAssertTrue(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertTrue(fake.rebaseOntoTrunkCalls.isEmpty)
    }

    func test35_requiredSummaryMustBeNonemptyBeforeLand() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "ignored",
                bookmarkCommit: "ignored",
                commits: [LandCommit(id: "1", subject: "")],
                conflicts: [],
                needsMessage: true
            )
        )
        await store.prepareCloseWorkspace(workspace.id)

        store.setCloseWorkspaceSummary("   ")
        await store.addChangesAndCloseWorkspace()
        XCTAssertTrue(fake.landCalls.isEmpty)
        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .summaryRequired(changes: ["Undescribed change"])
        )

        store.setCloseWorkspaceSummary("Describe the change")
        await store.addChangesAndCloseWorkspace()
        XCTAssertEqual(fake.landCalls.first?.message, "Describe the change")
    }

    func test36_projectSetupWithDescribedChangesNeedsNoSummaryAndLandsWithCreateTrunk() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.previewResults = [
            .failure(.noTrunk("storage-specific message")),
            .success(
                LandPreview(
                    bookmark: "main",
                    bookmarkCommit: "",
                    commits: [LandCommit(id: "abc", subject: "Establish project progress")],
                    conflicts: [],
                    needsMessage: false
                )
            )
        ]

        await store.prepareCloseWorkspace(workspace.id)
        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .projectSetupRequired(changes: ["Establish project progress"], needsMessage: false)
        )
        XCTAssertEqual(fake.previewLandCalls.map(\.createTrunk), [nil, "main"])

        fake.nextLandResult = .success(LandResult(commitID: "abc", bookmark: "main"))
        await store.setUpProjectAndCloseWorkspace()

        XCTAssertNil(fake.landCalls.last?.message)
        XCTAssertEqual(fake.landCalls.last?.createTrunk, "main")
        XCTAssertEqual(fake.rebaseOntoTrunkCalls, [workspace.projectPath])
        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .success(addedChanges: 1, notice: nil)
        )
        XCTAssertFalse(store.workspaces.contains { $0.id == workspace.id })
    }

    func test36b_projectSetupWithUndescribedChangesRequiresAndForwardsSummary() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.previewResults = [
            .failure(.noTrunk("storage-specific message")),
            .success(
                LandPreview(
                    bookmark: "main",
                    bookmarkCommit: "",
                    commits: [LandCommit(id: "dirty", subject: "")],
                    conflicts: [],
                    needsMessage: true
                )
            )
        ]

        await store.prepareCloseWorkspace(workspace.id)
        let setupPhase = CloseWorkspacePhase.projectSetupRequired(
            changes: ["Undescribed change"],
            needsMessage: true
        )
        XCTAssertEqual(store.closeWorkspace?.phase, setupPhase)

        store.setCloseWorkspaceSummary(" \n ")
        await store.setUpProjectAndCloseWorkspace()
        XCTAssertTrue(fake.landCalls.isEmpty)
        XCTAssertEqual(store.closeWorkspace?.phase, setupPhase)

        store.setCloseWorkspaceSummary("  Establish project progress  ")
        await store.setUpProjectAndCloseWorkspace()
        XCTAssertEqual(fake.landCalls.last?.message, "Establish project progress")
        XCTAssertEqual(fake.landCalls.last?.createTrunk, "main")
    }

    func test36c_emptyProjectSetupPreviewBecomesNoChanges() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.previewResults = [
            .failure(.noTrunk("storage-specific message")),
            .success(
                LandPreview(
                    bookmark: "main",
                    bookmarkCommit: "",
                    commits: [],
                    conflicts: [],
                    needsMessage: false
                )
            )
        ]

        await store.prepareCloseWorkspace(workspace.id)

        XCTAssertEqual(store.closeWorkspace?.phase, .noChanges)
        XCTAssertTrue(fake.landCalls.isEmpty)
    }

    func test36d_projectSetupPreviewOverlapIsFriendlyAndNonmutating() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        let workspacesBefore = store.workspaces
        let sessionsBefore = store.sessions
        fake.previewResults = [
            .failure(.noTrunk("storage-specific message")),
            .failure(.landConflict("raw storage overlap"))
        ]

        await store.prepareCloseWorkspace(workspace.id)

        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .conflictAttention(
                message: "These changes overlap newer project progress and need attention.",
                details: [],
                engineMessage: nil
            )
        )
        XCTAssertEqual(store.workspaces, workspacesBefore)
        XCTAssertEqual(store.sessions, sessionsBefore)
        XCTAssertTrue(fake.landCalls.isEmpty)
        XCTAssertTrue(fake.deleteCalls.isEmpty)
    }

    func test36e_noTrunkRacePreservesPreparedSummariesAndSummaryRequirement() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "main",
                bookmarkCommit: "head",
                commits: [LandCommit(id: "1", subject: "Reviewed change")],
                conflicts: [],
                needsMessage: false
            )
        )
        await store.prepareCloseWorkspace(workspace.id)
        fake.nextLandResult = .failure(.noTrunk("trunk disappeared"))

        await store.addChangesAndCloseWorkspace()

        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .projectSetupRequired(changes: ["Reviewed change"], needsMessage: false)
        )
        XCTAssertTrue(store.workspaces.contains { $0.id == workspace.id })
    }

    func test36e2_noTrunkRacePreservesUndescribedSummaryRequirement() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "main",
                bookmarkCommit: "head",
                commits: [LandCommit(id: "dirty", subject: "")],
                conflicts: [],
                needsMessage: true
            )
        )
        await store.prepareCloseWorkspace(workspace.id)
        store.setCloseWorkspaceSummary("Describe dirty work")
        fake.nextLandResult = .failure(.noTrunk("trunk disappeared"))

        await store.addChangesAndCloseWorkspace()

        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .projectSetupRequired(changes: ["Undescribed change"], needsMessage: true)
        )
        XCTAssertEqual(store.closeWorkspace?.summary, "Describe dirty work")
        XCTAssertTrue(store.workspaces.contains { $0.id == workspace.id })
    }

    func test36e3_repeatedNoTrunkPreviewFailsFriendlyWithoutMutation() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        let workspacesBefore = store.workspaces
        let sessionsBefore = store.sessions
        fake.previewResults = [
            .failure(.noTrunk("first raw detail")),
            .failure(.noTrunk("second raw detail"))
        ]

        await store.prepareCloseWorkspace(workspace.id)

        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .failure(
                message: "The project's starting changes couldn't be prepared. Return to the workspace and try again."
            )
        )
        XCTAssertEqual(store.workspaces, workspacesBefore)
        XCTAssertEqual(store.sessions, sessionsBefore)
        XCTAssertTrue(fake.landCalls.isEmpty)
        XCTAssertTrue(fake.deleteCalls.isEmpty)
    }

    func test36e4_setupRetryChecksPresentationIdentityAtBothAwaitBoundaries() async {
        do {
            let fake = FakeWorkspaceEngine()
            let (store, _, _) = TestSupport.makeStore(engine: fake)
            let workspace = await makeClosableWorkspace(store: store, fake: fake)
            fake.previewResults = [
                .failure(.noTrunk("no trunk")),
                .success(
                    LandPreview(
                        bookmark: "main",
                        bookmarkCommit: "",
                        commits: [LandCommit(id: "1", subject: "Starting change")],
                        conflicts: [],
                        needsMessage: false
                    )
                )
            ]
            fake.onPreviewLand = { callCount in
                if callCount == 1 { store.closeWorkspace = nil }
            }

            await store.prepareCloseWorkspace(workspace.id)

            XCTAssertNil(store.closeWorkspace)
            XCTAssertEqual(fake.previewLandCalls.count, 1)
        }

        do {
            let fake = FakeWorkspaceEngine()
            let (store, _, _) = TestSupport.makeStore(engine: fake)
            let workspace = await makeClosableWorkspace(store: store, fake: fake)
            fake.previewResults = [
                .failure(.noTrunk("no trunk")),
                .failure(.failed("retry failed"))
            ]
            fake.onPreviewLand = { callCount in
                if callCount == 2 { store.closeWorkspace = nil }
            }

            await store.prepareCloseWorkspace(workspace.id)

            XCTAssertNil(store.closeWorkspace)
            XCTAssertEqual(fake.previewLandCalls.count, 2)
        }
    }

    func test36f_projectSetupCanConfirmCancelAndCloseWithoutAdding() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        let sessionID = store.sessions.first {
            $0.target == .workspace(projectPath: workspace.projectPath, name: workspace.name)
        }!.id
        fake.previewResults = [
            .failure(.noTrunk("storage-specific message")),
            .success(
                LandPreview(
                    bookmark: "main",
                    bookmarkCommit: "",
                    commits: [LandCommit(id: "1", subject: "Starting change")],
                    conflicts: [],
                    needsMessage: false
                )
            )
        ]

        await store.prepareCloseWorkspace(workspace.id)
        let setupPhase = CloseWorkspacePhase.projectSetupRequired(
            changes: ["Starting change"],
            needsMessage: false
        )
        XCTAssertEqual(store.closeWorkspace?.phase, setupPhase)

        store.requestCloseWithoutAdding()
        guard case .confirmCloseWithoutAdding(let returnTo)? = store.closeWorkspace?.phase else {
            return XCTFail("expected destructive confirmation state")
        }
        XCTAssertEqual(returnTo, setupPhase)

        store.cancelCloseWithoutAdding()
        XCTAssertEqual(store.closeWorkspace?.phase, setupPhase)

        store.requestCloseWithoutAdding()
        await store.closeWithoutAddingWorkspace()

        XCTAssertTrue(fake.landCalls.isEmpty)
        XCTAssertEqual(fake.deleteCalls, [workspace])
        XCTAssertTrue(spy.closedIDs.contains(sessionID))
        XCTAssertFalse(store.sessions.contains { $0.id == sessionID })
        XCTAssertFalse(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertEqual(store.closeWorkspace?.phase, .success(addedChanges: 0, notice: nil))
    }

    func test37_nothingToLandBecomesCloseOnlyAndClosesWithoutAnotherConfirmation() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .failure(.nothingToLand("nothing"))

        await store.prepareCloseWorkspace(workspace.id)
        XCTAssertEqual(store.closeWorkspace?.phase, .noChanges)

        await store.closeWithoutAddingWorkspace()
        XCTAssertEqual(fake.deleteCalls, [workspace])
        XCTAssertEqual(store.closeWorkspace?.phase, .success(addedChanges: 0, notice: nil))
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

        store.apply(.structured(.set(.blocked)), toSession: session.id, pane: testPane)

        XCTAssertEqual(store.attention[session.id]?.activity, .blocked)
    }

    // MARK: - 46

    func test46_applyStructuredClearClearsActivityButLeavesTheLatchedEntry() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!
        store.apply(.structured(.set(.yourTurn)), toSession: session.id, pane: testPane)

        store.apply(.structured(.clear), toSession: session.id, pane: testPane)

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

        store.apply(.structured(.set(.blocked)), toSession: "not-a-real-id", pane: testPane)

        XCTAssertTrue(store.attention.isEmpty)
    }

    // MARK: - 48

    func test48_closingSessionDropsItsAttentionEntry() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!
        store.apply(.structured(.set(.blocked)), toSession: session.id, pane: testPane)

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
            store.apply(.structured(.set(.yourTurn)), toSession: session.id, pane: testPane)
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
        store1.apply(.structured(.set(.blocked)), toSession: session.id, pane: testPane)
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

        spy.emitSignal(session.id, .structured(.set(.blocked)))

        XCTAssertEqual(store.attention[session.id]?.activity, .blocked)
    }

    // MARK: - 51b: per-pane attention aggregation

    func test51b_onePaneClearingMustNotEraseAnotherPanesBlockedState() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!
        let paneA = UUID()
        let paneB = UUID()

        spy.emitSignal(session.id, pane: paneA, .structured(.set(.blocked)))
        spy.emitSignal(session.id, pane: paneB, .structured(.set(.yourTurn)))
        spy.emitSignal(session.id, pane: paneB, .structured(.clear))

        XCTAssertEqual(
            store.attention[session.id]?.activity, .blocked,
            "pane B finishing must not clear the row while pane A's agent is still blocked — the fold is a severity max over panes, and a last-writer-wins session state here would hide an agent actively burning the user's time"
        )
    }

    func test51b_structuredLatchIsPerPane_notSessionWide() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!
        let hooked = UUID()
        let hookless = UUID()

        spy.emitSignal(session.id, pane: hooked, .structured(.clear))
        spy.emitSignal(session.id, pane: hookless, .bell)

        XCTAssertEqual(
            store.attention[session.id]?.activity, .yourTurn,
            "one pane speaking the structured protocol must not latch its SIBLINGS out of the classifier path — the hookless pane's bell is its agent's only voice, and a session-wide latch would silence it"
        )
    }

    func test51b_closedPanesContributionIsDropped() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!
        let paneA = UUID()
        let paneB = UUID()

        spy.emitSignal(session.id, pane: paneA, .structured(.set(.blocked)))
        spy.emitSignal(session.id, pane: paneB, .structured(.set(.yourTurn)))
        spy.emitPaneClosed(session.id, pane: paneA)

        XCTAssertEqual(
            store.attention[session.id]?.activity, .yourTurn,
            "a closed pane's state must leave the fold — a pane that exits while blocked would otherwise keep the row red forever, with no live process behind the indicator"
        )

        spy.emitPaneClosed(session.id, pane: paneB)
        XCTAssertNil(
            store.attention[session.id]?.activity,
            "with every contributing pane closed nothing is waiting on the user — the indicator must go dark"
        )
    }

    // MARK: - 52

    func test52_onTitleChangeBecomesTheDisplayName() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!

        spy.emitTitle(session.id, "building the widget")

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
            store.apply(.structured(.set(.yourTurn)), toSession: session.id, pane: testPane)
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
        store.apply(.structured(.set(.blocked)), toSession: sessions[0].id, pane: testPane)
        store.apply(.structured(.set(.yourTurn)), toSession: sessions[1].id, pane: testPane)
        store.apply(.structured(.set(.blocked)), toSession: sessions[2].id, pane: testPane)

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
            store.apply(.structured(.set(.blocked)), toSession: session.id, pane: testPane)
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
        store.apply(.structured(.set(.blocked)), toSession: sessions[0].id, pane: testPane)
        store.apply(.structured(.set(.blocked)), toSession: sessions[1].id, pane: testPane)
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

    // MARK: - 67: close state edge cases

    func test67_knownConflictShowsDetailsAndNeverOffersAddOperation() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "ignored",
                bookmarkCommit: "ignored",
                commits: [LandCommit(id: "1", subject: "Change")],
                conflicts: [LandCommit(id: "Sources/App.swift", subject: "Sources/App.swift")],
                needsMessage: false
            )
        )

        await store.prepareCloseWorkspace(workspace.id)

        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .conflictAttention(
                message: "These changes overlap newer project progress and need attention.",
                details: ["Sources/App.swift"],
                engineMessage: nil
            )
        )
        await store.addChangesAndCloseWorkspace()
        XCTAssertTrue(fake.landCalls.isEmpty)
    }

    func test68_cancelDismissesPreparedFlowAndSecondFlowCannotReplaceActiveSheet() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let first = await makeClosableWorkspace(store: store, fake: fake)
        let second = WorkspaceRow(
            projectPath: first.projectPath,
            name: "ws-b",
            path: "/tmp/workspaces/ws-b",
            label: nil
        )
        fake.nextCreateResult = .success(second)
        await store.createWorkspace(in: first.projectPath)
        fake.nextPreviewResult = .failure(.nothingToLand("nothing"))

        await store.prepareCloseWorkspace(first.id)
        await store.prepareCloseWorkspace(second.id)

        XCTAssertEqual(store.closeWorkspace?.workspaceID, first.id)
        XCTAssertEqual(fake.previewLandCalls.map(\.workspace), [first])

        store.cancelCloseWorkspace()
        XCTAssertNil(store.closeWorkspace)
        XCTAssertTrue(fake.landCalls.isEmpty)
        XCTAssertTrue(fake.deleteCalls.isEmpty)
    }

    func test69_reconciliationConflictIsNonfatalAttentionAfterSuccessfulClose() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        let sessionID = store.sessions.first {
            $0.target == .workspace(projectPath: workspace.projectPath, name: workspace.name)
        }!.id
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "ignored",
                bookmarkCommit: "ignored",
                commits: [LandCommit(id: "1", subject: "Change")],
                conflicts: [],
                needsMessage: false
            )
        )
        fake.nextRebaseResult = .failure(.rebaseConflict("root overlap"))

        await store.prepareCloseWorkspace(workspace.id)
        await store.addChangesAndCloseWorkspace()

        XCTAssertTrue(spy.closedIDs.contains(sessionID))
        XCTAssertFalse(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertEqual(fake.rebaseOntoTrunkCalls, [workspace.projectPath])
        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .projectAttention(addedChanges: 1, notice: nil)
        )
        XCTAssertNil(store.lastError)
        XCTAssertTrue(store.projectWorkingCopyAttention.contains(workspace.projectPath))

        store.cancelCloseWorkspace()

        XCTAssertNil(store.closeWorkspace)
        XCTAssertTrue(
            store.projectWorkingCopyAttention.contains(workspace.projectPath),
            "dismissing the close sheet must not clear project working-copy attention"
        )
    }

    func test69b_manualReconciliationRetryStaysFlaggedUntilItSucceeds() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "ignored",
                bookmarkCommit: "ignored",
                commits: [LandCommit(id: "1", subject: "Change")],
                conflicts: [],
                needsMessage: false
            )
        )
        fake.nextRebaseResult = .failure(.rebaseConflict("root overlap"))
        await store.prepareCloseWorkspace(workspace.id)
        await store.addChangesAndCloseWorkspace()
        store.cancelCloseWorkspace()
        XCTAssertTrue(store.projectWorkingCopyAttention.contains(workspace.projectPath))

        fake.nextRebaseResult = .failure(.rebaseConflict("still overlapping"))
        await store.refreshProjectWorkspace(workspace.projectPath)

        XCTAssertEqual(
            fake.rebaseOntoTrunkCalls,
            [workspace.projectPath, workspace.projectPath]
        )
        XCTAssertTrue(
            store.projectWorkingCopyAttention.contains(workspace.projectPath),
            "a failed manual retry must keep project attention set"
        )

        fake.nextRebaseResult = .success(0)
        await store.refreshProjectWorkspace(workspace.projectPath)

        XCTAssertEqual(
            fake.rebaseOntoTrunkCalls,
            [workspace.projectPath, workspace.projectPath, workspace.projectPath]
        )
        XCTAssertFalse(
            store.projectWorkingCopyAttention.contains(workspace.projectPath),
            "a successful manual retry must clear project attention"
        )
    }

    func test70_cleanupWarningRemainsSuccessfulCloseFollowUp() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "ignored",
                bookmarkCommit: "ignored",
                commits: [LandCommit(id: "1", subject: "Change")],
                conflicts: [],
                needsMessage: false
            )
        )
        fake.nextLandResult = .success(
            LandResult(
                commitID: "abc",
                bookmark: "ignored",
                cleanupWarning: "The workspace folder remains on disk."
            )
        )

        await store.prepareCloseWorkspace(workspace.id)
        await store.addChangesAndCloseWorkspace()

        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .success(
                addedChanges: 1,
                notice: "The workspace folder remains on disk."
            )
        )
        XCTAssertFalse(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertNil(store.lastError)
    }

    /// A successful land always means the engine deregistered the workspace,
    /// so the teardown is unconditional — a cleanup warning rides along as a
    /// notice and must not hold the row, its sessions, or its persisted state
    /// open.
    func test70b_successfulLandAlwaysTearsDownEvenWithACleanupWarning() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, stateURL) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        let sessionID = store.sessions.first {
            $0.target == .workspace(projectPath: workspace.projectPath, name: workspace.name)
        }!.id
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "ignored",
                bookmarkCommit: "ignored",
                commits: [LandCommit(id: "1", subject: "Change")],
                conflicts: [],
                needsMessage: false
            )
        )
        fake.nextLandResult = .success(
            LandResult(
                commitID: "abc",
                bookmark: "ignored",
                cleanupWarning: "The workspace folder couldn't be moved to the Bin."
            )
        )

        await store.prepareCloseWorkspace(workspace.id)
        await store.addChangesAndCloseWorkspace()

        XCTAssertTrue(spy.closedIDs.contains(sessionID))
        XCTAssertFalse(store.sessions.contains { $0.id == sessionID })
        XCTAssertFalse(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .success(
                addedChanges: 1,
                notice: "The workspace folder couldn't be moved to the Bin."
            )
        )

        let restored = AppStore(
            terminals: SpyTerminals(),
            stateURL: stateURL,
            engine: FakeWorkspaceEngine()
        )
        XCTAssertFalse(restored.sessions.contains { $0.id == sessionID })
        XCTAssertFalse(restored.workspaces.contains { $0.id == workspace.id })
    }

    func test71_prepareFailureStaysInSheetWithoutTearingDownWorkspace() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        // The helper already closed the project's default root session; that
        // is setup noise, not something this test is about, so it's carried
        // forward as a baseline rather than asserted away.
        let closedIDsAfterSetup = spy.closedIDs
        fake.nextPreviewResult = .failure(.sharedHistory("Changes cannot be isolated"))
        let sessionsBefore = store.sessions

        await store.prepareCloseWorkspace(workspace.id)

        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .conflictAttention(
                message: "These changes overlap newer project progress and need attention.",
                details: [],
                engineMessage: nil
            )
        )
        XCTAssertEqual(spy.closedIDs, closedIDsAfterSetup)
        XCTAssertEqual(store.sessions, sessionsBefore)
        XCTAssertTrue(store.workspaces.contains { $0.id == workspace.id })
    }

    func test71b_landConflictDuringPrepareShowsFriendlyAttentionWithoutMutation() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        // The helper already closed the project's default root session; that
        // is setup noise, not something this test is about, so it's carried
        // forward as a baseline rather than asserted away.
        let closedIDsAfterSetup = spy.closedIDs
        fake.nextPreviewResult = .failure(.landConflict("conflicted preferred Jujutsu trunk"))
        let sessionsBefore = store.sessions
        let workspacesBefore = store.workspaces

        await store.prepareCloseWorkspace(workspace.id)

        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .conflictAttention(
                message: "These changes overlap newer project progress and need attention.",
                details: [],
                engineMessage: nil
            )
        )
        XCTAssertNil(store.lastError)
        XCTAssertEqual(spy.closedIDs, closedIDsAfterSetup)
        XCTAssertEqual(store.sessions, sessionsBefore)
        XCTAssertEqual(store.workspaces, workspacesBefore)
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

        spy.emitSignal(session.id, .notification(title: "Claude Code", body: "Claude needs your permission to use Bash"))

        XCTAssertEqual(
            store.attention[session.id]?.activity, .blocked,
            "a permission-prompt notification from an agent with no hook installed must still raise the red indicator — otherwise the entire point of this stage (lighting up agents that never ran the hook) silently doesn't work"
        )
    }

    // MARK: - 77

    func test77_freeTextNotificationForUnknownSessionIsIgnored() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")

        spy.emitSignal("not-a-real-id", .notification(title: "Claude Code", body: "Claude is waiting for your input"))

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

        spy.emitSignal(session.id, .notification(title: "Claude Code", body: "Claude needs your permission to use Bash"))

        XCTAssertEqual(
            store.blockedSessionCount, 1,
            "the Dock badge must count a session blocked by classification exactly the same as one blocked by the hook — a badge that only reacts to the hook path would undercount for every agent that doesn't have it installed"
        )
    }

    // MARK: - 79

    func test79_selectingASessionWhoseIndicatorWasRaisedByClassificationClearsIt() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let target = store.sessions.first!
        store.newSession(in: store.projects.first!)
        let other = store.sessions.first { $0.id != target.id }!
        XCTAssertEqual(store.selection, other.id)
        store.setAppActive(true)

        spy.emitSignal(target.id, .notification(title: "Claude Code", body: "Claude is waiting for your input"))
        XCTAssertEqual(store.attention[target.id]?.activity, .yourTurn, "the setup must actually raise the indicator before this test can prove selecting it clears one")

        store.selection = target.id

        XCTAssertNil(
            store.attention[target.id]?.activity,
            "selecting a session whose gold dot came from classifying a free-text notification must clear it — the hook isn't installed here, so 'looked at it' is the only honest signal available that the user has seen it"
        )
    }

    // MARK: - 80

    func test80_selectingASessionWhoseBlockedCameFromTheHookDoesNotClearIt() {
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let target = store.sessions.first!
        store.newSession(in: store.projects.first!)
        let other = store.sessions.first { $0.id != target.id }!
        XCTAssertEqual(store.selection, other.id)
        store.setAppActive(true)

        store.apply(.structured(.set(.blocked)), toSession: target.id, pane: testPane)

        store.selection = target.id

        XCTAssertEqual(
            store.attention[target.id]?.activity, .blocked,
            "selecting a session the hook has reported as genuinely still blocked must not clear the red pulse — going dark while a permission prompt is actually still open would be a lie the user could act on by walking away"
        )
    }

    // MARK: - 81

    func test81_notificationForTheCurrentlyAttendedSessionIsDropped() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!
        store.setAppActive(true)
        XCTAssertEqual(store.attention[session.id]?.isAttended, true)

        spy.emitSignal(session.id, .notification(title: "Claude Code", body: "Claude needs your permission to use Bash"))

        XCTAssertNil(
            store.attention[session.id]?.activity,
            "a notification for the session already on screen must not raise an indicator — there's no later selection change to ever clear it, so a raise here would light the row forever"
        )
    }

    // MARK: - 82

    func test82_notificationForASelectedSessionWithAppNotFrontmostRaises() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!
        // Deliberately never calling setAppActive(true): the session is
        // selected but the user has switched to another app entirely, which
        // is exactly the case they need the indicator for.

        spy.emitSignal(session.id, .notification(title: "Claude Code", body: "Claude is waiting for your input"))

        XCTAssertEqual(
            store.attention[session.id]?.activity, .yourTurn,
            "a notification for a selected session must still raise when the app itself isn't frontmost — this is the case the user actually needs the indicator for, since they're away from the app and can't see the row is selected"
        )
    }

    // MARK: - 83

    /// The regression that matters most in this stage: if the un-attend leg
    /// of `AppStore.updateAttention()` were ever dropped, `isAttended` would
    /// stay true forever after this resign, and `SessionAttention.reduce`
    /// would keep silently swallowing every future notification for this
    /// session as "they're already looking at it" — the row could never
    /// light up again.
    func test83_resigningAppActiveAfterAttendingLetsANotificationRaiseAgain() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let session = store.sessions.first!
        store.setAppActive(true)
        XCTAssertEqual(store.attention[session.id]?.isAttended, true)

        store.setAppActive(false)

        spy.emitSignal(session.id, .notification(title: "Claude Code", body: "Claude is waiting for your input"))

        XCTAssertEqual(
            store.attention[session.id]?.activity, .yourTurn,
            "a notification arriving after the app resigns active must raise, even though this exact session was attended a moment ago — a missing un-attend here would leave isAttended stuck true and silently drop every notification for this session for the rest of its life"
        )
    }

    // MARK: - 84

    func test84_switchingSelectionUnattendsTheOldSessionAndAttendsTheNew() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let sessionA = store.sessions.first!
        store.setAppActive(true)
        XCTAssertEqual(store.attention[sessionA.id]?.isAttended, true)

        // newSession both creates B and selects it, which is the selection
        // change under test — A is no longer `store.selection` afterward.
        store.newSession(in: store.projects.first!)
        XCTAssertNotEqual(store.selection, sessionA.id)

        spy.emitSignal(sessionA.id, .notification(title: "Claude Code", body: "Claude is waiting for your input"))

        XCTAssertEqual(
            store.attention[sessionA.id]?.activity, .yourTurn,
            "moving selection away from A must un-attend it — if A were still marked attended after the switch, this notification would be silently dropped instead of raising"
        )
    }

    // MARK: - 85

    /// cmux (#5095) auto-withdrew attention at a level coarser than the unit
    /// of attention (a whole container, not the one session inside it the
    /// user was actually looking at) and silently ate notifications for a
    /// second, unattended agent sharing that container. This is the same
    /// shape here: two sessions share a project, only one is selected, and
    /// the other must still be able to raise.
    func test85_attendingOneSessionDoesNotSuppressAnUnselectedSiblingInTheSameProject() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let sessionA = store.sessions.first!
        store.newSession(in: store.projects.first!)
        let sessionB = store.sessions.first { $0.id != sessionA.id }!
        XCTAssertEqual(sessionB.projectPath, sessionA.projectPath, "both sessions must share a project for this to test granularity at all")

        store.selection = sessionA.id
        store.setAppActive(true)
        XCTAssertEqual(store.attention[sessionA.id]?.isAttended, true)

        spy.emitSignal(sessionB.id, .notification(title: "Claude Code", body: "Claude needs your permission to use Bash"))

        XCTAssertEqual(
            store.attention[sessionB.id]?.activity, .blocked,
            "attention must never be withdrawn at a level coarser than one session — B sharing a project with the attended A must not suppress B's own notification"
        )
    }

    // MARK: - 86

    func test86_withAppActiveNeverSeededSelectionChangesAttendNothing() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let sessionA = store.sessions.first!
        store.newSession(in: store.projects.first!)
        // Selection churns twice, but setAppActive(_:) is never called at
        // all — simulating what would happen if RootView's launch seed
        // (`store.setAppActive(NSApp.isActive)`) never ran.
        store.selection = sessionA.id

        spy.emitSignal(sessionA.id, .notification(title: "Claude Code", body: "Claude is waiting for your input"))

        XCTAssertEqual(
            store.attention[sessionA.id]?.activity, .yourTurn,
            "selection changes alone must never attend a session — without the app-active flag ever being set true, a notification for the selected session must still raise, or a store that never received the seed call would silently swallow every notification for whatever happens to be selected"
        )
    }

    // MARK: - Agent session resume

    func test87_agentCallbackPersistsAndEnrichesResumeMetadataWithoutRaisingAttention() {
        let (store, spy, url) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let sessionID = store.sessions.first!.id

        spy.emitTitle(sessionID, "π ⠙ Repair persistence")
        spy.emitAgentEvent(
            sessionID,
            AgentSessionEvent(agent: "omp", name: "session_start", sessionID: "omp-1", query: nil)
        )

        XCTAssertEqual(
            store.sessions.first?.resume,
            SessionResumeMetadata(
                agent: "omp",
                sessionID: "omp-1",
                title: "Repair persistence",
                prompt: nil
            )
        )
        XCTAssertNil(store.attention[sessionID])

        spy.emitAgentEvent(
            sessionID,
            AgentSessionEvent(agent: "omp", name: "prompt_submit", sessionID: "omp-1", query: "Make it durable")
        )
        spy.emitTitle(sessionID, "zsh: /tmp/proj-A")

        XCTAssertEqual(store.sessions.first?.resume?.title, "Repair persistence")
        XCTAssertEqual(store.sessions.first?.resume?.prompt, "Make it durable")

        let restored = AppStore(terminals: SpyTerminals(), stateURL: url, engine: FakeWorkspaceEngine())
        XCTAssertEqual(restored.sessions.first?.resume, store.sessions.first?.resume)
    }

    func test87b_hookHomeIsRememberedAndRefreshedForTheSameSession() {
        let (store, spy, url) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let sessionID = store.sessions.first!.id

        spy.emitAgentEvent(
            sessionID,
            AgentSessionEvent(agent: "codex", name: "SessionStart", sessionID: "c-1", query: nil, home: "/Users/kira/.codex-kira")
        )
        XCTAssertEqual(store.sessions.first?.resume?.home, "/Users/kira/.codex-kira")

        // An event without a home keeps the remembered one; an event with a
        // home replaces it — the latest word on where the harness lives wins.
        spy.emitAgentEvent(
            sessionID,
            AgentSessionEvent(agent: "codex", name: "UserPromptSubmit", sessionID: "c-1", query: "go", home: nil)
        )
        XCTAssertEqual(store.sessions.first?.resume?.home, "/Users/kira/.codex-kira")
        spy.emitAgentEvent(
            sessionID,
            AgentSessionEvent(agent: "codex", name: "UserPromptSubmit", sessionID: "c-1", query: nil, home: "/elsewhere")
        )
        XCTAssertEqual(store.sessions.first?.resume?.home, "/elsewhere")

        let restored = AppStore(terminals: SpyTerminals(), stateURL: url, engine: FakeWorkspaceEngine())
        XCTAssertEqual(
            restored.sessions.first?.resume?.home, "/elsewhere",
            "the home must survive a relaunch — it is only ever read when building the banner after one"
        )
    }

    func test88_newOmpSessionIDReplacesPriorMetadataAndLaterDecoratedTitleEnrichesIt() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let sessionID = store.sessions.first!.id

        spy.emitTitle(sessionID, "π > Old task")
        spy.emitAgentEvent(
            sessionID,
            AgentSessionEvent(agent: "omp", name: "prompt_submit", sessionID: "omp-old", query: "Old prompt")
        )
        spy.emitTitle(sessionID, "π > New task")
        spy.emitAgentEvent(
            sessionID,
            AgentSessionEvent(agent: "omp", name: "session_start", sessionID: "omp-new", query: nil)
        )

        XCTAssertEqual(
            store.sessions.first?.resume,
            SessionResumeMetadata(agent: "omp", sessionID: "omp-new", title: "New task", prompt: nil)
        )

        spy.emitTitle(sessionID, "π ! New task needs input")
        XCTAssertEqual(store.sessions.first?.resume?.title, "New task needs input")
    }

    func test89_shellTitleDoesNotEnrichOrClearExistingOmpResumeMetadata() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let sessionID = store.sessions.first!.id

        spy.emitTitle(sessionID, "zsh: /tmp/proj-A")
        spy.emitAgentEvent(
            sessionID,
            AgentSessionEvent(agent: "omp", name: "session_start", sessionID: "omp-1", query: nil)
        )
        spy.emitAgentEvent(
            sessionID,
            AgentSessionEvent(agent: "omp", name: "tool_complete", sessionID: "omp-1", query: nil)
        )

        XCTAssertNil(store.sessions.first?.resume?.title)
        XCTAssertEqual(store.sessions.first?.resume?.sessionID, "omp-1")

        spy.emitTitle(sessionID, "π > Recognized OMP task")
        XCTAssertEqual(store.sessions.first?.resume?.title, "Recognized OMP task")
    }

    // MARK: - 89b: title roles in a split

    func test89b_displayOnlyTitleNamesTheRowButNeverTouchesResumeMetadata() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let sessionID = store.sessions.first!.id

        spy.emitAgentEvent(
            sessionID,
            AgentSessionEvent(agent: "claude", name: "SessionStart", sessionID: "c-A", query: nil)
        )
        spy.emitTitle(sessionID, "✳ Designate task", roles: [.resume])
        XCTAssertEqual(store.sessions.first?.resume?.title, "Designate task")

        // The focused sibling's title in a split arrives display-only.
        spy.emitTitle(sessionID, "✳ Sibling task", roles: [.display])

        XCTAssertEqual(
            store.sessions.first?.agentTitle, "✳ Sibling task",
            "the focused pane's title must still drive the row's display name"
        )
        XCTAssertEqual(
            store.sessions.first?.resume?.title, "Designate task",
            "a display-only title must never relabel the resume record — the record's session id belongs to the designate pane's agent, and a sibling's task name on it would advertise a resume hint that lies about what it resumes"
        )
    }

    func test89b_resumeOnlyTitleLabelsTheMetadataWithoutRenamingTheRow() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let sessionID = store.sessions.first!.id

        spy.emitTitle(sessionID, "✳ Sibling task", roles: [.display])
        spy.emitAgentEvent(
            sessionID,
            AgentSessionEvent(agent: "claude", name: "SessionStart", sessionID: "c-A", query: nil)
        )

        XCTAssertNil(
            store.sessions.first?.resume?.title,
            "an agent event must not seed its resume title from the row's display name — that name is the focused sibling's; with no designate title known yet the honest seed is none"
        )

        spy.emitTitle(sessionID, "✳ Designate task", roles: [.resume])
        XCTAssertEqual(store.sessions.first?.resume?.title, "Designate task")
        XCTAssertEqual(
            store.sessions.first?.agentTitle, "✳ Sibling task",
            "a resume-only title must not rename the row — the unfocused designate has no say over the display name"
        )
    }

    func test89b_designateTitleKnownBeforeTheAgentEventSeedsTheRecord() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let sessionID = store.sessions.first!.id

        spy.emitTitle(sessionID, "✳ Sibling task", roles: [.display])
        spy.emitTitle(sessionID, "✳ Designate task", roles: [.resume])
        spy.emitAgentEvent(
            sessionID,
            AgentSessionEvent(agent: "claude", name: "SessionStart", sessionID: "c-A", query: nil)
        )

        XCTAssertEqual(
            store.sessions.first?.resume?.title, "Designate task",
            "the first agent event must seed its title from the DESIGNATE pane's remembered title, not from agentTitle, which the focused sibling owns"
        )
    }

    // MARK: - 90

    func test90_claudeCodeSessionFlowPersistsAcrossReloadWithoutRaisingAttention() {
        let (store, spy, url) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let sessionID = store.sessions.first!.id

        spy.emitTitle(sessionID, "◐ Fix the parser")
        spy.emitAgentEvent(
            sessionID,
            AgentSessionEvent(agent: "claude", name: "SessionStart", sessionID: "c-1", query: nil)
        )

        XCTAssertEqual(
            store.sessions.first?.resume,
            SessionResumeMetadata(agent: "claude", sessionID: "c-1", title: "Fix the parser", prompt: nil),
            "a Claude Code spinner-decorated title present at session-start time must seed the resume snapshot's title immediately, the same way an OMP π title does"
        )
        XCTAssertNil(store.attention[sessionID], "a session-resume envelope must never itself raise attention — only agents:status/notifications/bell do that")

        spy.emitAgentEvent(
            sessionID,
            AgentSessionEvent(agent: "claude", name: "UserPromptSubmit", sessionID: "c-1", query: "Make it durable")
        )
        XCTAssertEqual(store.sessions.first?.resume?.prompt, "Make it durable")

        spy.emitTitle(sessionID, "✳ Fix the parser")
        XCTAssertEqual(
            store.sessions.first?.resume?.title, "Fix the parser",
            "Claude Code's idle glyph ✳ is a recognized decoration too, not just the spinner frames, and must keep enriching the same snapshot"
        )

        spy.emitTitle(sessionID, "kira@Mac:~/code")
        XCTAssertEqual(
            store.sessions.first?.resume?.title, "Fix the parser",
            "a plain shell prompt taking over the title (agent exited) must not be read as a Claude Code decoration and must not wipe the remembered title"
        )

        let restored = AppStore(terminals: SpyTerminals(), stateURL: url, engine: FakeWorkspaceEngine())
        XCTAssertEqual(
            restored.sessions.first?.resume,
            store.sessions.first?.resume,
            "the agent identifier itself must round-trip through save/reload identically to title/prompt"
        )
        XCTAssertEqual(restored.sessions.first?.resume?.agent, "claude")
    }

    // MARK: - 91

    func test91_switchingHarnessOnOneRowReplacesTheResumeSnapshot() {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/proj-A")
        let sessionID = store.sessions.first!.id

        spy.emitAgentEvent(
            sessionID,
            AgentSessionEvent(agent: "omp", name: "prompt_submit", sessionID: "omp-1", query: "old")
        )
        XCTAssertEqual(store.sessions.first?.resume?.agent, "omp")

        spy.emitAgentEvent(
            sessionID,
            AgentSessionEvent(agent: "claude", name: "SessionStart", sessionID: "c-1", query: nil)
        )

        XCTAssertEqual(
            store.sessions.first?.resume,
            SessionResumeMetadata(agent: "claude", sessionID: "c-1", title: nil, prompt: nil),
            "a different harness announcing a session on the same row must replace the prior snapshot wholesale, including dropping OMP's leftover prompt — carrying OMP's prompt text into a Claude Code snapshot would misattribute it"
        )

        // Same session id string reused under a different agent must also
        // replace, not merge — session ids are only unique within a single
        // harness's own id space, so a collision across harnesses is
        // coincidence, not continuity.
        spy.emitAgentEvent(
            sessionID,
            AgentSessionEvent(agent: "claude", name: "UserPromptSubmit", sessionID: "same", query: "a claude prompt")
        )
        XCTAssertEqual(store.sessions.first?.resume?.sessionID, "same")
        XCTAssertEqual(store.sessions.first?.resume?.prompt, "a claude prompt")

        spy.emitAgentEvent(
            sessionID,
            AgentSessionEvent(agent: "codex", name: "session_start", sessionID: "same", query: nil)
        )

        XCTAssertEqual(store.sessions.first?.resume?.agent, "codex")
        XCTAssertEqual(store.sessions.first?.resume?.sessionID, "same")
        XCTAssertNil(
            store.sessions.first?.resume?.prompt,
            "codex's own event carried no query, and the prior snapshot belonged to a different agent entirely, so nothing should have carried over"
        )
    }

    func test27a_dirtyOnlyPreviewRequiresDestructiveConfirmation() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .success(LandPreview(bookmark: "main", bookmarkCommit: "head", commits: [], conflicts: [], needsMessage: true))
        await store.prepareCloseWorkspace(workspace.id)
        XCTAssertEqual(store.closeWorkspace?.phase, .summaryRequired(changes: ["Undescribed change"]))
        await store.closeWithoutAddingWorkspace()
        XCTAssertTrue(fake.deleteCalls.isEmpty)
        store.requestCloseWithoutAdding()
        await store.closeWithoutAddingWorkspace()
        XCTAssertEqual(fake.deleteCalls, [workspace])
    }

    func test27aa_describedCommitsAndDirtyWorkingTreeIncludeTrailingUndescribedChange() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "main",
                bookmarkCommit: "head",
                commits: [
                    LandCommit(id: "1", subject: "First committed change"),
                    LandCommit(id: "2", subject: "Second committed change")
                ],
                conflicts: [],
                needsMessage: true
            )
        )

        await store.prepareCloseWorkspace(workspace.id)

        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .summaryRequired(
                changes: [
                    "First committed change",
                    "Second committed change",
                    "Undescribed change"
                ]
            )
        )
    }

    func test27ab_undescribedCommitAndNeedsMessageDoNotDuplicatePlaceholder() async {
        for subject in ["", "  \n "] {
            let fake = FakeWorkspaceEngine()
            let (store, _, _) = TestSupport.makeStore(engine: fake)
            let workspace = await makeClosableWorkspace(store: store, fake: fake)
            fake.nextPreviewResult = .success(
                LandPreview(
                    bookmark: "main",
                    bookmarkCommit: "head",
                    commits: [LandCommit(id: "1", subject: subject)],
                    conflicts: [],
                    needsMessage: true
                )
            )

            await store.prepareCloseWorkspace(workspace.id)

            XCTAssertEqual(
                store.closeWorkspace?.phase,
                .summaryRequired(changes: ["Undescribed change"])
            )
        }
    }

    func test27c_conflictAttentionCanCancelConfirmationThenDelete() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .success(LandPreview(bookmark: "main", bookmarkCommit: "head", commits: [], conflicts: [LandCommit(id: "1", subject: " \n ")], needsMessage: false))
        await store.prepareCloseWorkspace(workspace.id)
        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .conflictAttention(
                message: "These changes overlap newer project progress and need attention.",
                details: ["Conflicting change"],
                engineMessage: nil
            )
        )
        store.requestCloseWithoutAdding()
        store.cancelCloseWithoutAdding()
        guard case .conflictAttention = store.closeWorkspace?.phase else { return XCTFail("expected conflict attention restored") }
        store.requestCloseWithoutAdding()
        await store.closeWithoutAddingWorkspace()
        XCTAssertEqual(fake.deleteCalls, [workspace])
        XCTAssertFalse(store.workspaces.contains { $0.id == workspace.id })
    }

    func test27b_closeWithoutAddingStaleSheetStillRemovesDeletedWorkspace() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .failure(.nothingToLand("clean"))
        await store.prepareCloseWorkspace(workspace.id)
        let newer = CloseWorkspacePresentation(workspaceID: UUID().uuidString, workspaceName: "new", projectPath: workspace.projectPath, projectName: "p", phase: .ready(changes: []))
        fake.onDeleteWorkspace = { store.closeWorkspace = newer }
        await store.closeWithoutAddingWorkspace()
        XCTAssertFalse(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertEqual(store.closeWorkspace, newer)
    }

    func test33a_cancelDuringLandDoesNotDismissBusySheet() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .success(LandPreview(bookmark: "main", bookmarkCommit: "head", commits: [LandCommit(id: "1", subject: "change")], conflicts: [], needsMessage: false))
        var remainedBusy = false
        fake.onLandWorkspace = {
            store.cancelCloseWorkspace()
            remainedBusy = store.closeWorkspace?.isBusy == true
        }
        await store.prepareCloseWorkspace(workspace.id)
        await store.addChangesAndCloseWorkspace()
        XCTAssertTrue(remainedBusy)
        XCTAssertEqual(store.closeWorkspace?.phase, .success(addedChanges: 1, notice: nil))
    }

    func test33b_genericPreviewFailureUsesStableProjectRecoveryCopy() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .failure(.failed("preview failed"))
        await store.prepareCloseWorkspace(workspace.id)
        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .failure(
                message: "The workspace's changes couldn't be compared with the project. The workspace remains open. Return to it and try again."
            )
        )
    }

    /// A `workspace-changed` refusal is the engine saying the workspace needs
    /// the user's hand before it can even be previewed -- a stale jj working
    /// copy, a git rebase still in progress -- and its message is the only
    /// thing that says what to do, so it is shown verbatim rather than the
    /// generic recovery copy.
    func test33b2_workspaceChangedPreviewSurfacesTheEngineMessage() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        let engineMessage = "The working copy in /tmp/ws is stale: run `jj workspace update-stale` in that directory, then try again."
        fake.nextPreviewResult = .failure(.workspaceChanged(engineMessage))
        await store.prepareCloseWorkspace(workspace.id)
        XCTAssertEqual(store.closeWorkspace?.phase, .failure(message: engineMessage))
        XCTAssertTrue(store.workspaces.contains { $0.id == workspace.id })
    }

    func test33c_unknownPreviewFailureUsesStableProjectRecoveryCopy() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.previewLandHandler = { _, _ in
            throw NSError(domain: "raw manager/VCS/storage/token diagnostic", code: 17)
        }

        await store.prepareCloseWorkspace(workspace.id)

        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .failure(
                message: "The workspace's changes couldn't be compared with the project. The workspace remains open. Return to it and try again."
            )
        )
    }

    func test49a_removeProjectClearsWorkingCopyAttentionForRemoveAndReAdd() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let path = "/tmp/project-attention"
        store.addProject(path: path)
        fake.nextRebaseResult = .failure(.rebaseConflict("conflict"))
        await store.refreshProjectWorkspace(path)
        XCTAssertTrue(store.projectWorkingCopyAttention.contains(path))
        let project = store.projects.first { $0.path == path }!
        store.removeProject(project)
        XCTAssertFalse(store.projectWorkingCopyAttention.contains(path))
        store.addProject(path: path)
        XCTAssertFalse(store.projectWorkingCopyAttention.contains(path))
    }

    func test49b_landCompletionAfterRemoveAndReaddCannotMutateNewLifecycle() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "main",
                bookmarkCommit: "head",
                commits: [LandCommit(id: "1", subject: "Change")],
                conflicts: [],
                needsMessage: false
            )
        )
        await store.prepareCloseWorkspace(workspace.id)

        let landStarted = expectation(description: "land reached suspension")
        var landContinuation: CheckedContinuation<LandResult, Error>?
        fake.landWorkspaceHandler = { _, _, _ in
            try await withCheckedThrowingContinuation { continuation in
                landContinuation = continuation
                landStarted.fulfill()
            }
        }

        let closeTask = Task { await store.addChangesAndCloseWorkspace() }
        await fulfillment(of: [landStarted], timeout: 2)

        let oldProject = store.projects.first { $0.path == workspace.projectPath }!
        store.removeProject(oldProject)
        store.addProject(path: workspace.projectPath)
        let newSessionID = store.selection
        let closedBeforeLandCompletion = spy.closedIDs

        landContinuation!.resume(
            returning: LandResult(commitID: "landed", bookmark: "main")
        )
        await closeTask.value

        XCTAssertEqual(spy.closedIDs, closedBeforeLandCompletion)
        XCTAssertTrue(store.sessions.contains { $0.id == newSessionID })
        XCTAssertTrue(store.projectWorkingCopyAttention.isEmpty)
        XCTAssertTrue(fake.rebaseOntoTrunkCalls.isEmpty)
        XCTAssertNil(store.closeWorkspace)
    }

    func test49c_staleReconciliationFailureAfterRemoveIsNeutralForOldClose() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "main",
                bookmarkCommit: "head",
                commits: [LandCommit(id: "1", subject: "Change")],
                conflicts: [],
                needsMessage: false
            )
        )
        await store.prepareCloseWorkspace(workspace.id)

        let rebaseStarted = expectation(description: "rebase reached suspension")
        var rebaseContinuation: CheckedContinuation<Int, Error>?
        fake.rebaseOntoTrunkHandler = { _ in
            try await withCheckedThrowingContinuation { continuation in
                rebaseContinuation = continuation
                rebaseStarted.fulfill()
            }
        }

        let closeTask = Task { await store.addChangesAndCloseWorkspace() }
        await fulfillment(of: [rebaseStarted], timeout: 2)
        let project = store.projects.first { $0.path == workspace.projectPath }!
        store.removeProject(project)
        rebaseContinuation!.resume(
            throwing: EngineError.rebaseConflict("stale failure")
        )
        await closeTask.value

        XCTAssertFalse(store.projectWorkingCopyAttention.contains(workspace.projectPath))
        XCTAssertNil(store.closeWorkspace)
    }

    func test49d_oldReconciliationSuccessCannotClearNewLifecycleAttention() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let path = "/tmp/readded-project-success"
        store.addProject(path: path)

        let firstStarted = expectation(description: "old rebase reached suspension")
        var firstContinuation: CheckedContinuation<Int, Error>?
        var callCount = 0
        fake.rebaseOntoTrunkHandler = { _ in
            callCount += 1
            if callCount == 1 {
                return try await withCheckedThrowingContinuation { continuation in
                    firstContinuation = continuation
                    firstStarted.fulfill()
                }
            }
            throw EngineError.rebaseConflict("new lifecycle attention")
        }

        let oldRefresh = Task { await store.refreshProjectWorkspace(path) }
        await fulfillment(of: [firstStarted], timeout: 2)
        let oldProject = store.projects.first { $0.path == path }!
        store.removeProject(oldProject)
        store.addProject(path: path)
        await store.refreshProjectWorkspace(path)
        XCTAssertTrue(store.projectWorkingCopyAttention.contains(path))

        firstContinuation!.resume(returning: 0)
        await oldRefresh.value

        XCTAssertTrue(store.projectWorkingCopyAttention.contains(path))
    }

    func test49e_oldReconciliationFailureCannotRaiseNewLifecycleAttention() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let path = "/tmp/readded-project-failure"
        store.addProject(path: path)

        let rebaseStarted = expectation(description: "old rebase reached suspension")
        var continuation: CheckedContinuation<Int, Error>?
        fake.rebaseOntoTrunkHandler = { _ in
            try await withCheckedThrowingContinuation { suspended in
                continuation = suspended
                rebaseStarted.fulfill()
            }
        }

        let oldRefresh = Task { await store.refreshProjectWorkspace(path) }
        await fulfillment(of: [rebaseStarted], timeout: 2)
        let oldProject = store.projects.first { $0.path == path }!
        store.removeProject(oldProject)
        store.addProject(path: path)
        continuation!.resume(
            throwing: EngineError.rebaseConflict("old lifecycle failure")
        )
        await oldRefresh.value

        XCTAssertFalse(store.projectWorkingCopyAttention.contains(path))
    }

    func test49f_addingExistingProjectPathDoesNotRenewLifecycle() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let path = "/tmp/existing-project"
        store.addProject(path: path)

        let rebaseStarted = expectation(description: "rebase reached suspension")
        var continuation: CheckedContinuation<Int, Error>?
        fake.rebaseOntoTrunkHandler = { _ in
            try await withCheckedThrowingContinuation { suspended in
                continuation = suspended
                rebaseStarted.fulfill()
            }
        }

        let refresh = Task { await store.refreshProjectWorkspace(path) }
        await fulfillment(of: [rebaseStarted], timeout: 2)
        store.addProject(path: path)
        continuation!.resume(
            throwing: EngineError.rebaseConflict("same lifecycle failure")
        )
        await refresh.value

        XCTAssertTrue(store.projectWorkingCopyAttention.contains(path))
    }

    func test49g_deleteCompletionAfterRemoveAndReaddCannotTearDownNewLifecycle() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .failure(.nothingToLand("nothing to add"))
        await store.prepareCloseWorkspace(workspace.id)

        let deleteStarted = expectation(description: "delete reached suspension")
        var continuation: CheckedContinuation<DeleteResult, Error>?
        fake.deleteWorkspaceHandler = { _, _ in
            try await withCheckedThrowingContinuation { suspended in
                continuation = suspended
                deleteStarted.fulfill()
            }
        }

        let closeTask = Task { await store.closeWithoutAddingWorkspace() }
        await fulfillment(of: [deleteStarted], timeout: 2)
        let oldProject = store.projects.first { $0.path == workspace.projectPath }!
        store.removeProject(oldProject)
        store.addProject(path: workspace.projectPath)
        let newSessionID = store.selection
        let closedBeforeDeleteCompletion = spy.closedIDs

        continuation!.resume(returning: DeleteResult())
        await closeTask.value

        XCTAssertEqual(spy.closedIDs, closedBeforeDeleteCompletion)
        XCTAssertTrue(store.sessions.contains { $0.id == newSessionID })
        XCTAssertNil(store.closeWorkspace)
    }

    func test49h_oldLandFailureCannotOverwriteReaddedSameWorkspaceSheet() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        let preview = LandPreview(
            bookmark: "main",
            bookmarkCommit: "head",
            commits: [LandCommit(id: "1", subject: "New lifecycle change")],
            conflicts: [],
            needsMessage: false
        )
        fake.nextPreviewResult = .success(preview)
        await store.prepareCloseWorkspace(workspace.id)

        let landStarted = expectation(description: "old land reached suspension")
        var continuation: CheckedContinuation<LandResult, Error>?
        fake.landWorkspaceHandler = { _, _, _ in
            try await withCheckedThrowingContinuation { suspended in
                continuation = suspended
                landStarted.fulfill()
            }
        }
        let oldClose = Task { await store.addChangesAndCloseWorkspace() }
        await fulfillment(of: [landStarted], timeout: 2)

        let oldProject = store.projects.first { $0.path == workspace.projectPath }!
        store.removeProject(oldProject)
        store.addProject(path: workspace.projectPath)
        fake.nextCreateResult = .success(workspace)
        await store.createWorkspace(in: workspace.projectPath)
        fake.nextPreviewResult = .success(preview)
        await store.prepareCloseWorkspace(workspace.id)
        let newSessionID = store.selection

        continuation!.resume(throwing: EngineError.failed("old land failure"))
        await oldClose.value

        XCTAssertEqual(store.closeWorkspace?.phase, .ready(changes: ["New lifecycle change"]))
        XCTAssertTrue(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertTrue(store.sessions.contains { $0.id == newSessionID })
    }

    func test49i_oldDeleteFailureCannotOverwriteReaddedSameWorkspaceSheet() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .failure(.nothingToLand("nothing to add"))
        await store.prepareCloseWorkspace(workspace.id)

        let deleteStarted = expectation(description: "old delete reached suspension")
        var continuation: CheckedContinuation<DeleteResult, Error>?
        fake.deleteWorkspaceHandler = { _, _ in
            try await withCheckedThrowingContinuation { suspended in
                continuation = suspended
                deleteStarted.fulfill()
            }
        }
        let oldClose = Task { await store.closeWithoutAddingWorkspace() }
        await fulfillment(of: [deleteStarted], timeout: 2)

        let oldProject = store.projects.first { $0.path == workspace.projectPath }!
        store.removeProject(oldProject)
        store.addProject(path: workspace.projectPath)
        fake.nextCreateResult = .success(workspace)
        await store.createWorkspace(in: workspace.projectPath)
        fake.nextPreviewResult = .failure(.nothingToLand("new lifecycle is clean"))
        await store.prepareCloseWorkspace(workspace.id)
        let newSessionID = store.selection

        continuation!.resume(throwing: EngineError.failed("old delete failure"))
        await oldClose.value

        XCTAssertEqual(store.closeWorkspace?.phase, .noChanges)
        XCTAssertTrue(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertTrue(store.sessions.contains { $0.id == newSessionID })
    }

    func test49j_oldPreviewFailureCannotOverwriteReaddedSameWorkspaceSheet() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        let preview = LandPreview(
            bookmark: "main",
            bookmarkCommit: "head",
            commits: [LandCommit(id: "1", subject: "New preview")],
            conflicts: [],
            needsMessage: false
        )
        let previewStarted = expectation(description: "old preview reached suspension")
        var continuation: CheckedContinuation<LandPreview, Error>?
        var previewCallCount = 0
        fake.previewLandHandler = { _, _ in
            previewCallCount += 1
            if previewCallCount == 1 {
                return try await withCheckedThrowingContinuation { suspended in
                    continuation = suspended
                    previewStarted.fulfill()
                }
            }
            return preview
        }
        let oldPreview = Task { await store.prepareCloseWorkspace(workspace.id) }
        await fulfillment(of: [previewStarted], timeout: 2)

        let oldProject = store.projects.first { $0.path == workspace.projectPath }!
        store.removeProject(oldProject)
        store.addProject(path: workspace.projectPath)
        fake.nextCreateResult = .success(workspace)
        await store.createWorkspace(in: workspace.projectPath)
        await store.prepareCloseWorkspace(workspace.id)

        continuation!.resume(throwing: EngineError.failed("old preview failure"))
        await oldPreview.value

        XCTAssertEqual(store.closeWorkspace?.phase, .ready(changes: ["New preview"]))
        XCTAssertTrue(store.workspaces.contains { $0.id == workspace.id })
    }

    func test49k_createCompletionAfterRemoveAndReaddCannotMutateNewLifecycle() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let path = "/tmp/stale-create"
        let workspace = WorkspaceRow(
            projectPath: path,
            name: "same-name",
            path: "\(path)/same-name",
            label: nil
        )
        store.addProject(path: path)

        let createStarted = expectation(description: "old create reached suspension")
        var continuation: CheckedContinuation<WorkspaceRow, Error>?
        fake.createWorkspaceHandler = { _ in
            try await withCheckedThrowingContinuation { suspended in
                continuation = suspended
                createStarted.fulfill()
            }
        }
        let oldCreate = Task { await store.createWorkspace(in: path) }
        await fulfillment(of: [createStarted], timeout: 2)

        let oldProject = store.projects.first { $0.path == path }!
        store.removeProject(oldProject)
        store.addProject(path: path)
        let newSessionID = store.selection
        continuation!.resume(returning: workspace)
        await oldCreate.value

        XCTAssertFalse(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertFalse(store.sessions.contains { $0.target.id == workspace.id })
        XCTAssertTrue(store.sessions.contains { $0.id == newSessionID })
    }

    func test49l_createFailureAfterRemoveAndReaddCannotSetNewLifecycleError() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let path = "/tmp/stale-create-failure"
        store.addProject(path: path)

        let createStarted = expectation(description: "old create reached suspension")
        var continuation: CheckedContinuation<WorkspaceRow, Error>?
        fake.createWorkspaceHandler = { _ in
            try await withCheckedThrowingContinuation { suspended in
                continuation = suspended
                createStarted.fulfill()
            }
        }
        let oldCreate = Task { await store.createWorkspace(in: path) }
        await fulfillment(of: [createStarted], timeout: 2)

        let oldProject = store.projects.first { $0.path == path }!
        store.removeProject(oldProject)
        store.addProject(path: path)
        continuation!.resume(throwing: EngineError.failed("old create failure"))
        await oldCreate.value

        XCTAssertNil(store.lastError)
    }
    func test72_noEngineCallBeginsUntilWorkspaceSessionsFinishQuiescing() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, stateURL) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        // The helper already closed the project's default root session; that
        // is setup noise, not something this test is about, so it's carried
        // forward as a baseline rather than asserted away.
        let closedIDsAfterSetup = spy.closedIDs
        fake.nextPreviewResult = .failure(.nothingToLand("nothing to add"))
        await store.prepareCloseWorkspace(workspace.id)

        let workspaceSessionIDs = Set(store.sessions.filter {
            $0.target == .workspace(projectPath: workspace.projectPath, name: workspace.name)
        }.map(\.id))
        let persistedBefore = try! Data(contentsOf: stateURL)
        let quiesceStarted = expectation(description: "quiesce reached suspension")
        var quiesceContinuation: CheckedContinuation<Void, Never>?
        spy.quiesceSessionsHandler = { _ in
            await withCheckedContinuation { continuation in
                quiesceContinuation = continuation
                quiesceStarted.fulfill()
            }
        }

        let closeTask = Task { await store.closeWithoutAddingWorkspace() }
        await fulfillment(of: [quiesceStarted], timeout: 2)

        XCTAssertEqual(spy.quiesceCalls, [workspaceSessionIDs])
        XCTAssertTrue(fake.deleteCalls.isEmpty)
        XCTAssertEqual(try! Data(contentsOf: stateURL), persistedBefore)

        quiesceContinuation!.resume()
        await closeTask.value

        XCTAssertEqual(fake.deleteCalls, [workspace])
        XCTAssertEqual(fake.deleteOnlyIfUnchangedCalls, [true])
        XCTAssertEqual(Set(spy.closedIDs), Set(closedIDsAfterSetup).union(workspaceSessionIDs))
        XCTAssertTrue(spy.resumeCalls.isEmpty)
    }

    func test73_lateChangeAfterNoChangePreviewRefusesForgetAndReturnsToChangeReview() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, stateURL) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        // The helper already closed the project's default root session; that
        // is setup noise, not something this test is about, so it's carried
        // forward as a baseline rather than asserted away.
        let closedIDsAfterSetup = spy.closedIDs
        fake.nextPreviewResult = .failure(.nothingToLand("nothing to add"))
        await store.prepareCloseWorkspace(workspace.id)

        let sessionsBefore = store.sessions
        let workspacesBefore = store.workspaces
        let selectionBefore = store.selection
        let persistedBefore = try! Data(contentsOf: stateURL)
        let workspaceSessionIDs = Set(sessionsBefore.filter {
            $0.target == .workspace(projectPath: workspace.projectPath, name: workspace.name)
        }.map(\.id))
        fake.nextDeleteResult = .failure(.workspaceChanged("workspace changed"))
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "main",
                bookmarkCommit: "abc",
                commits: [LandCommit(id: "late", subject: "Late terminal change")],
                conflicts: [],
                needsMessage: false
            )
        )

        await store.closeWithoutAddingWorkspace()

        XCTAssertEqual(fake.deleteOnlyIfUnchangedCalls, [true])
        XCTAssertEqual(spy.quiesceCalls, [workspaceSessionIDs])
        XCTAssertEqual(spy.resumeCalls, [workspaceSessionIDs])
        XCTAssertEqual(spy.closedIDs, closedIDsAfterSetup)
        XCTAssertEqual(store.sessions, sessionsBefore)
        XCTAssertEqual(store.workspaces, workspacesBefore)
        XCTAssertEqual(store.selection, selectionBefore)
        XCTAssertEqual(try! Data(contentsOf: stateURL), persistedBefore)
        XCTAssertEqual(fake.previewLandCalls.count, 2)
        XCTAssertEqual(store.closeWorkspace?.phase, .ready(changes: ["Late terminal change"]))
    }

    func test74_failedLandResumesQuiescedSessionsAndPreservesExactPersistedState() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, stateURL) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "main",
                bookmarkCommit: "abc",
                commits: [LandCommit(id: "1", subject: "Change")],
                conflicts: [],
                needsMessage: false
            )
        )
        await store.prepareCloseWorkspace(workspace.id)

        // The helper already closed the project's default root session; that
        // is setup noise, not something this test is about, so it's carried
        // forward as a baseline rather than asserted away.
        let closedIDsAfterSetup = spy.closedIDs
        let sessionsBefore = store.sessions
        let workspacesBefore = store.workspaces
        let selectionBefore = store.selection
        let persistedBefore = try! Data(contentsOf: stateURL)
        let workspaceSessionIDs = Set(sessionsBefore.filter {
            $0.target == .workspace(projectPath: workspace.projectPath, name: workspace.name)
        }.map(\.id))
        fake.nextLandResult = .failure(.failed("land failed"))

        await store.addChangesAndCloseWorkspace()

        XCTAssertEqual(spy.quiesceCalls, [workspaceSessionIDs])
        XCTAssertEqual(spy.resumeCalls, [workspaceSessionIDs])
        XCTAssertEqual(spy.closedIDs, closedIDsAfterSetup)
        XCTAssertEqual(store.sessions, sessionsBefore)
        XCTAssertEqual(store.workspaces, workspacesBefore)
        XCTAssertEqual(store.selection, selectionBefore)
        XCTAssertEqual(try! Data(contentsOf: stateURL), persistedBefore)
        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .failure(
                message: "The changes couldn't be added to the project. The workspace remains open. Return to it and try again."
            )
        )
    }

    func test74b_unknownLandFailureUsesStableProjectRecoveryCopy() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "main",
                bookmarkCommit: "abc",
                commits: [LandCommit(id: "1", subject: "Change")],
                conflicts: [],
                needsMessage: false
            )
        )
        await store.prepareCloseWorkspace(workspace.id)
        fake.landWorkspaceHandler = { _, _, _ in
            throw NSError(domain: "raw manager/VCS/storage/token diagnostic", code: 18)
        }

        await store.addChangesAndCloseWorkspace()

        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .failure(
                message: "The changes couldn't be added to the project. The workspace remains open. Return to it and try again."
            )
        )
    }

    func test74c_unknownForgetFailureUsesStableProjectRecoveryCopy() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .failure(.nothingToLand("nothing to add"))
        await store.prepareCloseWorkspace(workspace.id)
        fake.deleteWorkspaceHandler = { _, _ in
            throw NSError(domain: "raw manager/VCS/storage/token diagnostic", code: 19)
        }

        await store.closeWithoutAddingWorkspace()

        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .failure(
                message: "The workspace couldn't be closed. The workspace remains open. Return to it and try again."
            )
        )
    }

    func test75_confirmedCloseWithoutAddingUsesExplicitlyDestructiveForget() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "main",
                bookmarkCommit: "abc",
                commits: [LandCommit(id: "1", subject: "Change")],
                conflicts: [],
                needsMessage: false
            )
        )
        await store.prepareCloseWorkspace(workspace.id)
        store.requestCloseWithoutAdding()

        await store.closeWithoutAddingWorkspace()

        XCTAssertEqual(fake.deleteOnlyIfUnchangedCalls, [false])
        XCTAssertEqual(spy.quiesceCalls.count, 1)
        XCTAssertTrue(spy.resumeCalls.isEmpty)
    }
    func test76_landDoesNotBeginUntilWorkspaceSessionsFinishQuiescing() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        // The helper already closed the project's default root session; that
        // is setup noise, not something this test is about, so it's carried
        // forward as a baseline rather than asserted away.
        let workspaceSessionIDs = Set(store.sessions.filter {
            $0.target == .workspace(projectPath: workspace.projectPath, name: workspace.name)
        }.map(\.id))
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "main",
                bookmarkCommit: "abc",
                commits: [LandCommit(id: "1", subject: "Change")],
                conflicts: [],
                needsMessage: false
            )
        )
        await store.prepareCloseWorkspace(workspace.id)

        let quiesceStarted = expectation(description: "land quiesce reached suspension")
        var quiesceContinuation: CheckedContinuation<Void, Never>?
        spy.quiesceSessionsHandler = { _ in
            await withCheckedContinuation { continuation in
                quiesceContinuation = continuation
                quiesceStarted.fulfill()
            }
        }

        let closeTask = Task { await store.addChangesAndCloseWorkspace() }
        await fulfillment(of: [quiesceStarted], timeout: 2)

        XCTAssertTrue(fake.landCalls.isEmpty)
        quiesceContinuation!.resume()
        await closeTask.value

        XCTAssertEqual(fake.landCalls.count, 1)
        XCTAssertEqual(spy.quiesceCalls, [workspaceSessionIDs])
        // The land succeeded, so the quiesced sessions are closed with the
        // workspace rather than resumed.
        XCTAssertTrue(spy.resumeCalls.isEmpty)
        XCTAssertTrue(Set(spy.closedIDs).isSuperset(of: workspaceSessionIDs))
        XCTAssertFalse(store.workspaces.contains { $0.id == workspace.id })
    }
    func test77_workspaceChangedDuringLandRestartsSessionsAndRefreshesPreparedChanges() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, stateURL) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        // The helper already closed the project's default root session; that
        // is setup noise, not something this test is about, so it's carried
        // forward as a baseline rather than asserted away.
        let closedIDsAfterSetup = spy.closedIDs
        let target = TargetRef.workspace(projectPath: workspace.projectPath, name: workspace.name)
        let session = store.sessions.first { $0.target == target }!
        spy.emitTitle(session.id, "π > Preserve this session")
        spy.emitAgentEvent(
            session.id,
            AgentSessionEvent(agent: "omp", name: "session_start", sessionID: "omp-stale-recovery", query: nil)
        )
        let sessionsBefore = store.sessions
        let workspacesBefore = store.workspaces
        let persistedBefore = try! Data(contentsOf: stateURL)
        let sessionIDs = Set(sessionsBefore.filter { $0.target == target }.map(\.id))
        fake.previewResults = [
            .success(LandPreview(
                bookmark: "main", bookmarkCommit: "old", commits: [LandCommit(id: "old", subject: "Old target change")],
                conflicts: [], needsMessage: false
            )),
            .success(LandPreview(
                bookmark: "main", bookmarkCommit: "new", commits: [LandCommit(id: "new", subject: "Current target change")],
                conflicts: [], needsMessage: false
            )),
        ]
        fake.landWorkspaceHandler = { _, _, _ in
            throw EngineError.workspaceChanged("a rebase is already in progress in this worktree")
        }

        await store.prepareCloseWorkspace(workspace.id)
        XCTAssertEqual(store.closeWorkspace?.phase, .ready(changes: ["Old target change"]))
        await store.addChangesAndCloseWorkspace()

        XCTAssertEqual(fake.landCalls.count, 1)
        XCTAssertEqual(spy.quiesceCalls, [sessionIDs])
        XCTAssertEqual(spy.resumeCalls, [sessionIDs])
        XCTAssertEqual(spy.closedIDs, closedIDsAfterSetup)
        XCTAssertEqual(store.sessions, sessionsBefore)
        XCTAssertEqual(store.workspaces, workspacesBefore)
        XCTAssertEqual(try! Data(contentsOf: stateURL), persistedBefore)
        XCTAssertEqual(store.sessions.first { $0.id == session.id }?.resume, sessionsBefore.first { $0.id == session.id }?.resume)
        XCTAssertEqual(store.closeWorkspace?.phase, .ready(changes: ["Current target change"]))
    }

    func test78_projectProgressChangeAfterSummaryPreviewClearsStaleSummaryAndRefreshes() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        let sessionIDs = Set(store.sessions.filter {
            $0.target == .workspace(projectPath: workspace.projectPath, name: workspace.name)
        }.map(\.id))
        fake.previewResults = [
            .success(LandPreview(
                bookmark: "main", bookmarkCommit: "old-project", commits: [LandCommit(id: "dirty", subject: "")],
                conflicts: [], needsMessage: true
            )),
            .success(LandPreview(
                bookmark: "main", bookmarkCommit: "new-project", commits: [LandCommit(id: "new", subject: "Preferred project progress")],
                conflicts: [], needsMessage: false
            )),
        ]
        fake.landWorkspaceHandler = { _, _, _ in
            throw EngineError.workspaceChanged("the workspace changed")
        }

        await store.prepareCloseWorkspace(workspace.id)
        store.setCloseWorkspaceSummary("Description for old preview")
        await store.addChangesAndCloseWorkspace()

        XCTAssertEqual(spy.resumeCalls, [sessionIDs])
        XCTAssertEqual(store.closeWorkspace?.summary, "")
        XCTAssertEqual(store.closeWorkspace?.phase, .ready(changes: ["Preferred project progress"]))
    }

    func test79_projectSetupRecoversFromAWorkspaceChangedRefusal() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        // The helper already closed the project's default root session; that
        // is setup noise, not something this test is about, so it's carried
        // forward as a baseline rather than asserted away.
        let closedIDsAfterSetup = spy.closedIDs
        let sessionIDs = Set(store.sessions.filter {
            $0.target == .workspace(projectPath: workspace.projectPath, name: workspace.name)
        }.map(\.id))
        fake.previewResults = [
            .failure(.noTrunk("no trunk")),
            .success(LandPreview(
                bookmark: "main", bookmarkCommit: "", commits: [LandCommit(id: "old", subject: "Initial setup")],
                conflicts: [], needsMessage: false
            )),
            .failure(.noTrunk("still no trunk")),
            .success(LandPreview(
                bookmark: "main", bookmarkCommit: "", commits: [LandCommit(id: "new", subject: "Current setup")],
                conflicts: [], needsMessage: false
            )),
        ]
        fake.landWorkspaceHandler = { _, _, createTrunk in
            XCTAssertEqual(createTrunk, "main")
            throw EngineError.workspaceChanged("the workspace changed")
        }

        await store.prepareCloseWorkspace(workspace.id)
        await store.setUpProjectAndCloseWorkspace()

        XCTAssertEqual(fake.landCalls.map(\.createTrunk), ["main"])
        XCTAssertEqual(spy.resumeCalls, [sessionIDs])
        XCTAssertEqual(spy.closedIDs, closedIDsAfterSetup)
        XCTAssertTrue(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertEqual(fake.previewLandCalls.map(\.createTrunk), [nil, "main", nil, "main"])
        XCTAssertEqual(store.closeWorkspace?.phase, .projectSetupRequired(changes: ["Current setup"], needsMessage: false))
    }
    func test80_staleRefreshCannotOverwriteReplacementSheetForSameWorkspace() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let workspace = await makeClosableWorkspace(store: store, fake: fake)
        fake.nextPreviewResult = .success(LandPreview(
            bookmark: "main", bookmarkCommit: "old", commits: [LandCommit(id: "old", subject: "Old change")],
            conflicts: [], needsMessage: false
        ))
        await store.prepareCloseWorkspace(workspace.id)
        fake.landWorkspaceHandler = { _, _, _ in
            throw EngineError.workspaceChanged("changed")
        }
        let refreshStarted = expectation(description: "stale refresh suspended")
        var continuation: CheckedContinuation<LandPreview, Error>?
        fake.previewLandHandler = { _, _ in
            try await withCheckedThrowingContinuation { suspended in
                continuation = suspended
                refreshStarted.fulfill()
            }
        }

        let staleClose = Task { await store.addChangesAndCloseWorkspace() }
        await fulfillment(of: [refreshStarted], timeout: 2)
        let replacement = CloseWorkspacePresentation(
            workspaceID: workspace.id,
            workspaceName: workspace.displayName,
            projectPath: workspace.projectPath,
            projectName: "Replacement",
            phase: .ready(changes: ["Replacement change"])
        )
        store.closeWorkspace = replacement
        continuation!.resume(returning: LandPreview(
            bookmark: "main", bookmarkCommit: "stale", commits: [LandCommit(id: "stale", subject: "Stale result")],
            conflicts: [], needsMessage: false
        ))
        await staleClose.value

        XCTAssertEqual(store.closeWorkspace, replacement)
    }

    // MARK: - 90: deferred reconciliation with a live project-root session

    // test33 already proves the no-live-root-session case reconciles
    // automatically (makeClosableWorkspace's fixture has none), so there is
    // no separate "reconciles immediately" test here — that would just be
    // test33 again under a new name.

    func test90_addAndCloseWithLiveRootSessionDefersReconciliation() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let path = "/tmp/proj-live-root"
        let workspace = await makeClosableWorkspace(store: store, fake: fake, path: path)
        // Unlike the default fixture, this test wants the project root to
        // still have a session of its own when the close completes.
        store.newSession(in: .root(projectPath: path))
        let rootSessionID = store.sessions.first { $0.target == .root(projectPath: path) }!.id
        let workspaceSessionIDs = store.sessions.filter {
            $0.target == .workspace(projectPath: workspace.projectPath, name: workspace.name)
        }.map(\.id)
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "ignored",
                bookmarkCommit: "ignored",
                commits: [LandCommit(id: "1", subject: "Change")],
                conflicts: [],
                needsMessage: false
            )
        )

        await store.prepareCloseWorkspace(workspace.id)
        await store.addChangesAndCloseWorkspace()

        XCTAssertTrue(
            fake.rebaseOntoTrunkCalls.isEmpty,
            "a live root session must defer automatic reconciliation rather than rewrite the working copy under it"
        )
        XCTAssertTrue(store.projectWorkingCopyAttention.contains(path))
        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .success(addedChanges: 1, notice: AppStore.deferredReconciliationNotice)
        )
        XCTAssertFalse(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertTrue(Set(spy.closedIDs).isSuperset(of: workspaceSessionIDs))
        XCTAssertTrue(workspaceSessionIDs.allSatisfy { id in !store.sessions.contains { $0.id == id } })
        XCTAssertTrue(
            store.sessions.contains { $0.id == rootSessionID },
            "the project's own live session must survive the deferred close"
        )
    }

    func test90b_deferredReconciliationComposesTheCleanupWarningIntoOneNotice() async {
        let fake = FakeWorkspaceEngine()
        let (store, spy, _) = TestSupport.makeStore(engine: fake)
        let path = "/tmp/proj-live-root-warning"
        let workspace = await makeClosableWorkspace(store: store, fake: fake, path: path)
        store.newSession(in: .root(projectPath: path))
        let workspaceSessionID = store.sessions.first {
            $0.target == .workspace(projectPath: workspace.projectPath, name: workspace.name)
        }!.id
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "ignored",
                bookmarkCommit: "ignored",
                commits: [LandCommit(id: "1", subject: "Change")],
                conflicts: [],
                needsMessage: false
            )
        )
        fake.nextLandResult = .success(
            LandResult(
                commitID: "abc",
                bookmark: "main",
                cleanupWarning: "The workspace folder couldn't be moved to the Bin."
            )
        )

        await store.prepareCloseWorkspace(workspace.id)
        await store.addChangesAndCloseWorkspace()

        XCTAssertTrue(fake.rebaseOntoTrunkCalls.isEmpty)
        XCTAssertTrue(store.projectWorkingCopyAttention.contains(path))
        XCTAssertEqual(
            store.closeWorkspace?.phase,
            .success(
                addedChanges: 1,
                notice: "The workspace folder couldn't be moved to the Bin.\n"
                    + AppStore.deferredReconciliationNotice
            )
        )
        // The deferral is about the PROJECT's working copy; the workspace
        // itself is still gone.
        XCTAssertFalse(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertFalse(store.sessions.contains { $0.id == workspaceSessionID })
        XCTAssertTrue(spy.closedIDs.contains(workspaceSessionID))
    }

    func test90c_manualRefreshStaysUngatedWithLiveRootSession() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let path = "/tmp/proj-live-root-manual-refresh"
        let workspace = await makeClosableWorkspace(store: store, fake: fake, path: path)
        store.newSession(in: .root(projectPath: path))
        fake.nextPreviewResult = .success(
            LandPreview(
                bookmark: "ignored",
                bookmarkCommit: "ignored",
                commits: [LandCommit(id: "1", subject: "Change")],
                conflicts: [],
                needsMessage: false
            )
        )

        await store.prepareCloseWorkspace(workspace.id)
        await store.addChangesAndCloseWorkspace()
        XCTAssertTrue(
            store.projectWorkingCopyAttention.contains(path),
            "setup: the close must have deferred reconciliation for this test to be meaningful"
        )

        fake.nextRebaseResult = .success(0)
        await store.refreshProjectWorkspace(path)

        XCTAssertEqual(
            fake.rebaseOntoTrunkCalls, [path],
            "manual refresh must stay ungated even though the project root has a live session"
        )
        XCTAssertFalse(store.projectWorkingCopyAttention.contains(path))
    }

    // MARK: - 91: session-stop disclosure

    func test91_closeWorkspaceSessionCountIsZeroWithoutASheet() {
        let (store, _, _) = TestSupport.makeStore()
        let path = "/tmp/proj-no-sheet"
        store.addProject(path: path)
        store.newSession(in: .root(projectPath: path))

        XCTAssertEqual(
            store.closeWorkspaceSessionCount, 0,
            "with no close sheet open there is nothing to warn about stopping"
        )
    }

    func test91b_closeWorkspaceSessionCountCountsOnlyTheWorkspaceUnderReview() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let path = "/tmp/proj-91b"
        let workspace = await makeClosableWorkspace(store: store, fake: fake, path: path)
        // makeClosableWorkspace already leaves one session in the workspace
        // under review; add a second so the count distinguishes "1" from
        // "every session in the workspace".
        store.newSession(in: .workspace(projectPath: path, name: workspace.name))
        // A root session on the SAME project must never be counted — only
        // workspace-targeted rows are sessions the close sheet will stop.
        store.newSession(in: .root(projectPath: path))
        // A session in an unrelated workspace must not leak into the count.
        _ = await makeClosableWorkspace(store: store, fake: fake, path: "/tmp/proj-91b-other")
        fake.nextPreviewResult = .failure(.nothingToLand("nothing"))

        await store.prepareCloseWorkspace(workspace.id)

        XCTAssertEqual(
            store.closeWorkspaceSessionCount, 2,
            "the sheet must warn about exactly the sessions running in the workspace being closed"
        )
    }

    func test91c_closeWorkspaceSessionCountFollowsSessionsClosedWhileTheSheetIsOpen() async {
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        let path = "/tmp/proj-91c"
        let workspace = await makeClosableWorkspace(store: store, fake: fake, path: path)
        store.newSession(in: .workspace(projectPath: path, name: workspace.name))
        let workspaceSessionIDs = store.sessions
            .filter { $0.target == .workspace(projectPath: path, name: workspace.name) }
            .map(\.id)
        XCTAssertEqual(workspaceSessionIDs.count, 2, "setup: the workspace must start with two sessions")
        fake.nextPreviewResult = .failure(.nothingToLand("nothing"))
        await store.prepareCloseWorkspace(workspace.id)
        XCTAssertEqual(store.closeWorkspaceSessionCount, 2)

        store.closeSession(workspaceSessionIDs[0])

        XCTAssertEqual(
            store.closeWorkspaceSessionCount, 1,
            "the live count must drop when a session is closed while the sheet is still open"
        )

        store.cancelCloseWorkspace()

        XCTAssertEqual(
            store.closeWorkspaceSessionCount, 0,
            "with the sheet dismissed there is no longer a workspace under review"
        )
    }
}
