import XCTest
@testable import Agents

/// `ControlServer.decide` is the wire contract the revdiff launcher is
/// written against: one JSON line in, either a refusal string (which the
/// launcher prints verbatim to the agent) or the review to run. Each refusal
/// pinned here fails silently in production if it regresses — the launcher
/// just reports whatever the app said, so a wrong decision here becomes a
/// review opening for the wrong session or a misleading error at the agent.
final class ControlServerTests: XCTestCase {
    func testWellFormedRequestRuns() {
        let decision = ControlServer.decide(
            line: #"{"cmd":"overlay-run","command":"/tmp/launch.sh","cwd":"/tmp/repo","session":"row-1"}"#
        )
        XCTAssertEqual(
            decision,
            .run(command: "/tmp/launch.sh", cwd: "/tmp/repo", session: "row-1")
        )
    }

    func testMalformedJSONIsRefused() {
        XCTAssertEqual(
            ControlServer.decide(line: "not json"),
            .refuse("malformed request")
        )
    }

    func testUnknownCmdIsRefused() {
        XCTAssertEqual(
            ControlServer.decide(line: #"{"cmd":"self-destruct"}"#),
            .refuse("unknown cmd: self-destruct")
        )
    }

    func testMissingCommandIsRefused() {
        XCTAssertEqual(
            ControlServer.decide(line: #"{"cmd":"overlay-run","session":"row-1"}"#),
            .refuse("missing command")
        )
    }

    /// A launcher that predates session scoping omits `session`. The refusal
    /// message is user-facing guidance (the launcher prints it verbatim), so
    /// it must name the actual fix rather than a generic "bad request" —
    /// this is the only breadcrumb anyone gets after updating the app but
    /// not the launcher.
    func testMissingSessionIsRefusedWithUpgradeGuidance() {
        for line in [
            #"{"cmd":"overlay-run","command":"/tmp/launch.sh"}"#,
            #"{"cmd":"overlay-run","command":"/tmp/launch.sh","session":""}"#,
        ] {
            let decision = ControlServer.decide(line: line)
            guard case .refuse(let message) = decision else {
                XCTFail("a request without a session must be refused, got \(decision) for \(line)")
                continue
            }
            XCTAssertTrue(
                message.contains("AGENTS_SESSION_ID"),
                "the missing-session refusal must tell the reader what to forward — it is printed verbatim by the launcher and is the only clue after an app/launcher version skew"
            )
        }
    }

    /// The launcher may omit cwd (it never does today, but the field is
    /// optional in the wire format) — the app falls back to home rather than
    /// refusing, matching the pre-scoping behavior.
    func testMissingCwdFallsBackToHome() {
        let decision = ControlServer.decide(
            line: #"{"cmd":"overlay-run","command":"/tmp/launch.sh","session":"row-1"}"#
        )
        XCTAssertEqual(
            decision,
            .run(command: "/tmp/launch.sh", cwd: NSHomeDirectory(), session: "row-1")
        )
    }

    // MARK: - session-event

    /// The hook's wire form (see hooks/agents-status.sh). Every field the
    /// hook can send, in the exact spelling it sends it.
    private let pane = "7F4B1B6E-9E1E-4B7D-9C1A-1F2E3D4C5B6A"

    func testSessionEventDecodesAndNormalizesLikeTheOSCForm() {
        let decision = ControlServer.decide(
            line: #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"UserPromptSubmit","status":"clear","agent":" Claude ","agent_session_id":" abc-123 ","prompt":"Fix\n\tthe   parser"}"#
        )

        XCTAssertEqual(
            decision,
            .sessionEvent(ControlSessionEvent(
                session: "row-1",
                pane: UUID(uuidString: pane)!,
                status: .clear,
                event: AgentSessionEvent(
                    agent: "claude", name: "UserPromptSubmit", sessionID: "abc-123", query: "Fix the parser"
                )
            )),
            "the socket form must normalize exactly like the OSC form — lowercase agent, trimmed id, one-line prompt — so a session looks the same downstream whichever transport announced it"
        )
    }

    func testSessionEventMayCarryStatusAlone() {
        let decision = ControlServer.decide(
            line: #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"Stop","status":"your-turn"}"#
        )

        XCTAssertEqual(
            decision,
            .sessionEvent(ControlSessionEvent(
                session: "row-1", pane: UUID(uuidString: pane)!, status: .set(.yourTurn), event: nil
            )),
            "a hook that could not identify its harness still reports attention state — the sidebar dot must not depend on the process-tree walk succeeding"
        )
    }

    func testSessionEventMayCarryTheAnnouncementAlone() {
        let decision = ControlServer.decide(
            line: #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"SubagentStop","agent":"codex","agent_session_id":"x-1"}"#
        )

        XCTAssertEqual(
            decision,
            .sessionEvent(ControlSessionEvent(
                session: "row-1",
                pane: UUID(uuidString: pane)!,
                status: nil,
                event: AgentSessionEvent(agent: "codex", name: "SubagentStop", sessionID: "x-1", query: nil)
            )),
            "an event with no attention meaning still announces the session — every event re-announces, so a hook registered on an unmapped event alone keeps resume working"
        )
    }

    func testSessionEventWithNothingToApplyIsRefused() {
        XCTAssertEqual(
            ControlServer.decide(
                line: #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"PreCompact"}"#
            ),
            .refuse("nothing to apply: no status and no agent session"),
            "a line that would change nothing is a sender bug, and accepting it as ok would hide that from anyone debugging with nc by hand"
        )
    }

    func testSessionEventUnknownStatusTokenIsRefused() {
        XCTAssertEqual(
            ControlServer.decide(
                line: #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"Stop","status":"done"}"#
            ),
            .refuse("unknown status: done"),
            "the status vocabulary is shared with the OSC form and must not grow silently — an unknown token is refused, never mapped to some default state"
        )
    }

    func testSessionEventMissingOrMalformedPaneIsRefused() {
        for line in [
            #"{"cmd":"session-event","session":"row-1","event":"Stop","status":"clear"}"#,
            #"{"cmd":"session-event","session":"row-1","pane":"","event":"Stop","status":"clear"}"#,
        ] {
            guard case .refuse(let message) = ControlServer.decide(line: line) else {
                return XCTFail("a session event without a pane must be refused: \(line)")
            }
            XCTAssertTrue(
                message.contains("AGENTS_PANE_ID"),
                "the missing-pane refusal must name the variable the hook forwards — an app/hook version skew is the only way to get here, and this message is the only clue"
            )
        }
        XCTAssertEqual(
            ControlServer.decide(
                line: #"{"cmd":"session-event","session":"row-1","pane":"nope","event":"Stop","status":"clear"}"#
            ),
            .refuse("malformed pane: nope")
        )
    }

    func testSessionEventMissingSessionIsRefusedWithUpgradeGuidance() {
        guard case .refuse(let message) = ControlServer.decide(
            line: #"{"cmd":"session-event","pane":"\#(pane)","event":"Stop","status":"clear"}"#
        ) else {
            return XCTFail("a session event without a session must be refused")
        }
        XCTAssertTrue(message.contains("AGENTS_SESSION_ID"))
    }

    func testSessionEventMissingEventNameIsRefused() {
        for line in [
            #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","status":"clear"}"#,
            #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"  ","status":"clear"}"#,
        ] {
            XCTAssertEqual(ControlServer.decide(line: line), .refuse("missing event"))
        }
    }

    func testSessionEventHalfAnAgentIdentityIsRefused() {
        XCTAssertEqual(
            ControlServer.decide(
                line: #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"Stop","agent":"claude"}"#
            ),
            .refuse("missing agent_session_id")
        )
        XCTAssertEqual(
            ControlServer.decide(
                line: #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"Stop","agent_session_id":"abc"}"#
            ),
            .refuse("missing agent"),
            "an announcement needs both halves — a session id with no harness could never be turned into a resume command, and recording it would freeze the row's record on a lie"
        )
        XCTAssertEqual(
            ControlServer.decide(
                line: #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"Stop","agent":"  ","agent_session_id":"abc"}"#
            ),
            .refuse("blank agent or agent_session_id")
        )
    }
}
