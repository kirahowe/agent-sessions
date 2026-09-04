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
/// TEST_HOST), which bundles only cli/agents-cli as a resource. Real CLI
/// cases resolve workstream-manager from WORKSTREAM_MANAGER_ROOT or the
/// default local checkout, while the stub-envelope cases below need no
/// manager checkout.
@MainActor
final class WorkspaceEngineCLITests: XCTestCase {

    // MARK: - Integration prerequisites

    /// Custom error thrown when a required integration dependency is missing.
    /// Skip locally for convenience, but CI must fail hard to catch
    /// misconfigured environments before they mask integration failures.
    private struct MissingRequiredDependencyError: Error, CustomStringConvertible {
        let dependency: String

        var description: String {
            "\(dependency) is unavailable, but AGENTS_REQUIRE_TOOLS=1 — provision it on CI instead of silently skipping the Swift↔CLI integration coverage"
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

    private static func resolveWorkstreamManagerRoot() -> String {
        if let configured = ProcessInfo.processInfo.environment["WORKSTREAM_MANAGER_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return configured
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("code/projects/workstream-manager")
            .path
    }

    /// The manager is intentionally a local dependency until it is published.
    private func requireWorkstreamManager() throws {
        let root = Self.resolveWorkstreamManagerRoot()
        let entrypoint = URL(fileURLWithPath: root)
            .appendingPathComponent("src/wsm/cli.clj")
            .path
        guard FileManager.default.fileExists(atPath: entrypoint) else {
            try missingRequiredDependency("local workstream-manager checkout at \(root)")
        }
        setenv("WORKSTREAM_MANAGER_ROOT", root, 1)
    }

    private func missingRequiredDependency(_ dependency: String) throws -> Never {
        if ProcessInfo.processInfo.environment["AGENTS_REQUIRE_TOOLS"] == "1" {
            throw MissingRequiredDependencyError(dependency: dependency)
        } else {
            throw XCTSkip("\(dependency) is unavailable")
        }
    }

    /// Call at the top of every real CLI integration test. Tools and the
    /// manager checkout skip for local convenience, but are hard failures when
    /// AGENTS_REQUIRE_TOOLS is set for CI.
    private func requireTools() throws -> (jj: String, bb: String) {
        guard let jj = Self.resolveJJPath() else { try missingRequiredDependency("jj") }
        guard let bb = Self.resolveBBPath() else { try missingRequiredDependency("bb") }
        try requireWorkstreamManager()
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

        let workspacesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceEngineCLITests-root-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: workspacesRoot) }

        // Inject the root so the test never writes under the real
        // ~/.agents/workspaces; the production wiring is pinned by
        // test_createWorkspace_passesTheProjectKeyedWorkspacesRoot.
        let engine = WorkspaceEngineCLI(workspacesRoot: { _ in workspacesRoot })
        let row = try await engine.createWorkspace(projectPath: projectDir)

        let namePredicate = NSPredicate(format: "SELF MATCHES %@", "^[a-z]+-[a-z]+$")
        XCTAssertTrue(namePredicate.evaluate(with: row.name), "expected a two-word adjective-noun name, got \(row.name)")

        // Workspaces live under the root the engine passes as
        // --workspaces-root, never inside the project: a nested directory
        // is wiped by `git clean -fdx` at the project root and has to be
        // hidden from every tool that walks the tree.
        let expectedPath = workspacesRoot + "/" + row.name
        XCTAssertEqual(row.path, expectedPath)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: projectDir + "/workspaces"),
            "nothing may be created inside the project itself"
        )

