import Foundation

enum EngineError: Error, Equatable {
    case notARepo(String)
    case nameConflict(String)
    case destExists(String)
    case failed(String)
    case noTrunk(String)
    case landConflict(String)
    case nothingToLand(String)
    case sharedHistory(String)
    case workspaceChanged(String)
    // Thrown by rebase-onto-trunk when reconciling the project working copy
    // after a successful close. This is follow-up attention, not a failure
    // of the close that already completed.
    case rebaseConflict(String)

    var message: String {
        switch self {
        case .notARepo(let m), .nameConflict(let m), .destExists(let m), .failed(let m),
             .noTrunk(let m), .landConflict(let m), .nothingToLand(let m), .sharedHistory(let m),
             .workspaceChanged(let m), .rebaseConflict(let m):
            return m
        }
    }
}

/// The result of successfully adding a workspace's changes to its project.
/// The identifiers are retained for the subprocess contract but are not
/// presented in the close-workspace experience.
struct LandResult: Equatable {
    let commitID: String
    let bookmark: String
    /// Non-nil when project progress was published but final cleanup left a
    /// follow-up the user should know about.
    var cleanupWarning: String? = nil
    /// True only when the engine still has a live workspace registration.
    /// AppStore must preserve its row, sessions, path, and selection.
    var workspaceRetained = false
}

/// Result of an irreversible workspace forget. Once this value is returned,
/// the engine no longer knows the workspace; local directory cleanup is only
/// a best-effort follow-up and must not make the operation appear retryable.
struct DeleteResult: Equatable {
    var cleanupWarning: String? = nil
}

/// One human-readable change summary returned by a close preview. `id` is
/// retained for the subprocess contract; presentation uses only `subject`.
struct LandCommit: Equatable {
    let id: String
    let subject: String
}

/// A preview of the changes a workspace can add to its project. Storage
/// details remain in the subprocess contract for compatibility, but the
/// close-workspace UI intentionally presents only summaries and conflicts.
struct LandPreview: Equatable {
    let bookmark: String
    let bookmarkCommit: String
    let commits: [LandCommit]
    /// Human-readable conflict details. For Git previews the subject is the
    /// conflicted file path; for Jujutsu previews it is the change summary.
    let conflicts: [LandCommit]
    let needsMessage: Bool
    /// Advisory compatibility data. The close UI ignores it and project-root
    /// reconciliation is requested automatically after every successful add.
    let diverging: [LandCommit]
    /// Opaque manager state captured with this exact preview.
    let targetSnapshot: String
}

@MainActor
protocol WorkspaceEngineProviding: AnyObject {
    func createWorkspace(projectPath: String) async throws -> WorkspaceRow
    func deleteWorkspace(
        _ workspace: WorkspaceRow,
        onlyIfUnchanged: Bool
    ) async throws -> DeleteResult
    func landWorkspace(
        _ workspace: WorkspaceRow,
        message: String?,
        createTrunk: String?,
        expectedSnapshot: String
    ) async throws -> LandResult
    func previewLand(_ workspace: WorkspaceRow, createTrunk: String?) async throws -> LandPreview
    /// Reconciles the project working copy after a successful close.
    /// Requested automatically unless the project root has a live session of
    /// its own — rewriting that working copy under a running terminal would
    /// be destructive, so AppStore defers to a manual refresh in that case
    /// instead. A conflict is non-fatal follow-up attention either way,
    /// because the workspace close has already succeeded.
    func rebaseOntoTrunk(projectPath: String) async throws -> Int
}

extension WorkspaceEngineProviding {
    func previewLand(_ workspace: WorkspaceRow) async throws -> LandPreview {
        try await previewLand(workspace, createTrunk: nil)
    }
}

