import XCTest
@testable import Agents

/// Each numbered comment corresponds to a resolution-semantics case that
/// must exactly match the two real resolvers ToolPreflight mirrors
/// (WorkspaceEngineCLI.resolveBBPath() and cli/agents-cli's resolve-jj).
/// Every test drives `ToolPreflight.missingTools()` purely through injected
/// `environment`/`isExecutable` parameters — never real filesystem or
/// environment access — so these are hermetic and never touch the actual
/// machine's bb/jj installs.
@MainActor
final class ToolPreflightTests: XCTestCase {

    // MARK: - 1

    func test01_bothToolsFoundViaEnvOverrides() {
        let environment = ["AGENTS_BB": "/custom/bb", "AGENTS_JJ": "/custom/jj"]
        let missing = ToolPreflight.missingTools(
            environment: environment,
            isExecutable: { path in path == "/custom/bb" || path == "/custom/jj" }
        )
        XCTAssertEqual(missing, [])
    }

    // MARK: - 2

    func test02_bothToolsMissingEverywhere() {
        let missing = ToolPreflight.missingTools(
            environment: [:],
            isExecutable: { _ in false }
        )
        XCTAssertEqual(missing, ["bb", "jj"], "bb must be reported before jj")
    }

    // MARK: - 3

    func test03_jjFoundViaPathScanBbFoundViaHomebrewCandidate() {
        let environment = ["PATH": "/some/empty/dir:/some/dir/with/jj"]
        let missing = ToolPreflight.missingTools(
            environment: environment,
            isExecutable: { path in
                path == "/opt/homebrew/bin/bb" || path == "/some/dir/with/jj/jj"
            }
        )
        XCTAssertEqual(missing, [], "PATH scan should find jj in the second PATH component, not the first")
    }

    // MARK: - 4

    func test04a_bbEnvOverrideNotExecutableFallsThroughToHomebrewCandidate() {
        let environment = ["AGENTS_BB": "/bogus/bb"]
        let missing = ToolPreflight.missingTools(
            environment: environment,
            isExecutable: { path in path == "/opt/homebrew/bin/bb" }
        )
        XCTAssertFalse(missing.contains("bb"), "a non-executable override must fall through to the Homebrew candidates")
    }

    func test04b_bbEnvOverrideNotExecutableAndNoHomebrewCandidateReportsMissing() {
        let environment = ["AGENTS_BB": "/bogus/bb"]
        let missing = ToolPreflight.missingTools(
            environment: environment,
            isExecutable: { _ in false }
        )
        XCTAssertTrue(missing.contains("bb"))
    }

    // MARK: - 5

    func test05a_guidanceForBothToolsMentionsBothInstallCommandsAndEnvVars() {
        let guidance = ToolPreflight.guidance(for: ["bb", "jj"])
        XCTAssertTrue(guidance.contains("brew install borkdude/brew/babashka"))
        XCTAssertTrue(guidance.contains("brew install jj"))
        XCTAssertTrue(guidance.contains("AGENTS_BB"))
        XCTAssertTrue(guidance.contains("AGENTS_JJ"))
    }

    func test05b_guidanceForBbAloneMentionsOnlyBbInstallCommand() {
        let guidance = ToolPreflight.guidance(for: ["bb"])
        XCTAssertTrue(guidance.contains("brew install borkdude/brew/babashka"))
        XCTAssertFalse(guidance.contains("brew install jj"))
    }

    // MARK: - 6

    func test06_jjEnvOverrideWhitespaceOnlyDoesNotCountAsValid() {
        let environment = ["AGENTS_JJ": " "]
        let missing = ToolPreflight.missingTools(
            environment: environment,
            isExecutable: { path in path == " " }
        )
        XCTAssertTrue(missing.contains("jj"), "a whitespace-only override must be treated as blank, matching str/blank?")
    }
}
