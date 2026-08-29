import XCTest
@testable import Agents

@MainActor
final class ToolPreflightTests: XCTestCase {
    func testCustomManagerRootIsTrimmedAndChecked() {
        let result = check(
            environment: [
                "AGENTS_BB": "/custom/bb",
                "WORKSTREAM_MANAGER_ROOT": "  /custom/manager\n",
            ],
            homeDirectory: "/Users/test",
            executablePaths: ["/custom/bb"],
            regularFiles: ["/custom/manager/src/wsm/cli.clj"]
        )

        XCTAssertEqual(result.managerRoot, "/custom/manager")
        XCTAssertEqual(result.missing, [])
    }

    func testWhitespaceManagerOverrideFallsBackToInjectedHome() {
        let result = check(
            environment: [
                "AGENTS_BB": "/custom/bb",
                "WORKSTREAM_MANAGER_ROOT": " \t\n ",
            ],
            homeDirectory: "/Users/test",
            executablePaths: ["/custom/bb"],
            regularFiles: ["/Users/test/code/projects/workstream-manager/src/wsm/cli.clj"]
        )

        XCTAssertEqual(result.managerRoot, "/Users/test/code/projects/workstream-manager")
        XCTAssertEqual(result.missing, [])
    }

    func testBbAndManagerAreReportedIndependently() {
        let managerRoot = "/Users/test/code/projects/workstream-manager"
        let entryPoint = "\(managerRoot)/src/wsm/cli.clj"

        let bbMissing = check(
            environment: [:],
            homeDirectory: "/Users/test",
            regularFiles: [entryPoint]
        )
        XCTAssertEqual(bbMissing.missing, [.bb])

        let managerMissing = check(
            environment: [:],
            homeDirectory: "/Users/test",
            executablePaths: ["/opt/homebrew/bin/bb"]
        )
        XCTAssertEqual(managerMissing.missing, [.workstreamManager])
    }

    func testBothMissingAreReportedInStableOrder() {
        let result = check(environment: [:], homeDirectory: "/Users/test")

        XCTAssertEqual(result.missing, [.bb, .workstreamManager])
    }

    func testManagerEntryPointMustBeARegularFile() throws {
        let fileManager = FileManager.default
        let managerRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let entryPoint = managerRoot.appendingPathComponent("src/wsm/cli.clj")
        defer { try? fileManager.removeItem(at: managerRoot) }
        try fileManager.createDirectory(at: entryPoint, withIntermediateDirectories: true)

        let directoryResult = ToolPreflight.check(
            environment: ["WORKSTREAM_MANAGER_ROOT": managerRoot.path],
            homeDirectory: "/unused",
            isExecutable: { _ in true }
        )
        XCTAssertEqual(directoryResult.missing, [.workstreamManager])

        try fileManager.removeItem(at: entryPoint)
        XCTAssertTrue(fileManager.createFile(atPath: entryPoint.path, contents: Data()))
        let fileResult = ToolPreflight.check(
            environment: ["WORKSTREAM_MANAGER_ROOT": managerRoot.path],
            homeDirectory: "/unused",
            isExecutable: { _ in true }
        )
        XCTAssertEqual(fileResult.missing, [])
    }

    func testPresentPrerequisitesProduceNoGuidance() {
        let result = check(
            environment: [:],
            homeDirectory: "/Users/test",
            executablePaths: ["/usr/local/bin/bb"],
            regularFiles: ["/Users/test/code/projects/workstream-manager/src/wsm/cli.clj"]
        )

        XCTAssertEqual(result.missing, [])
        XCTAssertNil(ToolPreflight.guidance(for: result))
    }

    func testNonExecutableBbOverrideFallsThroughToHomebrew() {
        let result = check(
            environment: ["AGENTS_BB": "/bogus/bb"],
            homeDirectory: "/Users/test",
            executablePaths: ["/usr/local/bin/bb"],
            regularFiles: ["/Users/test/code/projects/workstream-manager/src/wsm/cli.clj"]
        )

        XCTAssertEqual(result.missing, [])
    }

    func testBbGuidanceIsIndependent() throws {
        let result = ToolPreflight.Result(managerRoot: "/manager", missing: [.bb])
        let guidance = try XCTUnwrap(ToolPreflight.guidance(for: result))

        XCTAssertTrue(guidance.contains("brew install borkdude/brew/babashka"))
        XCTAssertTrue(guidance.contains("AGENTS_BB"))
        XCTAssertFalse(guidance.contains("workstream-manager"))
        XCTAssertFalse(guidance.contains("WORKSTREAM_MANAGER_ROOT"))
    }

    func testManagerGuidanceIncludesMissingPathAndCheckoutInstructions() throws {
        let result = ToolPreflight.Result(
            managerRoot: "/custom/manager",
            missing: [.workstreamManager]
        )
        let guidance = try XCTUnwrap(ToolPreflight.guidance(for: result))

        XCTAssertTrue(guidance.contains("/custom/manager/src/wsm/cli.clj"))
        XCTAssertTrue(guidance.contains("https://github.com/kirahowe/workstream-manager"))
        XCTAssertTrue(guidance.contains("$HOME/code/projects/workstream-manager"))
        XCTAssertTrue(guidance.contains("into:\n/custom/manager"))
        XCTAssertTrue(guidance.contains("WORKSTREAM_MANAGER_ROOT"))
        XCTAssertFalse(guidance.contains("brew install borkdude/brew/babashka"))
    }

    func testCombinedGuidanceUsesStableOrderWithoutUniversalVCSRequirements() throws {
        let result = ToolPreflight.Result(
            managerRoot: "/custom/manager",
            missing: [.bb, .workstreamManager]
        )
        let guidance = try XCTUnwrap(ToolPreflight.guidance(for: result))
        let bbRange = try XCTUnwrap(guidance.range(of: "bb not found"))
        let managerRange = try XCTUnwrap(guidance.range(of: "workstream-manager entry point not found"))

        XCTAssertLessThan(bbRange.lowerBound, managerRange.lowerBound)
        XCTAssertFalse(guidance.contains("brew install jj"))
        XCTAssertFalse(guidance.contains("brew install git"))
        XCTAssertFalse(guidance.contains("jj or git"))
    }

    private func check(
        environment: [String: String],
        homeDirectory: String,
        executablePaths: Set<String> = [],
        regularFiles: Set<String> = []
    ) -> ToolPreflight.Result {
        ToolPreflight.check(
            environment: environment,
            homeDirectory: homeDirectory,
            isExecutable: executablePaths.contains,
            isRegularFile: regularFiles.contains
        )
    }
}
