import Foundation

enum EngineError: Error, Equatable {
    case notAJJRepo(String)
    case nameConflict(String)
    case destExists(String)
    case failed(String)
    case noTrunk(String)
    case landConflict(String)
    case nothingToLand(String)
    case sharedHistory(String)
    // Thrown by rebase-onto-trunk when rebasing the default workspace's
    // diverging commits onto the (just-moved) trunk bookmark hits a
    // conflict. Distinct from .landConflict: that one is reported by (and
    // guards) workspace-land itself, before trunk ever moves; this one can
    // only happen AFTER a successful land, as a side effect of the optional
    // rebase-offer the user opted into — see AppStore.reviewAndLandWorkspace.
    case rebaseConflict(String)

    var message: String {
        switch self {
        case .notAJJRepo(let m), .nameConflict(let m), .destExists(let m), .failed(let m),
             .noTrunk(let m), .landConflict(let m), .nothingToLand(let m), .sharedHistory(let m),
             .rebaseConflict(let m):
            return m
        }
    }
}

/// The result of successfully landing a workspace's changes onto its
/// project's trunk bookmark: the squashed commit id, and the bookmark it
/// now lives on.
struct LandResult: Equatable {
    let commitID: String
    let bookmark: String
    /// Non-nil when the land itself succeeded (jj already forgot the
    /// workspace and advanced the bookmark) but the leftover workspace
    /// directory couldn't be moved to the Bin. User-readable, meant to be
    /// surfaced as a non-fatal notice rather than treated as a failed land.
    /// Defaulted so every existing `LandResult(commitID:bookmark:)` call
    /// site (including in tests) keeps compiling unchanged.
    var cleanupWarning: String? = nil
}

/// One commit as shown in the land-review confirmation — just enough to
/// render a human-readable line (`LandPreview.commits`/`.conflicts`/
/// `.diverging` are all this shape). `id` is a short commit id, already
/// truncated by the CLI; it's carried through for potential future use
/// (e.g. a "show diff" affordance) but today only `subject` is rendered.
struct LandCommit: Equatable {
    let id: String
    let subject: String
}

/// A dry-run report of exactly what `landWorkspace` would do, fetched by
/// `previewLand` and shown to the user before they commit to landing. This
/// is what replaces the old free-text `promptLandMessage` prompt: that
/// prompt asked the user to type a description on every land, but the CLI
/// only ever reads it back (via `--message`) when `needsMessage` here is
/// true — a rare case — so the prompt was almost always silently discarded
/// work. Showing the user what will ACTUALLY happen is strictly more
/// useful than asking them to (usually pointlessly) describe it themselves.
struct LandPreview: Equatable {
    /// The trunk bookmark's name (e.g. "main").
    let bookmark: String
    /// Trunk's current short commit id, BEFORE landing — lets the
    /// confirmation dialog show exactly what's about to move, not just its
    /// name.
    let bookmarkCommit: String
    /// What will land on `bookmark`, oldest first.
    let commits: [LandCommit]
    /// Non-empty means landing would conflict. Still delivered inside an
    /// otherwise-successful (`ok:true`) preview envelope, because a
    /// preview's whole job is to REPORT, not to enforce — `workspace-land`
    /// itself independently refuses a conflicting land with its own
    /// `land-conflict` error. This field exists so the confirmation dialog
    /// can warn the user before they even try, not to replace that
    /// enforcement.
    let conflicts: [LandCommit]
    /// True iff the workspace's working-copy commit is non-empty AND
    /// undescribed — the one situation where `workspace-land`'s
    /// `--message` actually reaches the landed commit. Drives whether
    /// `Dialogs.confirmLand` shows a free-text field at all: false means
    /// there is nothing for a message to describe, so no field is shown.
    let needsMessage: Bool
    /// The user's OWN default-workspace commits that are not part of this
    /// land at all and will be left on a fork once `bookmark` moves out
    /// from under them. Empty means landing won't fork the default
    /// workspace. Non-empty drives the post-land rebase offer — see
    /// `AppStore.reviewAndLandWorkspace`.
    let diverging: [LandCommit]
}

