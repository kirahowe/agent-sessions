import Foundation
@testable import Agents

/// Test double for `WorkspaceEngineProviding`. Scriptable per-call result
/// (defaults to success) and records every call so tests can assert both
/// what was called and what the store did with the result — without any
/// real subprocess/jj/filesystem-trash machinery.
@MainActor
final class FakeWorkspaceEngine: WorkspaceEngineProviding {
    var nextCreateResult: Result<WorkspaceRow, EngineError> = .success(
        WorkspaceRow(projectPath: "", name: "unset", path: "", label: nil)
    )
    var nextDeleteResult: Result<Void, EngineError> = .success(())
    var nextLandResult: Result<LandResult, EngineError> = .success(
        LandResult(commitID: "unset", bookmark: "main")
    )
    /// Defaults to a no-conflicts, no-message-needed, non-diverging
    /// preview — the "boring" case most tests that don't care about
    /// `previewLand`'s content should get for free.
    var nextPreviewResult: Result<LandPreview, EngineError> = .success(
        LandPreview(bookmark: "main", bookmarkCommit: "unset", commits: [], conflicts: [], needsMessage: false, diverging: [])
    )
    var nextRebaseResult: Result<Int, EngineError> = .success(0)

    private(set) var createCalls: [String] = []       // projectPath args
    private(set) var deleteCalls: [WorkspaceRow] = []
    // `message` is optional for the same reason the protocol's is: nil means
    // "no message at all", which the real engine turns into an OMITTED
    // --message flag rather than a blank one. Recording it as a plain String
    // would let a test assert `== ""` and pass while the real CLI rejects
    // that exact call as a missing required flag.
    private(set) var landCalls: [(workspace: WorkspaceRow, message: String?, createTrunk: String?)] = []
    private(set) var previewLandCalls: [WorkspaceRow] = []
    private(set) var rebaseOntoTrunkCalls: [String] = []   // projectPath args

    func createWorkspace(projectPath: String) async throws -> WorkspaceRow {
        createCalls.append(projectPath)
        return try nextCreateResult.get()
    }

    func deleteWorkspace(_ workspace: WorkspaceRow) async throws {
        deleteCalls.append(workspace)
        _ = try nextDeleteResult.get()
    }

    func landWorkspace(_ workspace: WorkspaceRow, message: String?, createTrunk: String?) async throws -> LandResult {
        landCalls.append((workspace: workspace, message: message, createTrunk: createTrunk))
        return try nextLandResult.get()
    }

    func previewLand(_ workspace: WorkspaceRow) async throws -> LandPreview {
        previewLandCalls.append(workspace)
        return try nextPreviewResult.get()
    }

    func rebaseOntoTrunk(projectPath: String) async throws -> Int {
        rebaseOntoTrunkCalls.append(projectPath)
        return try nextRebaseResult.get()
    }
}
