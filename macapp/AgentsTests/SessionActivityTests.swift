import XCTest
@testable import Agents

/// Thorough coverage of `SessionActivity.parseStatusMessage` — this parser
/// is the entire wire contract between the (separately-shipped) Claude Code
/// hook script and the app, so every accepted/rejected shape matters.
final class SessionActivityTests: XCTestCase {

    // MARK: - OSC 777 form (title carries the magic string, body carries the token)

    func testOSC777YourTurn() {
        XCTAssertEqual(
            SessionActivity.parseStatusMessage(title: "agents:status", body: "your-turn"),
            .set(.yourTurn)
        )
    }

    func testOSC777Blocked() {
        XCTAssertEqual(
            SessionActivity.parseStatusMessage(title: "agents:status", body: "blocked"),
            .set(.blocked)
        )
    }

    func testOSC777Clear() {
        XCTAssertEqual(
            SessionActivity.parseStatusMessage(title: "agents:status", body: "clear"),
            .clear
        )
    }

    // MARK: - OSC 9 form, whole message routed to the title field

    func testOSC9FullMessageInTitle() {
        XCTAssertEqual(
            SessionActivity.parseStatusMessage(title: "agents:status:blocked", body: ""),
            .set(.blocked)
        )
    }

    // MARK: - OSC 9 form, whole message routed to the body field instead

    func testOSC9FullMessageInBody() {
        XCTAssertEqual(
            SessionActivity.parseStatusMessage(title: "", body: "agents:status:your-turn"),
            .set(.yourTurn)
        )
    }

    // MARK: - Surrounding whitespace/newlines are tolerated

    func testSurroundingWhitespaceAndNewlinesAreTolerated() {
        XCTAssertEqual(
            SessionActivity.parseStatusMessage(title: "  agents:status  \n", body: "\n blocked \t"),
            .set(.blocked)
        )
        XCTAssertEqual(
            SessionActivity.parseStatusMessage(title: " \nagents:status:your-turn\n ", body: ""),
            .set(.yourTurn)
        )
    }

    // MARK: - Unknown token

    func testUnknownTokenReturnsNil() {
        XCTAssertNil(SessionActivity.parseStatusMessage(title: "agents:status:bogus", body: ""))
    }

    // MARK: - Unrelated notification from some other program

    func testUnrelatedNotificationReturnsNil() {
        XCTAssertNil(SessionActivity.parseStatusMessage(title: "Build finished", body: "3 warnings"))
    }

    // MARK: - A body that merely CONTAINS the magic string without starting with it

    func testBodyContainingButNotStartingWithMagicStringReturnsNil() {
        XCTAssertNil(SessionActivity.parseStatusMessage(title: "", body: "see agents:status:blocked in log"))
    }
}
