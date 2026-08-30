import Foundation
@testable import Agents

/// Test double for WorkspaceEngineProviding. Scriptable per-call result
/// (defaults to success) and records every call so tests can assert both
/// what was called and what the store did with the result — without any
/// real subprocess/jj/filesystem-trash machinery.
@MainActor
final class FakeWorkspaceEngine: WorkspaceEngineProviding {
    var nextCreateResult: Result<WorkspaceRow, EngineError> = .success(
        WorkspaceRow(projectPath: "", name: "unset", path: "", label: nil)
    )
    var nextDeleteResult: Result<DeleteResult, EngineError> = .success(DeleteResult())
    var nextLandResult: Result<LandResult, EngineError> = .success(
        LandResult(commitID: "unset", bookmark: "main")
    )
    /// Defaults to a no-conflicts, no-message-needed preview — the "boring"
    /// case most tests that don't care about previewLand's content should get
    /// for free.
    var nextPreviewResult: Result<LandPreview, EngineError> = .success(
        LandPreview(
            bookmark: "main",
            bookmarkCommit: "unset",
            commits: [],
            conflicts: [],
            needsMessage: false
        )
    )
    /// Results consumed in order before falling back to nextPreviewResult.
    var previewResults: [Result<LandPreview, EngineError>] = []
    var nextRebaseResult: Result<Int, EngineError> = .success(0)

    private(set) var createCalls: [String] = []
    private(set) var deleteCalls: [WorkspaceRow] = []
    private(set) var deleteOnlyIfUnchangedCalls: [Bool] = []
    // message is optional for the same reason the protocol's is: nil means
    // "no message at all", which the real engine turns into an omitted
    // --message flag rather than a blank one.
    private(set) var landCalls: [(
        workspace: WorkspaceRow,
        message: String?,
        createTrunk: String?
    )] = []
    private(set) var previewLandCalls: [(workspace: WorkspaceRow, createTrunk: String?)] = []
    private(set) var rebaseOntoTrunkCalls: [String] = []
    var onRebaseOntoTrunk: (() -> Void)?
    var createWorkspaceHandler: ((String) async throws -> WorkspaceRow)?
    var previewLandHandler: ((WorkspaceRow, String?) async throws -> LandPreview)?
    var rebaseOntoTrunkHandler: ((String) async throws -> Int)?
    var landWorkspaceHandler: ((WorkspaceRow, String?, String?) async throws -> LandResult)?
    var deleteWorkspaceHandler: ((WorkspaceRow, Bool) async throws -> DeleteResult)?
    var onLandWorkspace: (() -> Void)?
    var onDeleteWorkspace: (() -> Void)?
    var onPreviewLand: ((Int) -> Void)?

    func createWorkspace(projectPath: String) async throws -> WorkspaceRow {
        createCalls.append(projectPath)
        if let createWorkspaceHandler {
            return try await createWorkspaceHandler(projectPath)
        }
        return try nextCreateResult.get()
    }

    func deleteWorkspace(
        _ workspace: WorkspaceRow,
        onlyIfUnchanged: Bool
    ) async throws -> DeleteResult {
        deleteCalls.append(workspace)
        deleteOnlyIfUnchangedCalls.append(onlyIfUnchanged)
        onDeleteWorkspace?()
        if let deleteWorkspaceHandler {
            return try await deleteWorkspaceHandler(workspace, onlyIfUnchanged)
        }
        return try nextDeleteResult.get()
    }

    func landWorkspace(
        _ workspace: WorkspaceRow,
        message: String?,
        createTrunk: String?
    ) async throws -> LandResult {
        landCalls.append((
            workspace: workspace,
            message: message,
            createTrunk: createTrunk
        ))
        if let landWorkspaceHandler {
            return try await landWorkspaceHandler(workspace, message, createTrunk)
        }
        onLandWorkspace?()
        return try nextLandResult.get()
    }

    func previewLand(
        _ workspace: WorkspaceRow,
        createTrunk: String?
    ) async throws -> LandPreview {
        previewLandCalls.append((workspace: workspace, createTrunk: createTrunk))
        onPreviewLand?(previewLandCalls.count)
        if let previewLandHandler {
            return try await previewLandHandler(workspace, createTrunk)
        }
        let result = previewResults.isEmpty ? nextPreviewResult : previewResults.removeFirst()
        return try result.get()
    }

    func rebaseOntoTrunk(projectPath: String) async throws -> Int {
        onRebaseOntoTrunk?()
        rebaseOntoTrunkCalls.append(projectPath)
        if let rebaseOntoTrunkHandler {
            return try await rebaseOntoTrunkHandler(projectPath)
        }
        return try nextRebaseResult.get()
    }
}
