import AppKit
import GhosttyTerminal
import XCTest
@testable import Agents

/// `TerminalCenter`'s pane behavior: surfaces keyed by pane id and grouped
/// by session, with a single pane as the degenerate tree. What these tests
/// pin is the session-facing contract from the design doc — a pane's exit
/// collapses its node while the *last* pane's exit removes the session; any
/// pane's signals light up the one session row; the focused pane's title
/// drives the row title; the resume hint prints once and only in the
/// initial pane; quiesce resets a split session back to a single pane.
///
/// No real processes are involved anywhere here: views are created but never
/// put in a window, so libghostty never spawns a surface, exactly like the
/// existing `TerminalCenterTests`. Process exits are simulated by calling
/// the pane's delegate proxy directly.
@MainActor
final class TerminalCenterPaneTests: XCTestCase {
    private let sessionID = "session-under-test"

    private func makeSession(
        in center: TerminalCenter,
        restoredResume: SessionResumeMetadata? = nil
    ) -> TerminalView {
        center.terminalView(
            for: sessionID,
            workingDirectory: "/tmp",
            restoredResume: restoredResume
        )!
    }

    private func proxy(forPane paneID: UUID, in center: TerminalCenter) -> SessionDelegateProxy {
        center.view(forPane: paneID)!.delegate as! SessionDelegateProxy
    }

    // MARK: - Creation and splitting

    func testNewSessionIsASinglePaneTreeFocusedOnTheInitialPane() {
        let center = TerminalCenter()
        let view = makeSession(in: center)

        let layout = center.layouts[sessionID]
        XCTAssertNotNil(layout, "creating a session's terminal must give it a pane layout — the host view lays out panes from this and would render nothing without it")
        XCTAssertEqual(layout?.paneCount, 1)
        XCTAssertEqual(layout?.focusedPane, layout?.initialPane)
        XCTAssertTrue(
            center.view(forPane: layout!.initialPane) === view,
            "the degenerate single-pane tree must be the same surface terminalView(for:) returns — two different views for one session would blank whichever one the host doesn't mount"
        )
    }

    func testSplitPaneAddsAFocusedPaneWithTheSessionsEnvironment() {
        let center = TerminalCenter()
        _ = makeSession(in: center)

        let newPane = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp/elsewhere")

        XCTAssertNotNil(newPane)
        let layout = center.layouts[sessionID]!
        XCTAssertEqual(layout.paneCount, 2)
        XCTAssertEqual(
            layout.focusedPane, newPane,
            "a split is a request to start working in the new pane — it must take focus, matching every terminal splitter"
        )
        let newView = center.view(forPane: newPane!)!
        XCTAssertEqual(
            newView.configuration.envVars["AGENTS_SESSION_ID"], sessionID,
            "every pane must share the session's AGENTS_SESSION_ID — a pane with its own id (or none) could never scope a review back to its sidebar row"
        )
        XCTAssertEqual(newView.configuration.envVars["AGENTS_APP"], "1")
        XCTAssertEqual(
            newView.configuration.envVars["AGENTS_PANE_ID"], newPane!.uuidString,
            "each pane must carry its OWN id — the hook reports over the session's shared socket, and this is the only thing that tells the app which pane's agent is talking"
        )
        XCTAssertEqual(
            center.view(forPane: center.layouts[sessionID]!.initialPane)!.configuration.envVars["AGENTS_PANE_ID"],
            center.layouts[sessionID]!.initialPane.uuidString
        )
        XCTAssertEqual(
            newView.configuration.workingDirectory, "/tmp/elsewhere",
            "a new pane spawns in the session's working directory passed by the caller"
        )
    }

    func testSplitPaneRefusesUnknownAndQuiescedSessions() async {
        let center = TerminalCenter()
        XCTAssertNil(
            center.splitPane(in: "never-seen", axis: .horizontal, workingDirectory: "/tmp"),
            "splitting a session with no live layout must refuse — there is no pane to split, and inventing a session here would leak a surface no row owns"
        )

        _ = makeSession(in: center)
        await center.quiesceSessions([sessionID])
        XCTAssertNil(
            center.splitPane(in: sessionID, axis: .vertical, workingDirectory: "/tmp"),
            "a quiesced session's surfaces are being managed by a close operation — splitting one would spawn a shell the manager doesn't know it has to stop"
        )
    }

