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

    // MARK: - make (shared by the OSC and control-socket transports)

    func testMakeNormalizesExactlyLikeParseNotification() {
        let made = AgentSessionEvent.make(
            agent: " Claude ", name: " UserPromptSubmit ", sessionID: " c-1 ", query: "Fix\n\tthe\u{001B} parser"
        )

        XCTAssertEqual(
            made,
            AgentSessionEvent(agent: "claude", name: "UserPromptSubmit", sessionID: "c-1", query: "Fix the parser"),
            "the control-socket path builds events through make() — it must apply the same lowercase/trim/one-line rules the OSC path does, or the same session would look different depending on which transport announced it"
        )
    }

    func testMakeRejectsBlankIdentityAndDropsABlankQuery() {
        XCTAssertNil(AgentSessionEvent.make(agent: " ", name: "e", sessionID: "s", query: nil))
        XCTAssertNil(AgentSessionEvent.make(agent: "claude", name: " ", sessionID: "s", query: nil))
        XCTAssertNil(AgentSessionEvent.make(agent: "claude", name: "e", sessionID: " ", query: nil))
        let blankQuery = AgentSessionEvent.make(agent: "claude", name: "e", sessionID: "s", query: " \n ")
        XCTAssertNotNil(blankQuery)
        XCTAssertNil(blankQuery?.query, "a whitespace-only prompt is no prompt — it must not become an empty heading fallback in the banner")
    }

    // MARK: - displayName / resumeCommand

    func testMakeTrimsTheHomeAndDropsABlankOne() {
        XCTAssertEqual(
            AgentSessionEvent.make(agent: "codex", name: "SessionStart", sessionID: "x", query: nil, home: " /Users/kira/.codex-kira ")?.home,
            "/Users/kira/.codex-kira"
        )
        XCTAssertNil(AgentSessionEvent.make(agent: "codex", name: "SessionStart", sessionID: "x", query: nil, home: "  ")?.home)
        XCTAssertNil(AgentSessionEvent.make(agent: "codex", name: "SessionStart", sessionID: "x", query: nil)?.home)
    }

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

    func testClaudeLaunchPlaceholderTitleIsNotATitle() {
        XCTAssertNil(
            SessionResumeMetadata.normalizedTitle("✳ Claude Code", agent: "claude"),
            "'✳ Claude Code' is what Claude Code shows before the first exchange is summarized — the program's name, not the conversation's — and a banner saying 'Last Claude Code session: Claude Code' would displace the more useful prompt fallback"
        )
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("✳ Claude Code review", agent: "claude"), "Claude Code review")
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

    // MARK: - resumeCommand: configuration home

    func testResumeCommandCarriesTheHarnessHomeAsAVariablePrefix() {
        let codex = SessionResumeMetadata(agent: "codex", sessionID: "s-3", title: nil, prompt: nil, home: "/Users/kira/.codex-kira")
        let claude = SessionResumeMetadata(agent: "claude", sessionID: "s-2", title: nil, prompt: nil, home: "/Users/kira/.claude-kira")

        XCTAssertEqual(
            SessionResumeMetadata.resumeCommand(for: codex), "CODEX_HOME=/Users/kira/.codex-kira codex resume s-3",
            "Codex keeps its sessions under CODEX_HOME: a bare `codex resume` typed into a fresh shell that never set it looks in ~/.codex and fails, so the command must carry the home it ran under"
        )
        XCTAssertEqual(SessionResumeMetadata.resumeCommand(for: claude), "CLAUDE_CONFIG_DIR=/Users/kira/.claude-kira claude --resume s-2")
    }

    func testResumeCommandIgnoresAHomeForOmpAndABlankHome() {
        let omp = SessionResumeMetadata(agent: "omp", sessionID: "s-1", title: nil, prompt: nil, home: "/somewhere")
        let blank = SessionResumeMetadata(agent: "codex", sessionID: "s-3", title: nil, prompt: nil, home: "  ")

        XCTAssertEqual(
            SessionResumeMetadata.resumeCommand(for: omp), "omp --resume s-1",
            "OMP has no home variable this app knows; a stray value must not be turned into a made-up prefix"
        )
        XCTAssertEqual(SessionResumeMetadata.resumeCommand(for: blank), "codex resume s-3")
    }

    func testResumeCommandQuotesIdsAndHomesTheShellWouldOtherwiseInterpret() {
        let hostile = SessionResumeMetadata(
            agent: "codex", sessionID: "id'; touch /tmp/nope; echo '", title: nil, prompt: nil,
            home: "/Users/kira/My Codex"
        )

        XCTAssertEqual(
            SessionResumeMetadata.resumeCommand(for: hostile),
            "CODEX_HOME='/Users/kira/My Codex' codex resume 'id'\"'\"'; touch /tmp/nope; echo '\"'\"''",
            "the command is typed at the prompt and run by Enter, so a session id or home carrying metacharacters must arrive as one quoted word, never as a second command"
        )
    }

    // MARK: - restoreInput

    func testRestoreInputPrintsTheHeadingAndLeavesTheResumeCommandTypedButUnrun() {
        let metadata = SessionResumeMetadata(agent: "claude", sessionID: "session-123", title: "Repair persistence", prompt: nil)

        let input = SessionResumeMetadata.restoreInput(for: metadata)

        XCTAssertEqual(
            input,
            "printf '%s\\n' 'Last Claude Code session: Repair persistence'\nclaude --resume session-123",
            "the heading runs at once (newline-terminated) and the resume command follows with NO newline, so it waits at the prompt: Enter resumes, and nothing spends tokens on the user's behalf"
        )
        XCTAssertFalse(input.hasSuffix("\n"), "a trailing newline would run the resume command — the one thing this banner must never do")
    }

    func testRestoreInputFallsBackToThePromptForAnUntitledSession() {
        let metadata = SessionResumeMetadata(agent: "claude", sessionID: "session-123", title: nil, prompt: "Repair persistence")

        XCTAssertTrue(
            SessionResumeMetadata.restoreInput(for: metadata)
                .hasPrefix("printf '%s\\n' 'Last Claude Code session: Repair persistence'\n")
        )
    }

    func testRestoreInputUsesEachHarnessesOwnResumeSyntax() {
        let codex = SessionResumeMetadata(agent: "codex", sessionID: "session-123", title: "Fix the parser", prompt: nil, home: "/h")
        let omp = SessionResumeMetadata(agent: "omp", sessionID: "session-123", title: "Fix the parser", prompt: nil)

        XCTAssertTrue(SessionResumeMetadata.restoreInput(for: codex).hasSuffix("\nCODEX_HOME=/h codex resume session-123"))
        XCTAssertTrue(SessionResumeMetadata.restoreInput(for: omp).hasSuffix("\nomp --resume session-123"))
    }

    func testRestoreInputForUnknownAgentPrintsTheSessionIDAndTypesNothing() {
        let metadata = SessionResumeMetadata(agent: "gemini", sessionID: "id-1", title: "T", prompt: nil)

        XCTAssertEqual(
            SessionResumeMetadata.restoreInput(for: metadata),
            "printf '%s\\n' 'Last gemini session: T' 'Session id: id-1'\n",
            "an agent with no known resume command must not leave a guessed-at command at the prompt — printing the raw session id is the honest fallback"
        )
    }

    func testRestoreInputWithNoTitleOrPromptOmitsTheColonEntirely() {
        let metadata = SessionResumeMetadata(agent: "claude", sessionID: "session-123", title: nil, prompt: nil)

        let input = SessionResumeMetadata.restoreInput(for: metadata)

        XCTAssertTrue(
            input.hasPrefix("printf '%s\\n' 'Last Claude Code session'\n"),
            "with neither a title nor a prompt there is nothing to put after a colon, so the heading must read as a plain statement rather than dangle one: \(input)"
        )
    }

    func testTitleWinsOverPromptAndThePromptNeverGetsItsOwnLine() {
        let titled = SessionResumeMetadata(agent: "claude", sessionID: "s-1", title: "Fix it", prompt: "Original ask")

        let input = SessionResumeMetadata.restoreInput(for: titled)

        XCTAssertTrue(input.contains("'Last Claude Code session: Fix it'"))
        XCTAssertFalse(
            input.contains("Original ask"),
            "the prompt is only ever the heading's fallback for an untitled session — printing it beneath a real title would repeat what the title says"
        )
    }

    func testRestoreInputQuotesTheHeadingSoATitleCannotInjectShellLines() {
        let metadata = SessionResumeMetadata(
            agent: "omp", sessionID: "id-1", title: "Kira's run'; touch /tmp/nope; echo '", prompt: nil
        )

        let input = SessionResumeMetadata.restoreInput(for: metadata)

        XCTAssertEqual(
            input,
            "printf '%s\\n' 'Last OMP session: Kira'\"'\"'s run'\"'\"'; touch /tmp/nope; echo '\"'\"''\nomp --resume id-1",
            "the heading is one single-quoted printf argument whatever the title contains; the only newline in the whole input is the one that runs printf"
        )
        XCTAssertEqual(input.filter { $0 == "\n" }.count, 1)
    }

    func testRestoreInputQuotesThePromptFallbackHeadingToo() {
        let metadata = SessionResumeMetadata(agent: "claude", sessionID: "s-1", title: nil, prompt: "Don't auto-run")

        XCTAssertTrue(
            SessionResumeMetadata.restoreInput(for: metadata).contains("'Last Claude Code session: Don'\"'\"'t auto-run'")
        )
    }

    func testRestoreInputCollapsesNewlinesAndStripsTerminalControls() {
        let titled = SessionResumeMetadata(
            agent: "claude", sessionID: "session-123", title: "Line one\n\tLine two\u{001B}\u{0007}", prompt: nil
        )
        let untitled = SessionResumeMetadata(
            agent: "claude", sessionID: "session-123", title: nil, prompt: "Prompt\r\nnext\u{0003}"
        )

        for metadata in [titled, untitled] {
            let input = SessionResumeMetadata.restoreInput(for: metadata)
            XCTAssertEqual(input.filter { $0 == "\n" }.count, 1)
            XCTAssertFalse(input.contains("\u{001B}"))
            XCTAssertFalse(input.contains("\u{0007}"))
            XCTAssertFalse(input.contains("\u{0003}"))
        }
        XCTAssertTrue(SessionResumeMetadata.restoreInput(for: titled).contains("'Last Claude Code session: Line one Line two'"))
        XCTAssertTrue(SessionResumeMetadata.restoreInput(for: untitled).contains("'Last Claude Code session: Prompt next'"))
    }
}
