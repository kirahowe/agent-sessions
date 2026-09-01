import XCTest
@testable import Agents

final class SessionResumeTests: XCTestCase {

    // MARK: - Parsing

    func testParsesWarpTitleWithOmpAgent() {
        let event = AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.warpNotificationTitle,
            body: #"{"event":"permission_request","v":1,"agent":"omp","session_id":"abc-123","cwd":"/tmp/p","project":"p","plugin_version":"1.2.3","summary":"Run tests","future":true}"#
        )

        XCTAssertEqual(event?.agent, "omp")
        XCTAssertEqual(event?.name, "permission_request")
        XCTAssertEqual(event?.sessionID, "abc-123")
        XCTAssertNil(event?.query)
    }

    func testParsesHookTitleWithClaudeAgent() {
        let event = AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.hookNotificationTitle,
            body: #"{"event":"session_start","v":1,"agent":"claude","session_id":"c-1"}"#
        )

        XCTAssertEqual(event?.agent, "claude", "the app's own hook title must decode Claude Code sessions, not just OMP's Warp title")
        XCTAssertEqual(event?.sessionID, "c-1")
    }

    func testParsesHookTitleWithCodexAgent() {
        let event = AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.hookNotificationTitle,
            body: #"{"event":"session_start","v":1,"agent":"codex","session_id":"x-1"}"#
        )

        XCTAssertEqual(event?.agent, "codex")
        XCTAssertEqual(event?.sessionID, "x-1")
    }

    func testClaudeUnderWarpTitleIsNowAcceptedBecauseTheProtocolIsHarnessAgnostic() {
        // Inverts the old OMP-only test: the wire shape is shared, so any
        // emitter speaking it through Warp's title must be accepted, not
        // just OMP. Rejecting a non-"omp" agent here would make the app
        // brittle to a future harness that (for whatever reason) speaks
        // through the Warp title instead of the app's own hook title.
        let event = AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.warpNotificationTitle,
            body: #"{"event":"session_start","v":1,"agent":"claude","session_id":"c-1"}"#
        )

        XCTAssertEqual(event?.agent, "claude")
    }

    func testAgentIsLowercasedAndTrimmed() {
        let event = AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.hookNotificationTitle,
            body: #"{"event":"session_start","v":1,"agent":" Claude ","session_id":"c-1"}"#
        )

        XCTAssertEqual(event?.agent, "claude", "AppStore/SessionResumeMetadata switch on lowercase agent strings, so a differently-cased or padded value from the hook must be normalized here, once, rather than everywhere it's compared")
    }

    func testExtraFieldsAreIgnored() {
        let event = AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.hookNotificationTitle,
            body: #"{"event":"session_start","v":1,"agent":"codex","session_id":"x-1","cwd":"/tmp","future_field":42}"#
        )

        XCTAssertEqual(event?.sessionID, "x-1")
    }

    func testExtractsAndCapsOptionalQueryPreview() {
        let query = String(repeating: "é", count: 205)
        let body = #"{"event":"prompt_submit","v":1,"agent":"omp","session_id":"abc","query":"\#(query)"}"#

        let event = AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.warpNotificationTitle,
            body: body
        )

        XCTAssertEqual(event?.query?.count, 200)
        XCTAssertEqual(event?.query, String(query.prefix(200)))
    }

    func testQueryPreviewCollapsesWhitespaceStripsControlsThenCapsAt200Characters() {
        let prefix = String(repeating: "a", count: 195)
        let body = #"{"event":"prompt_submit","v":1,"agent":"omp","session_id":"abc","query":"\#(prefix)\n\t\u001B\u0003tail and more"}"#

        let event = AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.warpNotificationTitle,
            body: body
        )

        XCTAssertEqual(event?.query, String(repeating: "a", count: 195) + " tail")
        XCTAssertEqual(event?.query?.count, 200)
        XCTAssertFalse(event?.query?.contains("\n") ?? true)
        XCTAssertFalse(event?.query?.contains("\u{001B}") ?? true)
        XCTAssertFalse(event?.query?.contains("\u{0003}") ?? true)
    }

    func testRejectsWrongTitles() {
        let validBody = #"{"event":"stop","v":1,"agent":"omp","session_id":"abc"}"#
        XCTAssertNil(
            AgentSessionEvent.parseNotification(title: "warp://cli-agent/other", body: validBody),
            "only an exact match on one of the two magic titles may decode — a look-alike title must not slip through"
        )
        XCTAssertNil(
            AgentSessionEvent.parseNotification(title: "agents:status", body: validBody),
            "agents:status is a different protocol entirely (free-text/structured attention), not a session-resume envelope"
        )
    }

    func testRejectsMalformedJSON() {
        XCTAssertNil(AgentSessionEvent.parseNotification(title: AgentSessionEvent.warpNotificationTitle, body: "{"))
        XCTAssertNil(AgentSessionEvent.parseNotification(title: AgentSessionEvent.hookNotificationTitle, body: "not json"))
    }

    func testRejectsVersionOtherThanOne() {
        XCTAssertNil(AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.warpNotificationTitle,
            body: #"{"event":"stop","v":2,"agent":"omp","session_id":"abc"}"#
        ))
    }

    func testRejectsMissingEvent() {
        XCTAssertNil(AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.warpNotificationTitle,
            body: #"{"v":1,"agent":"omp","session_id":"abc"}"#
        ))
    }

    func testRejectsBlankSessionID() {
        XCTAssertNil(AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.warpNotificationTitle,
            body: #"{"event":"stop","v":1,"agent":"omp","session_id":"  "}"#
        ))
    }

    func testRejectsBlankOrMissingAgent() {
        XCTAssertNil(
            AgentSessionEvent.parseNotification(
                title: AgentSessionEvent.hookNotificationTitle,
                body: #"{"event":"stop","v":1,"agent":"  ","session_id":"abc"}"#
            ),
            "a blank agent must not decode into an empty-string harness identifier that would then silently fail every downstream switch"
        )
        XCTAssertNil(
            AgentSessionEvent.parseNotification(
                title: AgentSessionEvent.hookNotificationTitle,
                body: #"{"event":"stop","v":1,"session_id":"abc"}"#
            ),
            "a missing agent field must reject rather than decode as an empty string"
        )
    }

    // MARK: - displayName / resumeCommand

    func testDisplayNameForKnownAndUnknownAgents() {
        XCTAssertEqual(SessionResumeMetadata.displayName(agent: "omp"), "OMP")
        XCTAssertEqual(SessionResumeMetadata.displayName(agent: "claude"), "Claude Code")
        XCTAssertEqual(SessionResumeMetadata.displayName(agent: "codex"), "Codex")
        XCTAssertEqual(
            SessionResumeMetadata.displayName(agent: "gemini"), "gemini",
            "an agent this table has never heard of must still print something sensible in a resume hint, rather than an empty or placeholder string"
        )
    }

    func testResumeCommandForKnownAgents() {
        let omp = SessionResumeMetadata(agent: "omp", sessionID: "s-1", title: nil, prompt: nil)
        let claude = SessionResumeMetadata(agent: "claude", sessionID: "s-2", title: nil, prompt: nil)
        let codex = SessionResumeMetadata(agent: "codex", sessionID: "s-3", title: nil, prompt: nil)

        XCTAssertEqual(SessionResumeMetadata.resumeCommand(for: omp), "omp --resume s-1")
        XCTAssertEqual(SessionResumeMetadata.resumeCommand(for: claude), "claude --resume s-2")
        XCTAssertEqual(
            SessionResumeMetadata.resumeCommand(for: codex), "codex resume s-3",
            "Codex's real CLI syntax has no `--` before the session id, unlike omp/claude — getting this wrong would hand the user a command that fails outright"
        )
    }

    func testResumeCommandForUnknownAgentIsNil() {
        let gemini = SessionResumeMetadata(agent: "gemini", sessionID: "s-4", title: nil, prompt: nil)

        XCTAssertNil(
            SessionResumeMetadata.resumeCommand(for: gemini),
            "an agent with no known resume syntax must yield no command, not a guessed-at one that could fail or do the wrong thing"
        )
    }

    // MARK: - normalizedTitle

    func testNormalizesOnlyDocumentedOmpTitleDecorations() {
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("π > Refactor parser", agent: "omp"), "Refactor parser")
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("π ⠼ Refactor parser", agent: "omp"), "Refactor parser")
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("π ! Refactor parser", agent: "omp"), "Refactor parser")
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("π: Refactor parser", agent: "omp"), "Refactor parser")
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("π >", agent: "omp"))
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("π project shell", agent: "omp"))
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("π >not a decoration", agent: "omp"))
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("ordinary title", agent: "omp"))
    }

    func testNormalizesAllFiveDocumentedClaudeGlyphs() {
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("✳ Fix parser", agent: "claude"), "Fix parser")
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("◐ Fix parser", agent: "claude"), "Fix parser")
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("◓ Fix parser", agent: "claude"), "Fix parser")
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("◑ Fix parser", agent: "claude"), "Fix parser")
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("◒ Fix parser", agent: "claude"), "Fix parser")
    }

    func testClaudeBareGlyphAndNoSpaceAreNotRecognized() {
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("✳", agent: "claude"), "a bare idle glyph with no summary must not be read as a title")
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("✳Fix", agent: "claude"), "no separating space means this isn't Claude Code's documented decoration")
    }

    func testClaudeRejectsPlainShellTitle() {
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("kira@Mac:~/code", agent: "claude"))
    }

    func testCrossAgentDecorationsDoNotMatch() {
        XCTAssertNil(
            SessionResumeMetadata.normalizedTitle("π > Task", agent: "claude"),
            "OMP's own decoration must never be mistaken for Claude Code's just because a row switched harnesses — a stale π title surviving under the wrong agent would misreport whose session this is"
        )
    }

    func testCodexAndUnknownAgentsHaveNoKnownDecoration() {
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("anything", agent: "codex"))
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("✳ Fix parser", agent: "codex"), "Claude's glyphs must not be recognized under a different agent")
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("anything", agent: "gemini"))
    }

    // MARK: - resumeHintCommand

    func testResumeHintForClaudeUsesPromptFallbackAndClaudesOwnExitText() {
        let metadata = SessionResumeMetadata(agent: "claude", sessionID: "session-123", title: nil, prompt: "Repair persistence")

        let command = SessionResumeMetadata.resumeHintCommand(for: metadata)

        XCTAssertEqual(
            command,
            "printf '%s\\n' 'Last Claude Code session: Repair persistence' 'Resume this session with:' 'claude --resume session-123'\n",
            "the banner must read like the message Claude Code prints on exit — a heading, then 'Resume this session with:' and the bare command on its own line — so what greets the user after a relaunch is the text they saw when the agent quit"
        )
        XCTAssertTrue(command.hasSuffix("\n"))
    }

    func testResumeHintForCodexUsesCodexResumeSyntax() {
        let metadata = SessionResumeMetadata(agent: "codex", sessionID: "session-123", title: "Fix the parser", prompt: nil)

        let command = SessionResumeMetadata.resumeHintCommand(for: metadata)

        XCTAssertTrue(command.contains("'Resume this session with:' 'codex resume session-123'"))
    }

    func testResumeHintForOmpUsesOmpResumeSyntax() {
        let metadata = SessionResumeMetadata(agent: "omp", sessionID: "session-123", title: "Fix the parser", prompt: nil)

        let command = SessionResumeMetadata.resumeHintCommand(for: metadata)

        XCTAssertTrue(command.contains("'Resume this session with:' 'omp --resume session-123'"))
    }

    func testResumeHintForUnknownAgentFallsBackToSessionIDWithNoResumeLine() {
        let metadata = SessionResumeMetadata(agent: "gemini", sessionID: "id-1", title: "T", prompt: nil)

        let command = SessionResumeMetadata.resumeHintCommand(for: metadata)

        XCTAssertTrue(command.contains("'Last gemini session: T'"))
        XCTAssertTrue(command.contains("'Session id: id-1'"))
        XCTAssertFalse(
            command.contains("Resume this session"),
            "an agent with no known resume command must not print a resume instruction it can't back up — printing a raw session id is the honest fallback"
        )
    }

    func testResumeHintWithNoTitleOrPromptOmitsTheColonEntirely() {
        let metadata = SessionResumeMetadata(agent: "claude", sessionID: "session-123", title: nil, prompt: nil)

        let command = SessionResumeMetadata.resumeHintCommand(for: metadata)

        XCTAssertTrue(
            command.contains("'Last Claude Code session' "),
            "with neither a title nor a prompt there is nothing to put after a colon, so the heading line must read as a plain statement rather than 'Last Claude Code session: ' with a dangling colon: \(command)"
        )
        XCTAssertFalse(command.contains("session: '"))
    }

    func testTitleWinsOverPromptAndThePromptNeverGetsItsOwnLine() {
        let titled = SessionResumeMetadata(agent: "claude", sessionID: "s-1", title: "Fix it", prompt: "Original ask")

        let command = SessionResumeMetadata.resumeHintCommand(for: titled)

        XCTAssertTrue(command.contains("'Last Claude Code session: Fix it'"))
        XCTAssertFalse(
            command.contains("Original ask"),
            "the prompt is only ever the heading's fallback for an untitled session — printing it beneath a real title would repeat what the title says and push Claude's two-line resume text further from the prompt"
        )
        XCTAssertFalse(command.contains("Prompt:"))
    }

    func testResumeHintQuotesTitleAndSessionIDWithoutExecutingThem() {
        let metadata = SessionResumeMetadata(
            agent: "omp",
            sessionID: "id'; touch /tmp/nope; echo '",
            title: "Kira's run",
            prompt: nil
        )

        let command = SessionResumeMetadata.resumeHintCommand(for: metadata)

        XCTAssertEqual(command.filter { $0 == "\n" }.count, 1, "the whole hint must be one printf invocation terminated by exactly one trailing newline, or a maliciously-crafted title/prompt could inject extra shell lines")
        XCTAssertTrue(command.contains("'Last OMP session: Kira'\"'\"'s run'"))
        XCTAssertTrue(
            command.contains("'omp --resume id'\"'\"'; touch /tmp/nope; echo '\"'\"''"),
            "the command line is printed, never run: a session id carrying shell metacharacters must arrive as one quoted printf argument"
        )
        XCTAssertFalse(command.contains("\nomp --resume"))
    }

    func testResumeHintQuotesThePromptFallbackHeadingToo() {
        let metadata = SessionResumeMetadata(agent: "claude", sessionID: "s-1", title: nil, prompt: "Don't auto-run")

        let command = SessionResumeMetadata.resumeHintCommand(for: metadata)

        XCTAssertTrue(command.contains("'Last Claude Code session: Don'\"'\"'t auto-run'"))
    }

    func testResumeHintCollapsesNewlinesAndStripsTerminalControls() {
        let titled = SessionResumeMetadata(
            agent: "claude",
            sessionID: "session-123",
            title: "Line one\n\tLine two\u{001B}\u{0007}",
            prompt: nil
        )
        let untitled = SessionResumeMetadata(
            agent: "claude",
            sessionID: "session-123",
            title: nil,
            prompt: "Prompt\r\nnext\u{0003}"
        )

        for metadata in [titled, untitled] {
            let command = SessionResumeMetadata.resumeHintCommand(for: metadata)
            XCTAssertEqual(command.filter { $0 == "\n" }.count, 1)
            XCTAssertFalse(command.contains("\u{001B}"))
            XCTAssertFalse(command.contains("\u{0007}"))
            XCTAssertFalse(command.contains("\u{0003}"))
        }
        XCTAssertTrue(SessionResumeMetadata.resumeHintCommand(for: titled).contains("'Last Claude Code session: Line one Line two'"))
        XCTAssertTrue(SessionResumeMetadata.resumeHintCommand(for: untitled).contains("'Last Claude Code session: Prompt next'"))
    }
}
