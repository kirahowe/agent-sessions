import Foundation

enum EngineError: Error, Equatable {
    case notAJJRepo(String)
    case nameConflict(String)
    case destExists(String)
    case failed(String)
    case noTrunk(String)
    case landConflict(String)
    case nothingToLand(String)

    var message: String {
        switch self {
        case .notAJJRepo(let m), .nameConflict(let m), .destExists(let m), .failed(let m),
             .noTrunk(let m), .landConflict(let m), .nothingToLand(let m):
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
}

@MainActor
protocol WorkspaceEngineProviding: AnyObject {
    func createWorkspace(projectPath: String) async throws -> WorkspaceRow
    func deleteWorkspace(_ workspace: WorkspaceRow) async throws
    func landWorkspace(_ workspace: WorkspaceRow, message: String, createTrunk: String?) async throws -> LandResult
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
    private static func runProcess(bb: String, scriptPath: String, args: [String]) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: bb)
            process.arguments = [scriptPath] + args

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { finishedProcess in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                continuation.resume(returning: (stdout, stderr, finishedProcess.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: EngineError.failed("failed to launch bb: \(error)"))
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
        try fm.trashItem(at: URL(fileURLWithPath: workspace.path), resultingItemURL: nil)
    }

    func landWorkspace(_ workspace: WorkspaceRow, message: String, createTrunk: String?) async throws -> LandResult {
        var args = ["--project", workspace.projectPath, "--name", workspace.name, "--message", message]
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

        let fm = FileManager.default
        if fm.fileExists(atPath: workspace.path) {
            try fm.trashItem(at: URL(fileURLWithPath: workspace.path), resultingItemURL: nil)
        }

        return LandResult(commitID: payload.commit_id, bookmark: payload.bookmark)
    }
}
