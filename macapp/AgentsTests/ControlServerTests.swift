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
}