/// Production conformer: drives the `agents-cli` wrapper as a subprocess to
/// create/forget workspaces through the external `wsm.cli` dependency. Every
/// invocation prints a single JSON envelope to stdout; this type resolves the
/// wrapper and `bb`, runs the process, and decodes that envelope.
final class WorkspaceEngineCLI: WorkspaceEngineProviding {
    // Explicitly nonisolated: conforming to the @MainActor protocol infers
    // whole-type MainActor isolation, which would otherwise make this
    // initializer MainActor-isolated too — and AppStore.init's default
    // argument (`engine: ... = WorkspaceEngineCLI()`) is evaluated in a
    // synchronous, nonisolated context, so it couldn't call an isolated
    // init. The init itself touches no actor-isolated state, so opting it
    // out here is safe.
    private let trashWorkspaceDirectory: @Sendable (URL) throws -> Void

    nonisolated init(
        trashWorkspaceDirectory: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) {
        self.trashWorkspaceDirectory = trashWorkspaceDirectory
    }

    // MARK: - Envelope decoding

    private struct Envelope: Decodable {
        let ok: Bool
        let workspace: WorkspacePayload?
        let landed: LandedPayload?
        let error: ErrorPayload?
        // Present only on workspace-land success envelopes when landing
        // succeeded but final workspace cleanup could not complete.
        // landWorkspace surfaces it as a non-fatal notice.
        let warning: String?
        // Present only on workspace-land-preview's success envelope.
        let preview: LandPreviewPayload?
        // Present only on rebase-onto-trunk's success envelope.
        let rebased: RebasedPayload?
    }

    private struct WorkspacePayload: Decodable {
        let name: String
        let path: String
        let project: String
    }

    private struct LandedPayload: Decodable {
        let commit_id: String
        let bookmark: String
        let workspace: String
        // Required on every success: silently defaulting a missing field to
        // false could destroy a workspace retained by the engine.
        let workspace_retained: Bool
    }

    /// Change entries use `id`/`subject`. Git conflict entries instead use
    /// `file`; keeping all fields optional lets one stable envelope represent
    /// both without leaking the VCS distinction into presentation.
    private struct LandCommitPayload: Decodable {
        let id: String?
        let subject: String?
        let file: String?
    }

    private struct LandPreviewPayload: Decodable {
        let bookmark: String
        let bookmark_commit: String
        let commits: [LandCommitPayload]
        let conflicts: [LandCommitPayload]
        let needs_message: Bool
        let diverging: [LandCommitPayload]
        let target_snapshot: String
    }

    private struct RebasedPayload: Decodable {
        let count: Int
        let bookmark: String
    }

    private struct ErrorPayload: Decodable {
        let code: String
        let message: String
    }

    private static func engineError(for payload: ErrorPayload) -> EngineError {
        switch payload.code {
        case "not-a-repo": return .notARepo(payload.message)
        case "name-conflict": return .nameConflict(payload.message)
        case "dest-exists": return .destExists(payload.message)
        case "no-trunk": return .noTrunk(payload.message)
        case "land-conflict": return .landConflict(payload.message)
        case "nothing-to-land": return .nothingToLand(payload.message)
        case "shared-history": return .sharedHistory(payload.message)
        case "workspace-changed": return .workspaceChanged(payload.message)
        case "rebase-conflict": return .rebaseConflict(payload.message)
        default: return .failed(payload.message)
        }
    }

    // MARK: - Resolution

    /// Locates the bundled (or dev-override) `agents-cli` wrapper for
    /// external `wsm.cli`.
    private static func resolveScriptURL() throws -> URL {
        if let bundled = Bundle.main.url(forResource: "agents-cli", withExtension: nil) {
            return bundled
        }
        if let devPath = ProcessInfo.processInfo.environment["AGENTS_CLI"], !devPath.isEmpty {
            return URL(fileURLWithPath: devPath)
        }
        throw EngineError.failed(
            "agents-cli script not found — not bundled as a resource, and AGENTS_CLI env var not set"
        )
    }