    // MARK: - Pane exit

    func testPaneExitCollapsesItsNodeAndKeepsTheSessionAlive() {
        let center = TerminalCenter()
        let initialView = makeSession(in: center)
        let newPane = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")!

        var exitedSessions: [String] = []
        var teardowns: [String] = []
        center.onProcessExit = { exitedSessions.append($0) }
        center.onSessionTeardown = { teardowns.append($0) }

        proxy(forPane: newPane, in: center).terminalDidClose(processAlive: false)

        XCTAssertTrue(
            exitedSessions.isEmpty,
            "a pane exit that leaves other panes alive must NOT report session process-exit — that callback removes the sidebar row, and the session is still running in its remaining pane"
        )
        XCTAssertTrue(
            teardowns.isEmpty,
            "a pane exit is not a session teardown — firing the teardown hook here would cancel the session's open review out from under it"
        )
        let layout = center.layouts[sessionID]!
        XCTAssertEqual(layout.paneCount, 1, "the exited pane's tree node must collapse")
        XCTAssertNil(center.view(forPane: newPane), "the exited pane's surface must be freed")
        XCTAssertTrue(
            center.view(forPane: layout.initialPane) === initialView,
            "the surviving pane keeps its live surface untouched"
        )
        XCTAssertEqual(
            layout.focusedPane, layout.initialPane,
            "focus must move to the pane that inherits the freed space"
        )
    }

    func testLastPaneExitRemovesTheSessionThroughTheExistingClosePath() {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        let initialPane = center.layouts[sessionID]!.initialPane

        var exitedSessions: [String] = []
        var teardowns: [String] = []
        center.onProcessExit = { exitedSessions.append($0) }
        center.onSessionTeardown = { teardowns.append($0) }

        proxy(forPane: initialPane, in: center).terminalDidClose(processAlive: false)

        XCTAssertEqual(
            exitedSessions, [sessionID],
            "the last pane's exit must reach onProcessExit under the SESSION id — this is the path that removes the sidebar row, and a pane id here would remove nothing"
        )
        XCTAssertEqual(teardowns, [sessionID])
        XCTAssertNil(center.layouts[sessionID], "the session's layout must be gone after its last pane exits")
    }

    func testExitOfFocusedMiddlePaneMovesFocusToTheInheritingPane() {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        let second = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")!
        let third = center.splitPane(in: sessionID, axis: .vertical, workingDirectory: "/tmp")!

        // third is focused (freshly split from second); its exit hands the
        // space back to second.
        proxy(forPane: third, in: center).terminalDidClose(processAlive: false)

        let layout = center.layouts[sessionID]!
        XCTAssertEqual(layout.paneCount, 2)
        XCTAssertEqual(
            layout.focusedPane, second,
            "when the focused pane's process exits, focus must land on the pane that inherits its region — leaving focus on a freed pane would strand every keyboard pane command"
        )
    }

    // MARK: - closeFocusedPane

    func testCloseFocusedPaneRefusesSinglePaneSessions() {
        let center = TerminalCenter()
        _ = makeSession(in: center)

        XCTAssertFalse(
            center.closeFocusedPane(in: sessionID),
            "closing the last pane is closing the session, and that decision belongs to the explicit close-session command — the pane command must refuse so the caller can beep instead of silently killing the row"
        )
        XCTAssertEqual(center.layouts[sessionID]?.paneCount, 1)
    }

    func testCloseFocusedPaneClosesTheFocusedPaneOfAMultiPaneSession() {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        let newPane = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")!
        var exitedSessions: [String] = []
        center.onProcessExit = { exitedSessions.append($0) }

        XCTAssertTrue(center.closeFocusedPane(in: sessionID))

        let layout = center.layouts[sessionID]!
        XCTAssertEqual(layout.paneCount, 1)
        XCTAssertNil(center.view(forPane: newPane))
        XCTAssertTrue(exitedSessions.isEmpty, "a deliberate pane close is not a session exit")
    }

