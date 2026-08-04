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

    private(set) var createCalls: [String] = []       // projectPath args
    private(set) var deleteCalls: [WorkspaceRow] = []

    func createWorkspace(projectPath: String) async throws -> WorkspaceRow {
        createCalls.append(projectPath)
        return try nextCreateResult.get()
    }

    func deleteWorkspace(_ workspace: WorkspaceRow) async throws {
        deleteCalls.append(workspace)
        _ = try nextDeleteResult.get()
    }
}