    // Kept in sync with ToolPreflight.swift's bb-resolution logic — see that file for why.
    /// Locates the `bb` (babashka) binary.
    private static func resolveBBPath() throws -> String {
        let fm = FileManager.default
        if let envPath = ProcessInfo.processInfo.environment["AGENTS_BB"], !envPath.isEmpty,
           fm.isExecutableFile(atPath: envPath)
        {
            return envPath
        }
        for candidate in ["/opt/homebrew/bin/bb", "/usr/local/bin/bb"] {
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw EngineError.failed("babashka not found — set AGENTS_BB or install bb")
    }

    // MARK: - Process execution

    /// Plain, non-actor-isolated helper that does the actual subprocess
    /// work. Kept outside the @MainActor type so `Process`'s
    /// `terminationHandler` (which fires on Process's own callback queue,
    /// not MainActor) can freely read its captured pipes and resume a
    /// continuation without any actor-isolation ceremony.
    ///
    /// Both pipes are drained CONCURRENTLY on background queues starting at
    /// launch, not after termination: a child that writes more than the
    /// pipe buffer (~64KB) before exiting would otherwise block forever in
    /// write() because nobody is reading yet, while we sit waiting for an
    /// exit that can't happen — a classic pipe deadlock. Three independent
    /// completions (stdout drained, stderr drained, process terminated) are
    /// fanned into one `DispatchGroup`, whose `notify` resumes the
    /// continuation exactly once after all three have finished. `didResume`
    /// + `resumeLock` exist only to make the launch-failure path safe: if
    /// `process.run()` throws, `group.notify`'s eventual fan-in and the
    /// catch block's own resume could otherwise race to resume twice.
    ///
    /// On the launch-failure path we also explicitly close both pipes'
    /// write ends: if `process.run()` throws, the child never spawned, so
    /// the write ends are still open only in this process. Left open, the
    /// background reads above would block forever waiting for an EOF that
    /// will never come — closing them unblocks `readDataToEndOfFile()`
    /// immediately so `group.leave()` for those two reads still fires.
    ///
    /// `ResultBox` exists only because Swift 5's concurrency checker cannot
    /// see the happens-before relationship `DispatchGroup` actually
    /// provides (enter/leave/notify orders every write to these fields
    /// strictly before the one read of them in `notify`'s closure); each
    /// field is still written by exactly one single-owner closure, so no
    /// locking is added beyond what the group already guarantees.
    private final class ResultBox: @unchecked Sendable {
        var stdoutData = Data()
        var stderrData = Data()
        var terminationStatus: Int32 = 0
    }

    // internal for @testable regression coverage
    static func runProcess(bb: String, scriptPath: String, args: [String]) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: bb)
            process.arguments = [scriptPath] + args

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let group = DispatchGroup()
            let resumeLock = NSLock()
            var didResume = false
            func resumeOnce(_ body: () -> Void) {
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !didResume else { return }
                didResume = true
                body()
            }

            let box = ResultBox()

            group.enter()
            DispatchQueue.global().async {
                box.stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            group.enter()
            DispatchQueue.global().async {
                box.stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            group.enter()
            process.terminationHandler = { finishedProcess in
                box.terminationStatus = finishedProcess.terminationStatus
                group.leave()
            }

            group.notify(queue: .global()) {
                resumeOnce {
                    let stdout = String(data: box.stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: box.stderrData, encoding: .utf8) ?? ""
                    continuation.resume(returning: (stdout, stderr, box.terminationStatus))
                }
            }

            do {
                try process.run()
            } catch {
                // The child never spawned — unblock the two background
                // reads (they're waiting on an EOF only a spawned child's
                // exit would produce) and let the terminationHandler's
                // group.leave() go uncalled by leaving it here instead,
                // since terminationHandler will never fire for a process
                // that never ran.
                //
                // The throwing resume must come BEFORE the balancing
                // group.leave(): once that leave zeroes the group, notify
                // can fire on another queue and win the resumeOnce race,
                // resuming with a bogus empty ("", "", 0) success instead
                // of the launch error.
                stdoutPipe.fileHandleForWriting.closeFile()
                stderrPipe.fileHandleForWriting.closeFile()
                resumeOnce {
                    continuation.resume(throwing: EngineError.failed("failed to launch bb: \(error)"))
                }
                group.leave()
            }
        }
    }

