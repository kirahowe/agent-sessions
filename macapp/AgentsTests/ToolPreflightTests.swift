import XCTest
@testable import Agents

@MainActor
final class ToolPreflightTests: XCTestCase {
    func testBbFoundViaEnvironmentOverride() {
        let missing = ToolPreflight.missingTools(
            environment: ["AGENTS_BB": "/custom/bb"],
            isExecutable: { $0 == "/custom/bb" }
        )
        XCTAssertEqual(missing, [])
    }

    func testBbFoundViaHomebrewFallback() {
        let missing = ToolPreflight.missingTools(
            environment: [:],
            isExecutable: { $0 == "/opt/homebrew/bin/bb" }
        )
        XCTAssertEqual(missing, [])
    }

    func testMissingPreflightReportsOnlyBb() {
        let missing = ToolPreflight.missingTools(
            environment: [
                "AGENTS_JJ": "/custom/jj",
                "PATH": "/usr/bin",
            ],
            isExecutable: { path in path == "/custom/jj" || path == "/usr/bin/git" }
        )
        XCTAssertEqual(missing, ["bb"])
    }

    func testNonExecutableBbOverrideFallsThrough() {
        let missing = ToolPreflight.missingTools(
            environment: ["AGENTS_BB": "/bogus/bb"],
            isExecutable: { $0 == "/usr/local/bin/bb" }
        )
        XCTAssertEqual(missing, [])
    }

    func testGuidanceMentionsOnlyBabashka() {
        let guidance = ToolPreflight.guidance(for: ["bb"])
        XCTAssertTrue(guidance.contains("brew install borkdude/brew/babashka"))
        XCTAssertTrue(guidance.contains("AGENTS_BB"))
        XCTAssertFalse(guidance.contains("brew install jj"))
        XCTAssertFalse(guidance.contains("git"))
    }
}
