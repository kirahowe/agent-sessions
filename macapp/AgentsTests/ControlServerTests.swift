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
            .run(command: "/tmp/launch.sh", cwd: "/tmp/repo", session: "row-1", env: [:])
        )
    }

    /// The review runs as the overlay surface's own process, in the app's
    /// environment — which for a Finder-launched app is the bare system PATH.
    /// The launcher forwards what its subprocesses need from the shell that
    /// asked; the decision carries it through untouched, and a launcher that
    /// predates the field still runs.
    func testOverlayRunForwardsTheCallersEnvironment() {
        let decision = ControlServer.decide(
            line: #"{"cmd":"overlay-run","command":"/tmp/launch.sh","cwd":"/tmp/repo","session":"row-1","env":{"PATH":"/opt/homebrew/bin:/usr/bin","LANG":"en_GB.UTF-8"}}"#
        )
        XCTAssertEqual(
            decision,
            .run(
                command: "/tmp/launch.sh", cwd: "/tmp/repo", session: "row-1",
                env: ["PATH": "/opt/homebrew/bin:/usr/bin", "LANG": "en_GB.UTF-8"]
            ),
            "the forwarded environment must reach the overlay as sent — it is how revdiff's jj/git/hg subprocesses find their binaries and config from inside an app that has no PATH of its own"
        )
        XCTAssertEqual(
            ControlServer.decide(
                line: #"{"cmd":"overlay-run","command":"/tmp/launch.sh","cwd":"/tmp/repo","session":"row-1","env":{"PATH":1}}"#
            ),
            .refuse("malformed request"),
            "an env that is not a string map is a malformed request, not a review that starts with half an environment"
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
            .run(command: "/tmp/launch.sh", cwd: NSHomeDirectory(), session: "row-1", env: [:])
        )
    }

    /// A build without its overlay wrapper cannot run a review, and the
    /// refusal has to reach the launcher as a JSON line that names the
    /// resource — that line is the only thing the agent ever sees.
    @MainActor
    func testAMissingOverlayWrapperIsRefusedOverTheSocket() async throws {
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("agents-wrapper-test-\(getpid()).sock").path
        let server = ControlServer(overlays: OverlayCenter(wrapperURL: nil), socketPath: socketPath)
        server.validateSession = { $0 == "row-1" }
        server.start()
        defer { server.stop() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socketPath) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "the server never bound its socket")

        let refusal = try await Self.run(
            "/usr/bin/nc", ["-U", "-w", "2", socketPath], environment: ["PATH": "/usr/bin:/bin"],
            stdin: #"{"cmd":"overlay-run","command":"/tmp/launch.sh","cwd":"/tmp","session":"row-1"}"# + "\n"
        )
        XCTAssertTrue(
            refusal.output.contains(#""ok":false"#) && refusal.output.contains("overlay-run.sh"),
            "the refusal must be a JSON line naming the missing resource, got: \(refusal.output)"
        )
    }

    // MARK: - session-event

    @MainActor
    func testTheAppAnswersAnAppliedEventWithSuccessNotTheShutdownFallback() {
        let center = TerminalCenter()
        _ = center.terminalView(for: "row-1", workingDirectory: "/tmp", restoredResume: nil)
        let pane = center.layouts["row-1"]!.initialPane
        let event = ControlSessionEvent(session: "row-1", pane: pane, status: .clear, event: nil)

        XCTAssertNil(
            AgentsApp.applySessionEvent(event, to: center),
            "an applied event must be answered ok — the one-liner this replaced turned the center's nil-for-success into the shutdown refusal, so the hook's log called every good report a failure"
        )
        XCTAssertEqual(
            AgentsApp.applySessionEvent(event, to: nil), "app is shutting down"
        )
        XCTAssertNotNil(
            AgentsApp.applySessionEvent(
                ControlSessionEvent(session: "row-1", pane: UUID(), status: .clear, event: nil), to: center
            ),
            "a genuine refusal must still come through"
        )
    }

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

    func testSessionEventCarriesTheHarnessHome() {
        let decision = ControlServer.decide(
            line: #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"SessionStart","agent":"codex","agent_session_id":"x-1","agent_home":" /Users/kira/.codex-kira "}"#
        )

        XCTAssertEqual(
            decision,
            .sessionEvent(ControlSessionEvent(
                session: "row-1",
                pane: UUID(uuidString: pane)!,
                status: nil,
                event: AgentSessionEvent(
                    agent: "codex", name: "SessionStart", sessionID: "x-1", query: nil, home: "/Users/kira/.codex-kira"
                )
            )),
            "the home the harness ran under rides along with its announcement, trimmed, so the restore banner can prefix the resume command with it"
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

    // MARK: - End to end: the real hook, a real socket

    /// The whole reporting path exactly as the hook drives it: the bundled
    /// script, run the way Claude Code runs it, speaking `nc -U` to a real
    /// `ControlServer` bound on a private path, landing on a
    /// `TerminalCenter` pane. Every other test here pins one link; this one
    /// proves the chain holds. A framing mismatch between the script's line
    /// and the server's reader, a reply that never closes (the hook's `nc`
    /// would sit on it until its timeout, stalling the agent), or a gap in
    /// the closures `AgentsApp` wires would each pass the unit tests and
    /// only show up as a dot that never lights or a banner that never
    /// prints.
    @MainActor
    func testTheRealHookReportsOverTheSocketAndLandsOnItsPane() async throws {
        let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        guard searchPath.split(separator: ":").contains(where: {
            FileManager.default.isExecutableFile(atPath: "\($0)/jq")
        }) else {
            throw XCTSkip("jq is not installed, so the hook cannot run here")
        }
        let hook = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AgentsTests
            .deletingLastPathComponent()  // macapp
            .deletingLastPathComponent()  // repo
            .appendingPathComponent("hooks/agents-status.sh")

        let center = TerminalCenter()
        _ = center.terminalView(for: "row-1", workingDirectory: "/tmp", restoredResume: nil)
        let pane = center.layouts["row-1"]!.initialPane
        var signals: [(pane: UUID, signal: AttentionSignal)] = []
        center.onSessionSignal = { _, pane, signal in signals.append((pane, signal)) }
        var announced: [AgentSessionEvent] = []
        center.onAgentSessionEvent = { _, event, _ in announced.append(event) }

        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("agents-hook-test-\(getpid()).sock").path
        let server = ControlServer(overlays: OverlayCenter(), socketPath: socketPath)
        server.validateSession = { $0 == "row-1" }
        server.applySessionEvent = { [center] event in center.handleControlSessionEvent(event) }
        server.start()
        defer { server.stop() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socketPath) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "the server never bound its socket")

        let environment = [
            "PATH": searchPath,
            "AGENTS_APP": "1",
            "AGENTS_CONTROL_SOCK": socketPath,
            "AGENTS_SESSION_ID": "row-1",
            "AGENTS_PANE_ID": pane.uuidString,
            // Under xctest there is no `claude` ancestor to find; this is the
            // hook's documented fallback for exactly that situation.
            "CLAUDECODE": "1",
            "CLAUDE_CONFIG_DIR": "/tmp/claude-config",
        ]
        let hookRun = try await Self.run(
            "/bin/bash", [hook.path], environment: environment,
            stdin: #"{"hook_event_name":"UserPromptSubmit","session_id":"abc-123","prompt":"Fix the parser"}"#
        )
        XCTAssertEqual(hookRun.status, 0, "hook exited \(hookRun.status): \(hookRun.output)")
        XCTAssertEqual(signals.map(\.pane), [pane])
        XCTAssertEqual(signals.map(\.signal), [.structured(.clear)])
        XCTAssertEqual(
            announced,
            [AgentSessionEvent(
                agent: "claude", name: "UserPromptSubmit", sessionID: "abc-123", query: "Fix the parser",
                home: "/tmp/claude-config"
            )],
            "the hook's UserPromptSubmit must arrive as one announcement carrying the harness, its session id, the prompt preview, and the configuration home it ran under"
        )

        // A refusal must be answered AND the connection closed, or the
        // hook's nc hangs on it: drive nc directly to read the reply.
        let refusal = try await Self.run(
            "/usr/bin/nc", ["-U", "-w", "2", socketPath], environment: ["PATH": searchPath],
            stdin: #"{"cmd":"session-event","session":"row-1","pane":"\#(UUID().uuidString)","event":"Stop","status":"clear"}"# + "\n"
        )
        XCTAssertTrue(
            refusal.output.contains(#""ok":false"#) && refusal.output.contains("unknown pane"),
            "a refusal must reach the caller as a JSON line naming the problem, got: \(refusal.output)"
        )
        XCTAssertEqual(signals.count, 1, "a refused event must apply nothing")

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath), "stop() must remove the socket file")
    }

    private static func run(
        _ executable: String, _ arguments: [String], environment: [String: String], stdin: String
    ) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        // Never waitUntilExit() here: the server applies events on the main
        // actor, and blocking the main thread would deadlock the very reply
        // the hook's nc is waiting for.
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do {
                try process.run()
                input.fileHandleForWriting.write(Data(stdin.utf8))
                try input.fileHandleForWriting.close()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