    // MARK: - Attention aggregation and title routing

    func testSignalsFromEveryPaneAggregateToTheOneSessionRow() {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        let initialPane = center.layouts[sessionID]!.initialPane
        let newPane = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")!

        var received: [(id: String, pane: UUID, signal: AttentionSignal)] = []
        center.onSessionSignal = { received.append(($0, $1, $2)) }

        proxy(forPane: initialPane, in: center).terminalDidRingBell()
        proxy(forPane: newPane, in: center)
            .terminalDidRequestDesktopNotification(title: "agents:status", body: "blocked")

        XCTAssertEqual(
            received.map(\.id), [sessionID, sessionID],
            "a signal from ANY pane must reach the session's one sidebar row, or an agent blocked in a background pane would wait invisibly"
        )
        XCTAssertEqual(
            received.map(\.pane), [initialPane, newPane],
            "each signal must carry its own pane's id — AppStore reduces per pane, and misattributed signals would let one pane's clear erase another's blocked state"
        )
        XCTAssertEqual(received.map(\.signal), [.bell, .structured(.set(.blocked))])
    }

    func testPaneTeardownAnnouncesTheClosedPane() {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        let newPane = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")!

        var closed: [(id: String, pane: UUID)] = []
        center.onPaneClosed = { closed.append(($0, $1)) }

        XCTAssertTrue(center.closeFocusedPane(in: sessionID))

        XCTAssertEqual(closed.map(\.id), [sessionID])
        XCTAssertEqual(
            closed.map(\.pane), [newPane],
            "every pane teardown must announce the closed pane — AppStore drops that pane's attention contribution on this signal, and a missing announcement leaves a closed-while-blocked pane keeping the row red forever"
        )
    }

    // MARK: - Resume-metadata ownership across panes

    private func sendAgentEvent(
        from paneID: UUID, in center: TerminalCenter, agentSessionID: String
    ) {
        proxy(forPane: paneID, in: center).terminalDidRequestDesktopNotification(
            title: AgentSessionEvent.hookNotificationTitle,
            body: #"{"event":"session_start","v":1,"agent":"claude","session_id":"\#(agentSessionID)"}"#
        )
    }

    func testOnlyTheInitialPanesAgentEventsReachTheStore() {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        let initialPane = center.layouts[sessionID]!.initialPane
        let splitPane = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")!

        var events: [(id: String, event: AgentSessionEvent)] = []
        center.onAgentSessionEvent = { id, event, _ in events.append((id, event)) }

        sendAgentEvent(from: splitPane, in: center, agentSessionID: "intruder")
        sendAgentEvent(from: initialPane, in: center, agentSessionID: "owner")

        XCTAssertEqual(
            events.map(\.event.sessionID), ["owner"],
            "only the initial pane's agent may write the row's resume metadata — it is the pane the resume hint is later injected into, and letting a split pane's agent overwrite it would type that agent's --resume command into a different agent's terminal after a relaunch"
        )
    }

    func testAgentEventOwnershipFallsToTheSurvivingPaneWhenTheInitialPaneExits() {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        let initialPane = center.layouts[sessionID]!.initialPane
        let splitPane = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")!

        proxy(forPane: initialPane, in: center).terminalDidClose(processAlive: false)

        var events: [(id: String, event: AgentSessionEvent)] = []
        center.onAgentSessionEvent = { id, event, _ in events.append((id, event)) }
        sendAgentEvent(from: splitPane, in: center, agentSessionID: "survivor")

        XCTAssertEqual(
            events.map(\.event.sessionID), ["survivor"],
            "once the initial pane is gone, the surviving pane is where a quiesce keeps the session and where the resume hint lands — its agent must own the metadata, or resume tracking would silently die with the initial pane"
        )
    }