    /// Runs a subcommand and decodes its JSON envelope, throwing the mapped
    /// `EngineError` on `ok:false` or on any process/parse failure.
    ///
    /// Returns the raw `Envelope` on `ok:true` rather than unwrapping a
    /// `workspace` payload — the CLI contract only guarantees a `workspace`
    /// key for subcommands that produce one (e.g. `workspace-add`);
    /// `workspace-forget`'s success envelope is a bare `{"ok":true}`. So
    /// "success" here means `ok:true` alone; whether a workspace payload
    /// should also be present is a per-subcommand concern each caller must
    /// decide for itself.
    private func run(_ subcommand: String, args: [String]) async throws -> Envelope {
        let scriptURL = try Self.resolveScriptURL()
        let bb = try Self.resolveBBPath()

        let result = try await Self.runProcess(bb: bb, scriptPath: scriptURL.path, args: [subcommand] + args)

        guard let data = result.stdout.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else {
            let diagnostics = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EngineError.failed(
                "agents-cli produced unparseable output (exit \(result.exitCode)): "
                    + (diagnostics.isEmpty ? result.stdout : diagnostics)
            )
        }

        if envelope.ok {
            return envelope
        }
        if let errorPayload = envelope.error {
            throw Self.engineError(for: errorPayload)
        }
        // Defensive: shouldn't happen per the CLI contract (ok:false always
        // carries an error payload), but don't silently swallow it.
        throw EngineError.failed("agents-cli returned an envelope with ok:false and no error payload")
    }

    // MARK: - WorkspaceEngineProviding

    func createWorkspace(projectPath: String) async throws -> WorkspaceRow {
        let envelope = try await run("workspace-add", args: ["--project", projectPath])
        // workspace-add always includes a workspace payload on success; a
        // missing one here would mean the CLI contract was violated.
        guard let payload = envelope.workspace else {
            throw EngineError.failed("agents-cli workspace-add returned ok with no workspace payload")
        }
        return WorkspaceRow(projectPath: payload.project, name: payload.name, path: payload.path, label: nil)
    }

    func deleteWorkspace(
        _ workspace: WorkspaceRow,
        onlyIfUnchanged: Bool
    ) async throws -> DeleteResult {
        var args = ["--project", workspace.projectPath, "--name", workspace.name]
        if onlyIfUnchanged {
            args += ["--if-unchanged", "--create-trunk", "main"]
        }
        _ = try await run("workspace-forget", args: args)
        let fm = FileManager.default
        guard fm.fileExists(atPath: workspace.path) else { return DeleteResult() }

        // The forget above is the irreversible boundary: another attempt is
        // not a safe cleanup retry because the workspace registration is
        // already gone. Report a leftover directory as non-fatal follow-up,
        // exactly as landWorkspace does after its successful CLI boundary.
        do {
            try trashWorkspaceDirectory(URL(fileURLWithPath: workspace.path))
            return DeleteResult()
        } catch {
            return DeleteResult(
                cleanupWarning: "The workspace was closed, but its folder couldn't be moved to the Bin — it's still at \(workspace.path)"
            )
        }
    }