@MainActor
protocol WorkspaceEngineProviding: AnyObject {
    func createWorkspace(projectPath: String) async throws -> WorkspaceRow
    func deleteWorkspace(_ workspace: WorkspaceRow) async throws
    func landWorkspace(_ workspace: WorkspaceRow, message: String?, createTrunk: String?) async throws -> LandResult
    func previewLand(_ workspace: WorkspaceRow) async throws -> LandPreview
    /// Rebases the default workspace's diverging commits (see
    /// `LandPreview.diverging`) onto the project's trunk bookmark. Returns
    /// how many commits were rebased. Only ever called after the user
    /// explicitly opts in via `Dialogs.confirmRebaseOntoTrunk`, immediately
    /// following a successful land — never automatically.
    func rebaseOntoTrunk(projectPath: String) async throws -> Int
}

/// Production conformer: drives the `agents-cli` babashka script as a
/// subprocess to create/forget jj workspaces. Every invocation prints a
/// single JSON envelope to stdout (see agents-cli's own header comment for
/// the exact contract); this type's job is just resolving the script/bb
/// binary, running the process, and decoding that envelope.
final class WorkspaceEngineCLI: WorkspaceEngineProviding {
    // Explicitly nonisolated: conforming to the @MainActor protocol infers
    // whole-type MainActor isolation, which would otherwise make this
    // initializer MainActor-isolated too — and AppStore.init's default
    // argument (`engine: ... = WorkspaceEngineCLI()`) is evaluated in a
    // synchronous, nonisolated context, so it couldn't call an isolated
    // init. The init itself touches no actor-isolated state, so opting it
    // out here is safe.
    nonisolated init() {}

    // MARK: - Envelope decoding

    private struct Envelope: Decodable {
        let ok: Bool
        let workspace: WorkspacePayload?
        let landed: LandedPayload?
        let error: ErrorPayload?
        // Present only on workspace-land's success envelope, and only when
        // the land itself irreversibly succeeded (squash done, bookmark
        // advanced) but the final `jj workspace forget` afterward failed —
        // most plausibly because the default workspace's own working copy
        // was stale (see agents-cli's cmd-workspace-land comment block).
        // landWorkspace below treats its presence as a signal to skip the
        // usual directory cleanup, not as a failure.
        let warning: String?
        // Present only on workspace-land-preview's success envelope.
        let preview: LandPreviewPayload?
        // Present only on rebase-onto-trunk's success envelope.
        let rebased: RebasedPayload?
    }

    private struct WorkspacePayload: Decodable {
        let name: String
        let jj_name: String
        let path: String
        let project: String
    }

    private struct LandedPayload: Decodable {
        let commit_id: String
        let bookmark: String
        let workspace: String
    }

    /// One entry of `LandPreviewPayload.commits`/`.conflicts`/`.diverging`
    /// — same shape reused for all three, matching the CLI's own contract.
    private struct LandCommitPayload: Decodable {
        let id: String
        let subject: String
    }

