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

    /// Custom error thrown when a required tool is missing in CI mode.
    /// Skip locally for convenience, but CI must fail hard to catch
    /// misconfigured environments before they mask integration failures.
    private struct MissingToolError: Error, CustomStringConvertible {
        let toolName: String

        var description: String {
            "\(toolName) not installed, but AGENTS_REQUIRE_TOOLS=1 — install it on CI instead of silently skipping the Swift↔CLI integration coverage"
        }
    }

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

    /// Throws XCTSkip or MissingToolError depending on environment.
    /// When AGENTS_REQUIRE_TOOLS="1", throws MissingToolError so CI fails hard.
    /// Otherwise, throws XCTSkip for developer convenience.
    private func missingToolThrow(_ toolName: String) throws -> Never {
        if ProcessInfo.processInfo.environment["AGENTS_REQUIRE_TOOLS"] == "1" {
            throw MissingToolError(toolName: toolName)
        } else {
            throw XCTSkip("\(toolName) not installed")
        }
    }

    /// Call at the top of every test: fails soft (XCTSkip) rather than hard
    /// in environments without jj/bb installed, since this suite's whole
    /// point is exercising the real subprocess seam.
    ///
    /// Two modes:
    /// - **Developer (default)**: Missing tools throw XCTSkip, soft-skipping the test.
    ///   Convenient for local development without a full environment.
    /// - **CI (AGENTS_REQUIRE_TOOLS=1)**: Missing tools throw MissingToolError,
    ///   a hard failure. CI must never silently skip — this suite is the only
    ///   integration coverage of the Swift↔CLI seam. A missing tool on CI is
    ///   a configuration problem, not a reason to hide it.
    private func requireTools() throws -> (jj: String, bb: String) {
        guard let jj = Self.resolveJJPath() else { try missingToolThrow("jj") }
        guard let bb = Self.resolveBBPath() else { try missingToolThrow("bb") }
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

        // Workspaces nest INSIDE the project (<project>/workspaces/<name>),
        // not alongside it in a directory shared by every project under the
        // same parent — see agents-cli's workspaces-root doc comment for why
        // (jj's per-workspace working-copy tracking makes the nested
        // directory invisible to the outer workspace; the repo-root
        // .gitignore's /workspaces/ entry is what keeps plain git happy
        // about it).
        let expectedPath = projectDir + "/workspaces/" + row.name
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

    // MARK: - runProcess deadlock regression

    /// Regression test for the pipe-read deadlock: the old implementation
    /// only started draining stdout/stderr in `terminationHandler`, AFTER
    /// the process exited. A child writing more than the pipe buffer
    /// (~64KB) before exiting would block forever in write() with nobody
    /// reading yet, and the process would never exit to fire that handler —
    /// a permanent hang. This needs no jj/bb, only `/bin/sh`, so it runs
    /// unconditionally (no `requireTools()`/XCTSkip path) rather than being
    /// soft-skipped in tool-less environments.
    func test_runProcess_drainsOutputLargerThanPipeBufferWithoutDeadlocking() async throws {
        let result = try await WorkspaceEngineCLI.runProcess(
            bb: "/bin/sh",
            scriptPath: "-c",
            args: ["dd if=/dev/zero bs=1024 count=200 2>/dev/null | tr '\\0' 'x'"]
        )

        XCTAssertEqual(result.stdout.count, 204800, "200KB of output is comfortably past the ~64KB pipe buffer that deadlocked the old drain-after-exit implementation")
        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - Envelope decoding for workspace-land-preview / rebase-onto-trunk

    /// Every test above this point drives the REAL agents-cli against a
    /// REAL jj repo, because their whole point is proving the Swift<->CLI
    /// process seam works end to end. These tests want something narrower:
    /// does `WorkspaceEngineCLI` decode a given JSON envelope correctly?
    /// That question doesn't need a real jj repo, or even the real
    /// workspace-land-preview/rebase-onto-trunk subcommands to exist yet —
    /// it needs a `bb` that prints a chosen envelope and exits.
    ///
    /// `AGENTS_BB` is `resolveBBPath`'s dev-override env var, checked
    /// BEFORE any Homebrew candidate (see WorkspaceEngine.swift) — pointing
    /// it at a throwaway shell script that ignores its arguments and just
    /// cats a canned envelope makes `WorkspaceEngineCLI` run its real
    /// decode/error-mapping logic against exactly the bytes each test
    /// wants, with no dependency on jj/bb being installed or on the CLI
    /// side of this feature having landed. `resolveScriptURL` still needs
    /// SOME agents-cli to exist, but the test host already bundles the
    /// real one as a resource (see this file's own header comment) — our
    /// stub `bb` never actually interprets it, so which one that is
    /// doesn't matter.
    private func withStubBB(json: String, _ body: () async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceEngineCLITests-stub-bb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let scriptURL = dir.appendingPathComponent("bb")
        // Ignores $1 (the real agents-cli script path) and $2... (the
        // subcommand + its own flags) entirely — this stub answers every
        // invocation the same way, because each test only ever makes one
        // call through it.
        let script = "#!/bin/sh\ncat <<'STUB_BB_EOF'\n\(json)\nSTUB_BB_EOF\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let previous = ProcessInfo.processInfo.environment["AGENTS_BB"]
        setenv("AGENTS_BB", scriptURL.path, 1)
        defer {
            if let previous {
                setenv("AGENTS_BB", previous, 1)
            } else {
                unsetenv("AGENTS_BB")
            }
        }

        try await body()
    }

    private func makeWorkspace() -> WorkspaceRow {
        WorkspaceRow(projectPath: "/tmp/proj-stub", name: "ws-stub", path: "/tmp/workspaces/ws-stub", label: nil)
    }

    func test_previewLand_decodesFullPreviewPayload() async throws {
        let json = """
        {"ok":true,"preview":{"bookmark":"main","bookmark_commit":"efdd547b","commits":[{"id":"5178cc25","subject":"Name the dev bundle Agents Dev.app on disk"}],"conflicts":[],"needs_message":false,"diverging":[{"id":"0071bbf4","subject":"Badge the Dock with blocked session count"}]}}
        """
        try await withStubBB(json: json) {
            let preview = try await WorkspaceEngineCLI().previewLand(self.makeWorkspace())

            XCTAssertEqual(preview.bookmark, "main")
            XCTAssertEqual(preview.bookmarkCommit, "efdd547b")
            XCTAssertEqual(preview.commits, [LandCommit(id: "5178cc25", subject: "Name the dev bundle Agents Dev.app on disk")])
            XCTAssertEqual(preview.conflicts, [])
            XCTAssertFalse(preview.needsMessage)
            XCTAssertEqual(preview.diverging, [LandCommit(id: "0071bbf4", subject: "Badge the Dock with blocked session count")])
        }
    }

    func test_previewLand_missingPreviewPayloadOnOkTrueThrowsContractViolation() async throws {
        try await withStubBB(json: #"{"ok":true}"#) {
            do {
                _ = try await WorkspaceEngineCLI().previewLand(self.makeWorkspace())
                XCTFail("expected a thrown EngineError.failed for a missing preview payload")
            } catch EngineError.failed(let message) {
                XCTAssertTrue(message.contains("preview payload"), "expected the contract-violation message to mention the missing preview payload, got: \(message)")
            } catch {
                XCTFail("expected EngineError.failed, got \(error)")
            }
        }
    }

    /// `workspace-land-preview` throws the SAME error codes as
    /// `workspace-land` in the same situations (per the CLI contract) — one
    /// representative each, pinning that `engineError(for:)`'s mapping
    /// applies uniformly regardless of which subcommand's envelope it's
    /// decoding.
    func test_previewLand_errorEnvelopeCodesMapToTheirEngineErrors() async throws {
        let cases: [(code: String, expect: (EngineError) -> Bool)] = [
            ("not-a-jj-repo", { if case .notAJJRepo = $0 { return true }; return false }),
            ("no-trunk", { if case .noTrunk = $0 { return true }; return false }),
            ("nothing-to-land", { if case .nothingToLand = $0 { return true }; return false }),
            ("shared-history", { if case .sharedHistory = $0 { return true }; return false }),
        ]
        for testCase in cases {
            let json = #"{"ok":false,"error":{"code":"\#(testCase.code)","message":"stub message for \#(testCase.code)"}}"#
            try await withStubBB(json: json) {
                do {
                    _ = try await WorkspaceEngineCLI().previewLand(self.makeWorkspace())
                    XCTFail("expected a thrown EngineError for code \(testCase.code)")
                } catch let error as EngineError {
                    XCTAssertTrue(testCase.expect(error), "code \(testCase.code) mapped to the wrong EngineError case: \(error)")
                    XCTAssertEqual(error.message, "stub message for \(testCase.code)")
                } catch {
                    XCTFail("expected EngineError, got \(error)")
                }
            }
        }
    }

    func test_rebaseOntoTrunk_decodesRebasedPayload() async throws {
        try await withStubBB(json: #"{"ok":true,"rebased":{"count":3,"bookmark":"main"}}"#) {
            let count = try await WorkspaceEngineCLI().rebaseOntoTrunk(projectPath: "/tmp/proj-stub")
            XCTAssertEqual(count, 3)
        }
    }

    func test_rebaseOntoTrunk_missingRebasedPayloadOnOkTrueThrowsContractViolation() async throws {
        try await withStubBB(json: #"{"ok":true}"#) {
            do {
                _ = try await WorkspaceEngineCLI().rebaseOntoTrunk(projectPath: "/tmp/proj-stub")
                XCTFail("expected a thrown EngineError.failed for a missing rebased payload")
            } catch EngineError.failed(let message) {
                XCTAssertTrue(message.contains("rebased payload"), "expected the contract-violation message to mention the missing rebased payload, got: \(message)")
            } catch {
                XCTFail("expected EngineError.failed, got \(error)")
            }
        }
    }

    /// The one error code new to this pair of subcommands: a rebase that
    /// hits a conflict maps to `EngineError.rebaseConflict`, distinct from
    /// `workspace-land`'s own `land-conflict` (see `EngineError.rebaseConflict`'s
    /// doc comment in WorkspaceEngine.swift for why they're kept separate).
    func test_rebaseOntoTrunk_rebaseConflictErrorMapsToEngineErrorRebaseConflict() async throws {
        let json = #"{"ok":false,"error":{"code":"rebase-conflict","message":"rebase hit a conflict"}}"#
        try await withStubBB(json: json) {
            do {
                _ = try await WorkspaceEngineCLI().rebaseOntoTrunk(projectPath: "/tmp/proj-stub")
                XCTFail("expected a thrown EngineError.rebaseConflict")
            } catch EngineError.rebaseConflict(let message) {
                XCTAssertEqual(message, "rebase hit a conflict")
            } catch {
                XCTFail("expected EngineError.rebaseConflict, got \(error)")
            }
        }
    }
}