    func landWorkspace(
        _ workspace: WorkspaceRow,
        message: String?,
        createTrunk: String?,
        expectedSnapshot: String
    ) async throws -> LandResult {
        var args = [
            "--project", workspace.projectPath,
            "--name", workspace.name,
            "--finalize-quiesced",
        ]
        guard !expectedSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineError.failed("Expected workspace snapshot cannot be blank")
        }
        args += ["--expected-snapshot", expectedSnapshot]
        // `--message` is OMITTED entirely for a nil (or blank) message —
        // never sent as `--message ""`. agents-cli's own flag validation
        // treats a blank flag VALUE as though the flag were never passed at
        // all (`bad-args: Missing required --message`), so `--message ""`
        // fails the call outright rather than landing with no message. That
        // rejection is correct for a flag that's actually required, but
        // `--message` isn't one here: the CLI only ever reads it back for
        // the one case where the workspace's own working-copy commit is
        // non-empty and undescribed — `LandPreview.needsMessage` is the
        // app's advance signal for exactly that case, and it's false for
        // the ordinary "session already committed its work" land. Omitting
        // the flag (rather than sending it empty) is what lets that
        // ordinary case succeed instead of tripping the CLI's required-flag
        // check.
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--message", message]
        }
        if let createTrunk {
            args += ["--create-trunk", createTrunk]
        }
        let envelope = try await run("workspace-land", args: args)
        // workspace-land always includes a landed payload on success; a
        // missing one here would mean the CLI contract was violated (same
        // reasoning as createWorkspace's workspace-payload check above).
        guard let payload = envelope.landed else {
            throw EngineError.failed("agents-cli workspace-land returned ok with no landed payload")
        }

        // By this point project progress has been published. The required
        // workspace_retained field distinguishes a live registered workspace
        // from ordinary cleanup warnings; never infer lifecycle from text.
        var cleanupWarnings = envelope.warning.map { [$0] } ?? []
        if payload.workspace_retained {
            if cleanupWarnings.isEmpty {
                cleanupWarnings.append(
                    "Changes were added, but the workspace remains open at \(workspace.path)."
                )
            }
        } else if FileManager.default.fileExists(atPath: workspace.path) {
            do {
                try trashWorkspaceDirectory(URL(fileURLWithPath: workspace.path))
            } catch {
                cleanupWarnings.append(
                    "Changes were kept, but the workspace folder couldn't be moved to the Bin — it's still at \(workspace.path)"
                )
            }
        }

        return LandResult(
            commitID: payload.commit_id,
            bookmark: payload.bookmark,
            cleanupWarning: cleanupWarnings.isEmpty
                ? nil
                : cleanupWarnings.joined(separator: "\n"),
            workspaceRetained: payload.workspace_retained
        )
    }

    func previewLand(_ workspace: WorkspaceRow, createTrunk: String?) async throws -> LandPreview {
        var args = ["--project", workspace.projectPath, "--name", workspace.name]
        if let createTrunk {
            args += ["--create-trunk", createTrunk]
        }
        let envelope = try await run("workspace-land-preview", args: args)
        // workspace-land-preview always includes a preview payload on
        // success; a missing one here would mean the CLI contract was
        // violated (same reasoning as createWorkspace's workspace-payload
        // check above).
        guard let payload = envelope.preview else {
            throw EngineError.failed("agents-cli workspace-land-preview returned ok with no preview payload")
        }
        func commits(_ payloads: [LandCommitPayload]) -> [LandCommit] {
            payloads.map { payload in
                LandCommit(
                    id: payload.id ?? payload.file ?? "",
                    subject: payload.file ?? payload.subject ?? "Conflicting change"
                )
            }
        }
        let targetSnapshot = payload.target_snapshot
        guard !targetSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineError.failed("agents-cli workspace-land-preview returned a blank target_snapshot")
        }
        return LandPreview(
            bookmark: payload.bookmark,
            bookmarkCommit: payload.bookmark_commit,
            commits: commits(payload.commits),
            conflicts: commits(payload.conflicts),
            needsMessage: payload.needs_message,
            diverging: commits(payload.diverging),
            targetSnapshot: targetSnapshot
        )
    }

    func rebaseOntoTrunk(projectPath: String) async throws -> Int {
        let envelope = try await run("rebase-onto-trunk", args: ["--project", projectPath])
        // rebase-onto-trunk always includes a rebased payload on success;
        // a missing one here would mean the CLI contract was violated (same
        // reasoning as createWorkspace's workspace-payload check above).
        guard let payload = envelope.rebased else {
            throw EngineError.failed("agents-cli rebase-onto-trunk returned ok with no rebased payload")
        }
        return payload.count
    }
}
