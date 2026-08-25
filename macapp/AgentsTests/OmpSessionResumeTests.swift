import XCTest
@testable import Agents

final class OmpSessionResumeTests: XCTestCase {
    func testParsesVersionOneOmpEnvelopeAndIgnoresExtraFields() {
        let event = OmpSessionEvent.parseNotification(
            title: OmpSessionEvent.notificationTitle,
            body: #"{"event":"permission_request","v":1,"agent":"omp","session_id":"abc-123","cwd":"/tmp/p","project":"p","plugin_version":"1.2.3","summary":"Run tests","future":true}"#
        )

        XCTAssertEqual(event?.name, "permission_request")
        XCTAssertEqual(event?.sessionID, "abc-123")
        XCTAssertNil(event?.query)
    }

    func testExtractsAndCapsOptionalQueryPreview() {
        let query = String(repeating: "é", count: 205)
        let body = #"{"event":"prompt_submit","v":1,"agent":"omp","session_id":"abc","query":"\#(query)"}"#

        let event = OmpSessionEvent.parseNotification(
            title: OmpSessionEvent.notificationTitle,
            body: body
        )

        XCTAssertEqual(event?.query?.count, 200)
        XCTAssertEqual(event?.query, String(query.prefix(200)))
    }

    func testQueryPreviewCollapsesWhitespaceStripsControlsThenCapsAt200Characters() {
        let prefix = String(repeating: "a", count: 195)
        let body = #"{"event":"prompt_submit","v":1,"agent":"omp","session_id":"abc","query":"\#(prefix)\n\t\u001B\u0003tail and more"}"#

        let event = OmpSessionEvent.parseNotification(
            title: OmpSessionEvent.notificationTitle,
            body: body
        )

        XCTAssertEqual(event?.query, String(repeating: "a", count: 195) + " tail")
        XCTAssertEqual(event?.query?.count, 200)
        XCTAssertFalse(event?.query?.contains("\n") ?? true)
        XCTAssertFalse(event?.query?.contains("\u{001B}") ?? true)
        XCTAssertFalse(event?.query?.contains("\u{0003}") ?? true)
    }

    func testRejectsWrongTitleMalformedJSONVersionAgentAndRequiredFields() {
        let validBody = #"{"event":"stop","v":1,"agent":"omp","session_id":"abc"}"#
        XCTAssertNil(OmpSessionEvent.parseNotification(title: "warp://cli-agent/other", body: validBody))
        XCTAssertNil(OmpSessionEvent.parseNotification(title: OmpSessionEvent.notificationTitle, body: "{"))
        XCTAssertNil(OmpSessionEvent.parseNotification(
            title: OmpSessionEvent.notificationTitle,
            body: #"{"event":"stop","v":2,"agent":"omp","session_id":"abc"}"#
        ))
        XCTAssertNil(OmpSessionEvent.parseNotification(
            title: OmpSessionEvent.notificationTitle,
            body: #"{"event":"stop","v":1,"agent":"claude","session_id":"abc"}"#
        ))
        XCTAssertNil(OmpSessionEvent.parseNotification(
            title: OmpSessionEvent.notificationTitle,
            body: #"{"v":1,"agent":"omp","session_id":"abc"}"#
        ))
        XCTAssertNil(OmpSessionEvent.parseNotification(
            title: OmpSessionEvent.notificationTitle,
            body: #"{"event":"stop","v":1,"agent":"omp","session_id":"  "}"#
        ))
    }

    func testNormalizesOnlyDocumentedOmpTitleDecorations() {
        XCTAssertEqual(OmpSessionResumeMetadata.normalizedDecoratedTitle("π > Refactor parser"), "Refactor parser")
        XCTAssertEqual(OmpSessionResumeMetadata.normalizedDecoratedTitle("π ⠼ Refactor parser"), "Refactor parser")
        XCTAssertEqual(OmpSessionResumeMetadata.normalizedDecoratedTitle("π ! Refactor parser"), "Refactor parser")
        XCTAssertEqual(OmpSessionResumeMetadata.normalizedDecoratedTitle("π: Refactor parser"), "Refactor parser")
        XCTAssertNil(OmpSessionResumeMetadata.normalizedDecoratedTitle("π >"))
        XCTAssertNil(OmpSessionResumeMetadata.normalizedDecoratedTitle("π project shell"))
        XCTAssertNil(OmpSessionResumeMetadata.normalizedDecoratedTitle("π >not a decoration"))
        XCTAssertNil(OmpSessionResumeMetadata.normalizedDecoratedTitle("ordinary title"))
    }

    func testResumeHintUsesPromptFallbackAndExactResumeCommand() {
        let metadata = OmpSessionResumeMetadata(
            sessionID: "session-123",
            title: nil,
            prompt: "Repair persistence"
        )

        let command = OmpSessionResumeMetadata.resumeHintCommand(for: metadata)

        XCTAssertEqual(
            command,
            "printf '%s\\n' 'OMP session: Repair persistence' 'Resume: omp --resume session-123'\n"
        )
        XCTAssertTrue(command.hasSuffix("\n"))
    }

    func testResumeHintQuotesTitlePromptAndSessionIDWithoutExecutingThem() {
        let metadata = OmpSessionResumeMetadata(
            sessionID: "id'; touch /tmp/nope; echo '",
            title: "Kira's run",
            prompt: "Don't auto-run"
        )

        let command = OmpSessionResumeMetadata.resumeHintCommand(for: metadata)

        XCTAssertEqual(command.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(command.contains("'OMP session: Kira'\"'\"'s run'"))
        XCTAssertTrue(command.contains("'Prompt: Don'\"'\"'t auto-run'"))
        XCTAssertTrue(command.contains("'Resume: omp --resume id'\"'\"'; touch /tmp/nope; echo '\"'\"''"))
        XCTAssertFalse(command.contains("\nomp --resume"))
    }

    func testResumeHintCollapsesNewlinesAndStripsTerminalControls() {
        let metadata = OmpSessionResumeMetadata(
            sessionID: "session-123",
            title: "Line one\n\tLine two\u{001B}\u{0007}",
            prompt: "Prompt\r\nnext\u{0003}"
        )

        let command = OmpSessionResumeMetadata.resumeHintCommand(for: metadata)

        XCTAssertEqual(command.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(command.contains("'OMP session: Line one Line two'"))
        XCTAssertTrue(command.contains("'Prompt: Prompt next'"))
        XCTAssertFalse(command.contains("\u{001B}"))
        XCTAssertFalse(command.contains("\u{0007}"))
        XCTAssertFalse(command.contains("\u{0003}"))
    }
}
