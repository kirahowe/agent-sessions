import CryptoKit
import Foundation

/// Where a project's workspaces live on disk: `~/.agents/workspaces/<key>`,
/// outside every repository and keyed by project.
///
/// Outside the repository, because a directory nested inside the project is
/// hostile to everything else that touches the tree: `git clean -fdx` at the
/// project root deletes every nested workspace (a jj workspace carries only a
/// `.jj` directory, so git's nested-repository guard does not apply), every
/// indexer, backup, and sync client has to be told to skip it, and the project
/// can never have a `workspaces/` directory of its own.
///
/// Keyed by project, because the CLI mints a workspace's name against ONE
/// project's registry: two projects can both produce `quiet-otter`, and under a
/// flat root that is a destination collision. The key is the project's
/// basename, so `ls ~/.agents/workspaces` reads like the sidebar, plus a short
/// hash of the project's canonical path so two checkouts with the same name
/// never share a directory.
enum WorkspacesRoot {
    static let defaultHome = FileManager.default.homeDirectoryForCurrentUser

    /// The directory the CLI is given as `--workspaces-root` for `projectPath`.
    static func directory(forProject projectPath: String, home: URL = defaultHome) -> String {
        home.appendingPathComponent(".agents")
            .appendingPathComponent("workspaces")
            .appendingPathComponent(projectKey(forProject: projectPath))
            .path
    }

    /// `<basename>-<8 hex chars>`, stable across trailing slashes, `..`
    /// segments, and symlinks: the hash is over the resolved path, so the
    /// same checkout always maps to the same directory however it was named.
    static func projectKey(forProject projectPath: String) -> String {
        let canonical = URL(fileURLWithPath: projectPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let short = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        let name = (canonical as NSString).lastPathComponent
        return "\(name)-\(short)"
    }
}