    // MARK: - Control-socket session events

    func testSocketEventRoutesStatusAndAnnouncementToThePaneItNames() {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        let initialPane = center.layouts[sessionID]!.initialPane
        let splitPane = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")!

        var signals: [(pane: UUID, signal: AttentionSignal)] = []
        center.onSessionSignal = { id, pane, signal in
            XCTAssertEqual(id, self.sessionID)
            signals.append((pane, signal))
        }
        var announced: [String] = []
        center.onAgentSessionEvent = { _, event, _ in announced.append(event.sessionID) }

        let fromSplit = ControlSessionEvent(
            session: sessionID, pane: splitPane, status: .set(.blocked),
            event: AgentSessionEvent(agent: "claude", name: "PreToolUse", sessionID: "intruder", query: nil)
        )
        let fromInitial = ControlSessionEvent(
            session: sessionID, pane: initialPane, status: .clear,
            event: AgentSessionEvent(agent: "claude", name: "PreToolUse", sessionID: "owner", query: nil)
        )

        XCTAssertNil(center.handleControlSessionEvent(fromSplit))
        XCTAssertNil(center.handleControlSessionEvent(fromInitial))

        XCTAssertEqual(
            signals.map(\.pane), [splitPane, initialPane],
            "status must be reduced for the pane the hook ran in — the socket is shared by every pane, so only the AGENTS_PANE_ID the hook forwards can attribute it"
        )
        XCTAssertEqual(signals.map(\.signal), [.structured(.set(.blocked)), .structured(.clear)])
        XCTAssertEqual(
            announced, ["owner"],
            "the socket path must honour the same resume-designate rule as the OSC path: a split pane's agent reports its status but never authors the row's resume record"
        )
    }

    func testSocketEventNamingAnUnknownOrForeignPaneIsRefused() {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        _ = center.terminalView(for: "other-session", workingDirectory: "/tmp", restoredResume: nil)
        let foreignPane = center.layouts["other-session"]!.initialPane
        var signals = 0
        center.onSessionSignal = { _, _, _ in signals += 1 }

        XCTAssertNotNil(
            center.handleControlSessionEvent(
                ControlSessionEvent(session: sessionID, pane: foreignPane, status: .set(.blocked), event: nil)
            ),
            "a pane id that belongs to another session must be refused — applying it would light up a row the reporting agent isn't in"
        )
        XCTAssertNotNil(
            center.handleControlSessionEvent(
                ControlSessionEvent(session: sessionID, pane: UUID(), status: .set(.blocked), event: nil)
            )
        )
        XCTAssertEqual(signals, 0)
    }

    func testSocketEventForATornDownPaneIsRefused() async {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        let initialPane = center.layouts[sessionID]!.initialPane
        let splitPane = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")!
        var signals = 0
        center.onSessionSignal = { _, _, _ in signals += 1 }

        XCTAssertTrue(center.closeFocusedPane(in: sessionID))
        XCTAssertNotNil(
            center.handleControlSessionEvent(
                ControlSessionEvent(session: sessionID, pane: splitPane, status: .clear, event: nil)
            ),
            "a closed pane's id must be refused — AppStore already dropped that pane's attention on teardown, and a late report would resurrect it under a dead id"
        )

        await center.quiesceSessions([sessionID])
        XCTAssertNotNil(
            center.handleControlSessionEvent(
                ControlSessionEvent(session: sessionID, pane: initialPane, status: .clear, event: nil)
            ),
            "a quiesced survivor keeps its pane id for the fresh shell that follows, but until that shell exists no process can honestly report for it"
        )
        XCTAssertEqual(signals, 0)
    }

