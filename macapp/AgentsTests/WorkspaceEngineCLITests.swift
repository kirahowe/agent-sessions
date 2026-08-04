import XCTest
@testable import Agents

/// Integration test crossing the real Swift <-> CLI process seam: unlike
/// every other suite (which uses `FakeWorkspaceEngine` via
/// `TestSupport.makeStore()`), these tests drive the REAL
/// `WorkspaceEngineCLI` against a REAL `bb`-run `agents-cli` script and a
/// REAL throwaway jj repo. This is what caught the `workspace-forget`
/// regression: its success envelope is a bare `{"ok":true}` with no
/// `workspace` key, a shape `FakeWorkspaceEngine` never exercises because it
/// never touches agents-cli's actual JSON output.
///
/// The test host is the built Agents.app (see macapp/project.yml's
/// TEST_HOST), which bundles cli/agents-cli as a resource, so a plain
/// `WorkspaceEngineCLI()` here resolves both the script and `bb` with no
/// extra setup.
@MainActor
final class WorkspaceEngineCLITests: XCTestCase {

    // MARK: - Tool location (skip-soft if bb/jj aren't installed)

    /// Resolves an executable's absolute path by checking common Homebrew
    /// locations first, then falling back to `which` via `/usr/bin/env` --
    /// mirrors WorkspaceEngineCLI's own bb-resolution strategy closely
    /// enough to be a reasonable proxy, without depending on its (private)
    /// implementation.
    private static func resolveTool(named name: String, candidates: [String]) -> String? {
        let fm = FileManager.default
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty, fm.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    private static func resolveJJPath() -> String? {
        resolveTool(named: "jj", candidates: ["/opt/homebrew/bin/jj", "/usr/local/bin/jj"])
    }

    private static func resolveBBPath() -> String? {
        resolveTool(named: "bb", candidates: ["/opt/homebrew/bin/bb", "/usr/local/bin/bb"])
    }

    /// Call at the top of every test: fails soft (XCTSkip) rather than hard
    /// in environments without jj/bb installed, since this suite's whole
    /// point is exercising the real subprocess seam.
    private func requireTools() throws -> (jj: String, bb: String) {
        guard let jj = Self.resolveJJPath() else { throw XCTSkip("jj not installed") }
        guard let bb = Self.resolveBBPath() else { throw XCTSkip("bb not installed") }
        Self.ensurePathIncludesToolDirectories(jj: jj, bb: bb)
        return (jj, bb)
    }

    /// The xctest host (Agents.app, launched by xcodebuild/launchd rather
    /// than an interactive shell) does not inherit a shell's PATH, so it
    /// typically lacks /opt/homebrew/bin. That's harmless for every Process
    /// call in this file (they all use resolved absolute paths), but
    /// agents-cli's `run-jj` shells out to a bare "jj" and relies on PATH to
    /// find it -- and WorkspaceEngineCLI's own subprocess (bb, run with an
    /// absolute path) inherits ITS environment from this process. Without
    /// this, `createWorkspace`/`deleteWorkspace` fail with "Cannot run
    /// program \"jj\": ... No such file or directory" even though jj is
    /// installed. `Process.environment` is captured at launch time, so
    /// mutating PATH here (before constructing any `WorkspaceEngineCLI`)
    /// is sufficient -- no need to touch WorkspaceEngineCLI itself.
    private static func ensurePathIncludesToolDirectories(jj: String, bb: String) {
        let neededDirs = [jj, bb].map { ($0 as NSString).deletingLastPathComponent }
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var components = currentPath.split(separator: ":").map(String.init)
        for dir in neededDirs where !components.contains(dir) {
            components.append(dir)
        }
        setenv("PATH", components.joined(separator: ":"), 1)
    }

    // MARK: - Subprocess helper (synchronous; test setup only)

    @discardableResult
    private func runSync(_ executable: String, _ args: [String]) -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ("", "failed to launch \(executable): \(error)", -1)
        }
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (stdout, stderr, process.terminationStatus)
    }

    // MARK: - Temp jj repo helper

    /// Creates a fresh, real jj repo in a temp directory (a throwaway repo
    /// under the system temp dir -- NOT this project's own repo) with one
    /// snapshotted commit, for use as a `project` in createWorkspace tests.
    /// Caller is responsible for removing the returned directory.
    private func makeTempJJRepo(jj: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceEngineCLITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let initResult = runSync(jj, ["--quiet", "git", "init", dir.path])
        guard initResult.exitCode == 0 else {
            XCTFail("jj git init failed (exit \(initResult.exitCode)): \(initResult.stderr)")
            throw EngineError.failed("jj git init failed: \(initResult.stderr)")
        }

        let helloPath = dir.appendingPathComponent("hello.txt")
        try "hello from WorkspaceEngineCLITests\n".write(to: helloPath, atomically: true, encoding: .utf8)

        // `jj st` snapshots the working copy into a commit as a side effect.
        let snapshotResult = runSync(jj, ["--no-pager", "-R", dir.path, "st"])
        guard snapshotResult.exitCode == 0 else {
            XCTFail("jj st (snapshot) failed (exit \(snapshotResult.exitCode)): \(snapshotResult.stderr)")
            throw EngineError.failed("jj st failed: \(snapshotResult.stderr)")
        }

        return dir.path
    }

    // MARK: - Tests

    /// The regression test: pre-fix, `deleteWorkspace` always threw because
    /// `run` required a `workspace` payload on every success, but
    /// `workspace-forget`'s envelope never carries one.
    func test_createThenDeleteWorkspace_roundTripsThroughRealCLI() async throws {
        let tools = try requireTools()
        let projectDir = try makeTempJJRepo(jj: tools.jj)
        defer { try? FileManager.default.removeItem(atPath: projectDir) }

        let engine = WorkspaceEngineCLI()
        let row = try await engine.createWorkspace(projectPath: projectDir)

        let namePredicate = NSPredicate(format: "SELF MATCHES %@", "^[a-z]+-[a-z]+$")
        XCTAssertTrue(namePredicate.evaluate(with: row.name), "expected a two-word adjective-noun name, got \(row.name)")

        let expectedPath = (projectDir as NSString).deletingLastPathComponent + "/workspaces/" + row.name
        XCTAssertEqual(row.path, expectedPath)

        // The CLI absolutizes the project path server-side, and on macOS
        // temp dirs are often under a symlink (/tmp -> /private/tmp), so
        // compare resolved paths rather than raw strings to avoid a flake.
        let resolvedRowProject = URL(fileURLWithPath: row.projectPath).resolvingSymlinksInPath().path
        let resolvedProjectDir = URL(fileURLWithPath: projectDir).resolvingSymlinksInPath().path
        XCTAssertEqual(resolvedRowProject, resolvedProjectDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: row.path), "workspace directory should exist on disk after creation")

        do {
            try await engine.deleteWorkspace(row)
        } catch {
            XCTFail(
                "deleteWorkspace must not throw — workspace-forget returns a bare {\"ok\":true} envelope "
                    + "with no workspace payload, and the engine must treat that as success. \(error)"
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: row.path), "workspace directory should have been trashed")

        let listResult = runSync(tools.jj, ["--no-pager", "-R", projectDir, "workspace", "list"])
        XCTAssertFalse(
            listResult.stdout.contains("agents/\(row.name)"),
            "jj workspace list should no longer mention the forgotten workspace: \(listResult.stdout)"
        )
    }

    /// Confirms EngineError mapping still works correctly for an ok:false
    /// envelope now that `run` returns the raw Envelope instead of
    /// unwrapping a workspace payload itself.
    func test_createWorkspace_onNonRepoDirectory_throwsNotAJJRepo() async throws {
        _ = try requireTools()

        let nonRepoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceEngineCLITests-nonrepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: nonRepoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nonRepoDir) }

        let engine = WorkspaceEngineCLI()

        do {
            _ = try await engine.createWorkspace(projectPath: nonRepoDir.path)
            XCTFail("expected createWorkspace to throw for a non-jj-repo directory")
        } catch let error as EngineError {
            guard case .notAJJRepo = error else {
                XCTFail("expected .notAJJRepo, got \(error)")
                return
            }
        } catch {
            XCTFail("expected EngineError, got \(error)")
        }
    }
}