        // The CLI absolutizes the project path server-side, and on macOS
        // temp dirs are often under a symlink (/tmp -> /private/tmp), so
        // compare resolved paths rather than raw strings to avoid a flake.
        let resolvedRowProject = URL(fileURLWithPath: row.projectPath).resolvingSymlinksInPath().path
        let resolvedProjectDir = URL(fileURLWithPath: projectDir).resolvingSymlinksInPath().path
        XCTAssertEqual(resolvedRowProject, resolvedProjectDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: row.path), "workspace directory should exist on disk after creation")

        do {
            _ = try await engine.deleteWorkspace(row, onlyIfUnchanged: false)
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
    func test_createWorkspace_onNonRepoDirectory_throwsNotARepo() async throws {
        _ = try requireTools()

        let nonRepoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceEngineCLITests-nonrepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: nonRepoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nonRepoDir) }

        let engine = WorkspaceEngineCLI(
            workspacesRoot: { _ in nonRepoDir.appendingPathComponent("unused-root").path }
        )

        do {
            _ = try await engine.createWorkspace(projectPath: nonRepoDir.path)
            XCTFail("expected createWorkspace to throw for a non-repository directory")
        } catch let error as EngineError {
            guard case .notARepo = error else {
                XCTFail("expected .notARepo, got \(error)")
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

    // MARK: - Envelope decoding for external wsm.cli workspace commands

    /// Every test above this point drives the REAL agents-cli against a
    /// REAL jj repo, because their whole point is proving the Swift<->CLI
    /// process seam works end to end. These tests want something narrower:
    /// does `WorkspaceEngineCLI` decode a given JSON envelope correctly?
    /// That focused decoding question uses a `bb` stub for the external
    /// `wsm.cli` envelope; end-to-end behavior is covered above.
    ///
    /// `AGENTS_BB` is `resolveBBPath`'s dev-override env var, checked
    /// BEFORE any Homebrew candidate (see WorkspaceEngine.swift) — pointing
    /// it at a throwaway shell script that records its arguments and cats a
    /// canned envelope makes WorkspaceEngineCLI run its real argument and
    /// decode/error-mapping logic against exactly what each test wants, with
    /// no dependency on jj/bb being installed or on the CLI
    /// side of this feature having landed. `resolveScriptURL` still needs
    /// SOME agents-cli to exist, but the test host already bundles the
    /// real one as a resource (see this file's own header comment) — our
    /// stub `bb` never actually interprets it, so which one that is
    /// doesn't matter.
    @discardableResult
    private func withStubBB(
        json: String,
        _ body: () async throws -> Void
    ) async throws -> [String] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceEngineCLITests-stub-bb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let scriptURL = dir.appendingPathComponent("bb")
        let argumentsURL = dir.appendingPathComponent("arguments")
        // Capture the real invocation while returning one canned envelope.
        // This exercises both decoding and argument construction without
        // needing the external CLI implementation under test.
        let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argumentsURL.path)'\ncat <<'STUB_BB_EOF'\n\(json)\nSTUB_BB_EOF\n"
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
        return try String(contentsOf: argumentsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }

    private func makeWorkspace() -> WorkspaceRow {
        WorkspaceRow(projectPath: "/tmp/proj-stub", name: "ws-stub", path: "/tmp/workspaces/ws-stub", label: nil)
    }

    func test_deleteWorkspace_forgetFailureDoesNotAttemptLocalCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceEngineCLITests-delete-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceRow(
            projectPath: "/tmp/project",
            name: "ws",
            path: directory.path,
            label: nil
        )
        let json = #"{"ok":false,"error":{"code":"failed","message":"forget failed"}}"#

        try await withStubBB(json: json) {
            let engine = WorkspaceEngineCLI(trashWorkspaceDirectory: { _ in
                XCTFail("local cleanup must not run before workspace-forget succeeds")
            })
            do {
                _ = try await engine.deleteWorkspace(workspace, onlyIfUnchanged: false)
                XCTFail("expected forget failure")
            } catch EngineError.failed(let message) {
                XCTAssertEqual(message, "forget failed")
            } catch {
                XCTFail("expected EngineError.failed, got \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func test_deleteWorkspace_trashFailureAfterForgetReturnsCleanupWarning() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceEngineCLITests-delete-warning-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceRow(
            projectPath: "/tmp/project",
            name: "ws",
            path: directory.path,
            label: nil
        )

        try await withStubBB(json: #"{"ok":true}"#) {
            let engine = WorkspaceEngineCLI(trashWorkspaceDirectory: { _ in
                throw CocoaError(.fileWriteNoPermission)
            })
            let result = try await engine.deleteWorkspace(workspace, onlyIfUnchanged: false)

            XCTAssertEqual(
                result.cleanupWarning,
                "The workspace was closed, but its folder couldn't be moved to the Bin — it's still at \(directory.path)"
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    /// A land success now means one thing only: the engine deregistered the
    /// workspace. The leftover directory is always the app's to move to the
    /// Bin, and the engine's own non-fatal warning rides along with it.
    func test_landWorkspace_successAlwaysTrashesTheLeftoverDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceEngineCLITests-landed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceRow(
            projectPath: "/tmp/project",
            name: "ws",
            path: directory.path,
            label: nil
        )
        let warning = "The obsolete workspace branch remains."
        let json = #"{"ok":true,"landed":{"commit_id":"abc","bookmark":"main","workspace":"ws"},"warning":"The obsolete workspace branch remains."}"#
        var trashCalls = 0

        try await withStubBB(json: json) {
            let engine = WorkspaceEngineCLI(trashWorkspaceDirectory: { url in
                trashCalls += 1
                try FileManager.default.removeItem(at: url)
            })
            let result = try await engine.landWorkspace(
                workspace,
                message: nil,
                createTrunk: nil
            )

            XCTAssertEqual(result.commitID, "abc")
            XCTAssertEqual(result.bookmark, "main")
            XCTAssertEqual(result.cleanupWarning, warning)
        }

        XCTAssertEqual(trashCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// `cleanup-failed` is its own outcome: the trunk moved but the workspace
    /// could not be deregistered. It must not collapse into the generic
    /// `.failed`, because only the engine's message describes that state, and
    /// AppStore shows it verbatim.
    func test_landWorkspace_cleanupFailedMapsToItsOwnEngineErrorWithTheCLIMessage() async throws {
        let message = "Added the changes to main, but could not forget the workspace: it is still registered."
        let json = #"{"ok":false,"error":{"code":"cleanup-failed","message":"\#(message)"}}"#
        try await withStubBB(json: json) {
            do {
                _ = try await WorkspaceEngineCLI().landWorkspace(
                    self.makeWorkspace(),
                    message: nil,
                    createTrunk: nil
                )
                XCTFail("expected a thrown EngineError.cleanupFailed")
            } catch EngineError.cleanupFailed(let thrown) {
                XCTAssertEqual(thrown, message)
            } catch {
                XCTFail("expected EngineError.cleanupFailed, got \(error)")
            }
        }
    }

    /// The one subcommand that learns where workspaces go. A default-built
    /// engine must send the app-owned, project-keyed root, and an injected
    /// resolver must be honored verbatim.
    func test_createWorkspace_passesTheProjectKeyedWorkspacesRoot() async throws {
        let envelope = #"{"ok":true,"workspace":{"name":"ws-stub","jj_name":"agents/ws-stub","path":"/tmp/roots/ws-stub","project":"/tmp/proj-stub","vcs":"jj"}}"#

        let defaultArguments = try await withStubBB(json: envelope) {
            _ = try await WorkspaceEngineCLI().createWorkspace(projectPath: "/tmp/proj-stub")
        }
        XCTAssertEqual(
            Array(defaultArguments.dropFirst()),
            [
                "workspace-add",
                "--project", "/tmp/proj-stub",
                "--workspaces-root", WorkspacesRoot.directory(forProject: "/tmp/proj-stub"),
            ]
        )

        let injectedArguments = try await withStubBB(json: envelope) {
            let engine = WorkspaceEngineCLI(workspacesRoot: { projectPath in
                "/tmp/roots/" + (projectPath as NSString).lastPathComponent
            })
            let row = try await engine.createWorkspace(projectPath: "/tmp/proj-stub")
            XCTAssertEqual(row.path, "/tmp/roots/ws-stub", "the row keeps the CLI's reported path")
        }
        XCTAssertEqual(
            Array(injectedArguments.dropFirst()),
            ["workspace-add", "--project", "/tmp/proj-stub", "--workspaces-root", "/tmp/roots/proj-stub"]
        )
    }

    func test_deleteWorkspace_guardedForgetUsesManagerSideRecheckAndCreatesMainTrunk() async throws {
        let arguments = try await withStubBB(json: #"{"ok":true}"#) {
            _ = try await WorkspaceEngineCLI().deleteWorkspace(
                self.makeWorkspace(),
                onlyIfUnchanged: true
            )
        }

        XCTAssertEqual(
            Array(arguments.dropFirst()),
            [
                "workspace-forget",
                "--project", "/tmp/proj-stub",
                "--name", "ws-stub",
                "--if-unchanged",
                "--create-trunk", "main",
            ]
        )
    }

    func test_deleteWorkspace_destructiveForgetOmitsUnchangedGuard() async throws {
        let arguments = try await withStubBB(json: #"{"ok":true}"#) {
            _ = try await WorkspaceEngineCLI().deleteWorkspace(
                self.makeWorkspace(),
                onlyIfUnchanged: false
            )
        }

        XCTAssertEqual(
            Array(arguments.dropFirst()),
            ["workspace-forget", "--project", "/tmp/proj-stub", "--name", "ws-stub"]
        )
    }

    /// The CLI rejects unknown options outright, so sending either of the
    /// retired flags would turn every close into a `bad-args` failure. Pin the
    /// exact argument list to keep them from creeping back.
    func test_landWorkspace_sendsNeitherRetiredFlag() async throws {
        let json = #"{"ok":true,"landed":{"commit_id":"abc","bookmark":"main","workspace":"ws-stub"}}"#
        let arguments = try await withStubBB(json: json) {
            _ = try await WorkspaceEngineCLI().landWorkspace(
                self.makeWorkspace(),
                message: "Summarise the draft",
                createTrunk: "main"
            )
        }

        XCTAssertEqual(
            Array(arguments.dropFirst()),
            [
                "workspace-land",
                "--project", "/tmp/proj-stub",
                "--name", "ws-stub",
                "--message", "Summarise the draft",
                "--create-trunk", "main",
            ]
        )
        XCTAssertFalse(arguments.contains("--finalize-quiesced"))
        XCTAssertFalse(arguments.contains("--expected-snapshot"))
    }

    func test_deleteWorkspace_workspaceChangedMapsToTypedEngineError() async throws {
        let json = #"{"ok":false,"error":{"code":"workspace-changed","message":"workspace changed"}}"#
        try await withStubBB(json: json) {
            do {
                _ = try await WorkspaceEngineCLI().deleteWorkspace(
                    self.makeWorkspace(),
                    onlyIfUnchanged: true
                )
                XCTFail("expected guarded forget refusal")
            } catch EngineError.workspaceChanged(let message) {
                XCTAssertEqual(message, "workspace changed")
            } catch {
                XCTFail("expected EngineError.workspaceChanged, got \(error)")
            }
        }
    }

    func test_previewLand_appendsCreateTrunkOnlyWhenProvided() async throws {
        let json = """
        {"ok":true,"preview":{"bookmark":"main","bookmark_commit":"","commits":[],"conflicts":[],"needs_message":false}}
        """

        let ordinaryArguments = try await withStubBB(json: json) {
            _ = try await WorkspaceEngineCLI().previewLand(self.makeWorkspace())
        }
        XCTAssertEqual(
            Array(ordinaryArguments.dropFirst()),
            ["workspace-land-preview", "--project", "/tmp/proj-stub", "--name", "ws-stub"]
        )

        let setupArguments = try await withStubBB(json: json) {
            _ = try await WorkspaceEngineCLI().previewLand(
                self.makeWorkspace(),
                createTrunk: "main"
            )
        }
        XCTAssertEqual(
            Array(setupArguments.dropFirst()),
            [
                "workspace-land-preview",
                "--project", "/tmp/proj-stub",
                "--name", "ws-stub",
                "--create-trunk", "main"
            ]
        )
    }

    /// The preview envelope no longer carries `diverging` or
    /// `target_snapshot`; decoding must succeed on exactly the fields the
    /// engine sends now.
    func test_previewLand_decodesFullPreviewPayload() async throws {
        let json = """
        {"ok":true,"preview":{"bookmark":"main","bookmark_commit":"efdd547b","commits":[{"id":"5178cc25","subject":"Name the dev bundle Agents Dev.app on disk"}],"conflicts":[],"needs_message":false,"vcs":"jj"}}
        """
        try await withStubBB(json: json) {
            let preview = try await WorkspaceEngineCLI().previewLand(self.makeWorkspace())

            XCTAssertEqual(preview.bookmark, "main")
            XCTAssertEqual(preview.bookmarkCommit, "efdd547b")
            XCTAssertEqual(preview.commits, [LandCommit(id: "5178cc25", subject: "Name the dev bundle Agents Dev.app on disk")])
            XCTAssertEqual(preview.conflicts, [])
            XCTAssertFalse(preview.needsMessage)
        }
    }

    func test_previewLand_decodesGitConflictFilePaths() async throws {
        let json = """
        {"ok":true,"preview":{"bookmark":"main","bookmark_commit":"efdd547b","commits":[{"id":"5178cc25","subject":"Update close flow"}],"conflicts":[{"file":"Sources/CloseWorkspace.swift"},{"file":"Tests/CloseWorkspaceTests.swift"}],"needs_message":false}}
        """
        try await withStubBB(json: json) {
            let preview = try await WorkspaceEngineCLI().previewLand(self.makeWorkspace())
            XCTAssertEqual(
                preview.conflicts,
                [
                    LandCommit(id: "Sources/CloseWorkspace.swift", subject: "Sources/CloseWorkspace.swift"),
                    LandCommit(id: "Tests/CloseWorkspaceTests.swift", subject: "Tests/CloseWorkspaceTests.swift"),
                ]
            )
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
            ("not-a-repo", { if case .notARepo = $0 { return true }; return false }),
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