    func testTitlesCarryTheRolesTheirPaneHolds() {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        let initialPane = center.layouts[sessionID]!.initialPane
        let newPane = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")!

        var titles: [(title: String, roles: SessionTitleRoles)] = []
        center.onTitleChange = { id, title, roles in
            XCTAssertEqual(id, self.sessionID)
            titles.append((title, roles))
        }

        // newPane is focused but NOT the resume designate: display only.
        proxy(forPane: newPane, in: center).terminalDidChangeTitle("focused work")
        // initialPane is the designate but NOT focused: resume only — its
        // agent owns the row's resume metadata, and its title must be able
        // to label that record without renaming the row.
        proxy(forPane: initialPane, in: center).terminalDidChangeTitle("background work")

        XCTAssertEqual(titles.map(\.title), ["focused work", "background work"])
        XCTAssertEqual(
            titles.map(\.roles), [[.display], [.resume]],
            "a focused sibling's title must arrive display-only, or it would rewrite the designate agent's resume label into another pane's task name; the designate's must arrive resume-only, or an unfocused pane would rename the row out from under the user"
        )

        // Focus moving back re-announces the remembered title with BOTH
        // roles — the initial pane is now focused and designate at once.
        center.focusPane(initialPane)
        XCTAssertEqual(titles.last?.title, "background work")
        XCTAssertEqual(titles.last?.roles, [.display, .resume])
    }

    func testATitleFromAPaneWithNoRolesIsRememberedButNotForwarded() {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        _ = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")!
        let second = center.layouts[sessionID]!.focusedPane
        let third = center.splitPane(in: sessionID, axis: .vertical, workingDirectory: "/tmp")!
        _ = third // focused; `second` is now neither focused nor designate

        var titles: [String] = []
        center.onTitleChange = { _, title, _ in titles.append(title) }

        proxy(forPane: second, in: center).terminalDidChangeTitle("side work")
        XCTAssertTrue(
            titles.isEmpty,
            "a pane that is neither focused nor the resume designate has no say over the row's name or its resume label — its title is remembered for a later focus change, nothing more"
        )

        center.focusPane(second)
        XCTAssertEqual(
            titles, ["side work"],
            "the remembered title must surface the moment its pane gains a role"
        )
    }

    func testResumeLabelFreezesWhenTheAuthoringPaneDies() {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        let initialPane = center.layouts[sessionID]!.initialPane
        let splitPane = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")!

        // The initial pane's agent authors the resume record.
        sendAgentEvent(from: initialPane, in: center, agentSessionID: "owner")

        var roles: [SessionTitleRoles] = []
        center.onTitleChange = { _, _, r in roles.append(r) }

        // The authoring pane dies; splitPane inherits designation, but the
        // record still describes the dead agent's conversation.
        proxy(forPane: initialPane, in: center).terminalDidClose(processAlive: false)

        proxy(forPane: splitPane, in: center).terminalDidChangeTitle("inheritor's task")
        XCTAssertEqual(
            roles, [[.display]],
            "the inheriting pane's title must NOT carry .resume while the dead author's record stands — relabeling it would advertise \"Task B … --resume A\", a hint that lies about what it resumes"
        )

        // Its agent's first event re-authors the record; from then on its
        // titles label what is now genuinely its own record.
        sendAgentEvent(from: splitPane, in: center, agentSessionID: "new-owner")
        proxy(forPane: splitPane, in: center).terminalDidChangeTitle("inheritor's task 2")
        XCTAssertEqual(roles.last, [.display, .resume])
    }

    func testARestoredRecordIsFrozenUntilAnAgentEventReauthorsIt() {
        let center = TerminalCenter()
        let metadata = SessionResumeMetadata(
            agent: "claude", sessionID: "old-conversation", title: "Old task", prompt: nil
        )
        _ = makeSession(in: center, restoredResume: metadata)
        let initialPane = center.layouts[sessionID]!.initialPane

        var roles: [SessionTitleRoles] = []
        center.onTitleChange = { _, _, r in roles.append(r) }

        proxy(forPane: initialPane, in: center).terminalDidChangeTitle("✳ New task")
        XCTAssertEqual(
            roles, [[.display]],
            "a restored row's record was authored by a process that predates this launch — a fresh shell's decorated title arriving before any agent event must not relabel it, or the hint would read \"New task … --resume old-conversation\", and if no agent ever announces, that lie would persist"
        )

        sendAgentEvent(from: initialPane, in: center, agentSessionID: "new-conversation")
        proxy(forPane: initialPane, in: center).terminalDidChangeTitle("✳ New task 2")
        XCTAssertEqual(roles.last, [.display, .resume], "an agent event re-authors the record, restoring the pane's right to label what is now its own conversation")
    }

