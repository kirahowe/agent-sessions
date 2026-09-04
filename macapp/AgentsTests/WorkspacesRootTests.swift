import XCTest
@testable import Agents

final class WorkspacesRootTests: XCTestCase {
    func test_directory_isProjectKeyedUnderDotAgentsWorkspaces() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let directory = WorkspacesRoot.directory(forProject: "/Users/someone/code/agents", home: home)
        let key = WorkspacesRoot.projectKey(forProject: "/Users/someone/code/agents")

        XCTAssertEqual(directory, "/Users/someone/.agents/workspaces/" + key)
    }

    func test_projectKey_isBasenamePlusShortHash() {
        let key = WorkspacesRoot.projectKey(forProject: "/Users/someone/code/agents")
        let pattern = NSPredicate(format: "SELF MATCHES %@", "^agents-[0-9a-f]{8}$")

        XCTAssertTrue(pattern.evaluate(with: key), "expected agents-<8 hex>, got \(key)")
        XCTAssertEqual(key, WorkspacesRoot.projectKey(forProject: "/Users/someone/code/agents"), "deterministic")
    }

    func test_projectKey_ignoresTrailingSlashAndDotSegments() {
        let plain = WorkspacesRoot.projectKey(forProject: "/Users/someone/code/agents")

        XCTAssertEqual(WorkspacesRoot.projectKey(forProject: "/Users/someone/code/agents/"), plain)
        XCTAssertEqual(WorkspacesRoot.projectKey(forProject: "/Users/someone/code/other/../agents"), plain)
        XCTAssertEqual(WorkspacesRoot.projectKey(forProject: "/Users/someone/code/./agents"), plain)
    }

    func test_projectKey_resolvesSymlinksToTheSameCheckout() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspacesRootTests-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real-project")
        let link = base.appendingPathComponent("linked-project")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertEqual(
            WorkspacesRoot.projectKey(forProject: link.path),
            WorkspacesRoot.projectKey(forProject: real.path)
        )
    }

    func test_projectKey_separatesSameNamedCheckouts() {
        let one = WorkspacesRoot.projectKey(forProject: "/Users/someone/code/website")
        let two = WorkspacesRoot.projectKey(forProject: "/Users/someone/scratch/website")

        XCTAssertTrue(one.hasPrefix("website-"))
        XCTAssertTrue(two.hasPrefix("website-"))
        XCTAssertNotEqual(one, two, "same basename, different checkout, different directory")
    }
}