    private struct LandPreviewPayload: Decodable {
        let bookmark: String
        let bookmark_commit: String
        let commits: [LandCommitPayload]
        let conflicts: [LandCommitPayload]
        let needs_message: Bool
        let diverging: [LandCommitPayload]
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
        case "not-a-jj-repo": return .notAJJRepo(payload.message)
        case "name-conflict": return .nameConflict(payload.message)
        case "dest-exists": return .destExists(payload.message)
        case "no-trunk": return .noTrunk(payload.message)
        case "land-conflict": return .landConflict(payload.message)
        case "nothing-to-land": return .nothingToLand(payload.message)
        case "shared-history": return .sharedHistory(payload.message)
        case "rebase-conflict": return .rebaseConflict(payload.message)
        default: return .failed(payload.message)
        }
    }

    // MARK: - Resolution

    /// Locates the bundled (or dev-override) `agents-cli` script.
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

    func deleteWorkspace(_ workspace: WorkspaceRow) async throws {
        // workspace-forget's success envelope is a bare {"ok":true} with no
        // workspace payload — `run` throwing on ok:false is all the
        // confirmation needed here, so the envelope itself is discarded.
        _ = try await run("workspace-forget", args: ["--project", workspace.projectPath, "--name", workspace.name])

        let fm = FileManager.default
        guard fm.fileExists(atPath: workspace.path) else { return }
        // Deliberately left to throw/propagate here, unlike landWorkspace's
        // trashItem below: workspace-forget is idempotent and retryable, so
        // AppStore's catch can safely leave the WorkspaceRow in place as a
        // visible retry marker without stranding anything. landWorkspace's
        // land is NOT retryable — the trunk bookmark already moved — so the
        // same fatal treatment there would leave the app falsely believing
        // the workspace still needs landing.
        try fm.trashItem(at: URL(fileURLWithPath: workspace.path), resultingItemURL: nil)
    }

    func landWorkspace(_ workspace: WorkspaceRow, message: String?, createTrunk: String?) async throws -> LandResult {
        var args = ["--project", workspace.projectPath, "--name", workspace.name]
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

        // By this point the CLI envelope has already reported success: jj
        // has advanced the bookmark server-side, irreversibly. A trash
        // failure here is purely cosmetic (a leftover directory), so it must
        // never turn a successful land into a thrown error — that would
        // desync app state from reality (AppStore would treat the land as
        // failed and keep sessions/rows around for a workspace jj no longer
        // knows about). This is the deliberate ASYMMETRY with
        // deleteWorkspace's trashItem above: forgetting a workspace is
        // idempotent/retryable, so letting that one throw and leave a retry
        // marker is safe; landing is not retryable, so the same treatment
        // here would strand the app in a false "still needs landing" state.
        let fm = FileManager.default
        var cleanupWarning: String? = nil
        if let cliWarning = envelope.warning {
            // The CLI's own :warning means the final `jj workspace forget`
            // failed, so jj STILL HAS this workspace registered pointing at
            // workspace.path. Trashing the directory here would leave jj's
            // registry referencing a path that no longer exists — a state
            // strictly worse than a merely-undeleted folder, and one the
            // user's own follow-up `jj workspace forget` (named in the
            // message) would then be unable to clean up properly either.
            // So the trash step is skipped entirely, not just its errors
            // swallowed, and the CLI's own message — which already names the
            // real workspace/project — is passed straight through.
            cleanupWarning = cliWarning
        } else if fm.fileExists(atPath: workspace.path) {
            do {
                try fm.trashItem(at: URL(fileURLWithPath: workspace.path), resultingItemURL: nil)
            } catch {
                cleanupWarning = "Changes were kept, but the workspace folder couldn't be moved to the Bin — it's still at \(workspace.path)"
            }
        }

        return LandResult(commitID: payload.commit_id, bookmark: payload.bookmark, cleanupWarning: cleanupWarning)
    }

    func previewLand(_ workspace: WorkspaceRow) async throws -> LandPreview {
        let envelope = try await run("workspace-land-preview", args: ["--project", workspace.projectPath, "--name", workspace.name])
        // workspace-land-preview always includes a preview payload on
        // success; a missing one here would mean the CLI contract was
        // violated (same reasoning as createWorkspace's workspace-payload
        // check above).
        guard let payload = envelope.preview else {
            throw EngineError.failed("agents-cli workspace-land-preview returned ok with no preview payload")
        }
        func commits(_ payloads: [LandCommitPayload]) -> [LandCommit] {
            payloads.map { LandCommit(id: $0.id, subject: $0.subject) }
        }
        return LandPreview(
            bookmark: payload.bookmark,
            bookmarkCommit: payload.bookmark_commit,
            commits: commits(payload.commits),
            conflicts: commits(payload.conflicts),
            needsMessage: payload.needs_message,
            diverging: commits(payload.diverging)
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