    func testQuiesceFreezesAnAuthoredRecordUntilReauthored() async {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        let initialPane = center.layouts[sessionID]!.initialPane
        sendAgentEvent(from: initialPane, in: center, agentSessionID: "owner")

        await center.quiesceSessions([sessionID])
        center.resumeSessions([sessionID])
        _ = center.terminalView(for: sessionID, workingDirectory: "/tmp", restoredResume: nil)

        var roles: [SessionTitleRoles] = []
        center.onTitleChange = { _, _, r in roles.append(r) }
        proxy(forPane: initialPane, in: center).terminalDidChangeTitle("✳ Fresh shell task")

        XCTAssertEqual(
            roles, [[.display]],
            "the record survives a quiesce in AppStore but its author's process does not — the fresh shell spawned after resume must not relabel the old conversation's record until its own agent event re-authors it"
        )
    }

    func testAgentEventsCarryTheAuthoringPanesOwnTitle() {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        let initialPane = center.layouts[sessionID]!.initialPane
        let splitPane = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")!

        // The focused split pane titles itself; the initial (designate)
        // pane titles itself differently.
        proxy(forPane: splitPane, in: center).terminalDidChangeTitle("sibling task")
        proxy(forPane: initialPane, in: center).terminalDidChangeTitle("owner task")

        var attachedTitles: [String?] = []
        center.onAgentSessionEvent = { _, _, title in attachedTitles.append(title) }
        sendAgentEvent(from: initialPane, in: center, agentSessionID: "owner")

        XCTAssertEqual(
            attachedTitles, ["owner task"],
            "an agent event must carry ITS OWN pane's title as the label seed — the row's display name is the focused sibling's, and seeding from it would put another agent's task name on this record"
        )
    }

    func testFocusingAPaneWithNoTitleLeavesTheRowTitleAlone() {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        let initialPane = center.layouts[sessionID]!.initialPane
        let newPane = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")!
        _ = newPane

        var titles: [String] = []
        center.onTitleChange = { _, title, _ in titles.append(title) }

        center.focusPane(initialPane)

        XCTAssertTrue(
            titles.isEmpty,
            "a pane that never announced a title must not emit one on focus — flashing the row back to a default name would erase a perfectly good remembered title"
        )
    }

    // MARK: - Directional focus

    func testMoveFocusCrossesTheSplitAndStopsAtTheEdge() {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        let initialPane = center.layouts[sessionID]!.initialPane
        let newPane = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")!

        // newPane (right) is focused; left goes back to the initial pane.
        XCTAssertTrue(center.moveFocus(in: sessionID, direction: .left))
        XCTAssertEqual(center.layouts[sessionID]?.focusedPane, initialPane)

        XCTAssertFalse(
            center.moveFocus(in: sessionID, direction: .left),
            "moving past the layout's edge must report failure so the caller can beep or pass the key on rather than pretending focus moved"
        )
        XCTAssertEqual(center.layouts[sessionID]?.focusedPane, initialPane)

        XCTAssertTrue(center.moveFocus(in: sessionID, direction: .right))
        XCTAssertEqual(center.layouts[sessionID]?.focusedPane, newPane)
    }

    // MARK: - Resume hint

    func testResumeHintPrintsOnceAndOnlyInTheInitialPane() async {
        var deliveries: [(view: TerminalView, text: String)] = []
        let center = TerminalCenter(textDelivery: { view, text in
            deliveries.append((view, text))
        })
        let metadata = SessionResumeMetadata(
            agent: "omp", sessionID: "omp-1", title: "Restored work", prompt: nil
        )
        let initialView = makeSession(in: center, restoredResume: metadata)
        _ = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")

        let hostView = NSView()
        hostView.addSubview(initialView)
        let newPaneID = center.layouts[sessionID]!.paneIDs.first {
            $0 != center.layouts[sessionID]!.initialPane
        }!
        hostView.addSubview(center.view(forPane: newPaneID)!)

        center.showResumeHintIfNeeded(for: sessionID)
        center.showResumeHintIfNeeded(for: sessionID)
        await drainMainQueue()
        center.showResumeHintIfNeeded(for: sessionID)
        await drainMainQueue()

        XCTAssertEqual(deliveries.count, 1, "the resume hint must print exactly once per restored session")
        XCTAssertTrue(
            deliveries[0].view === initialView,
            "the resume hint must land in the session's INITIAL pane — printing it into a split would inject shell input into whatever the user is doing there"
        )
    }

    // MARK: - Teardown paths

    func testCloseSessionTearsDownEveryPane() {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        let initialPane = center.layouts[sessionID]!.initialPane
        let newPane = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")!

        center.closeSession(sessionID)

        XCTAssertNil(center.layouts[sessionID])
        XCTAssertNil(center.view(forPane: initialPane))
        XCTAssertNil(
            center.view(forPane: newPane),
            "closing a session must free every pane's surface — a leaked pane keeps a login shell running that no row owns"
        )
    }

    func testQuiesceResetsASplitSessionToASingleInitialPane() async {
        let center = TerminalCenter()
        let initialView = makeSession(in: center)
        let initialPane = center.layouts[sessionID]!.initialPane
        let newPane = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")!

        await center.quiesceSessions([sessionID])

        XCTAssertNil(center.view(forPane: newPane), "quiesce must free every non-surviving pane")
        let layout = center.layouts[sessionID]!
        XCTAssertEqual(
            layout.paneCount, 1,
            "split layout is deliberately not preserved across quiesce — the processes don't survive, so the session must come back as a single pane, same as relaunch"
        )
        XCTAssertEqual(layout.initialPane, initialPane)

        center.resumeSessions([sessionID])
        let resumedView = center.terminalView(
            for: sessionID, workingDirectory: "/tmp", restoredResume: nil
        )
        XCTAssertTrue(
            resumedView === initialView,
            "the surviving pane must keep its NSView identity across quiesce/resume — recreating it would blank the mounted surface"
        )
    }

    func testQuiesceAnnouncesClosureOfEveryPaneIncludingTheSurvivor() async {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        let initialPane = center.layouts[sessionID]!.initialPane
        let newPane = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")!

        var closed: Set<UUID> = []
        center.onPaneClosed = { id, pane in
            XCTAssertEqual(id, self.sessionID)
            closed.insert(pane)
        }

        await center.quiesceSessions([sessionID])

        XCTAssertEqual(
            closed, [initialPane, newPane],
            "quiesce must announce the SURVIVOR's closure too, not just its siblings' — the survivor keeps its view and pane id but its process dies with the rest, and stale attention under the reused id would carry an old structured latch or blocked state onto the fresh shell spawned after resume"
        )
    }

    func testQuiesceSurvivorFallsBackToFirstLeafWhenInitialPaneWasClosed() async {
        let center = TerminalCenter()
        _ = makeSession(in: center)
        let initialPane = center.layouts[sessionID]!.initialPane
        let newPane = center.splitPane(in: sessionID, axis: .horizontal, workingDirectory: "/tmp")!

        // The initial pane's process exits; the split pane inherits everything.
        proxy(forPane: initialPane, in: center).terminalDidClose(processAlive: false)
        XCTAssertEqual(center.layouts[sessionID]?.paneIDs, [newPane])

        await center.quiesceSessions([sessionID])

        let layout = center.layouts[sessionID]!
        XCTAssertEqual(
            layout.paneIDs, [newPane],
            "with the original initial pane gone, quiesce must keep the remaining pane rather than keying its survivor logic to a pane that no longer exists"
        )
        XCTAssertNotNil(center.view(forPane: newPane))
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
