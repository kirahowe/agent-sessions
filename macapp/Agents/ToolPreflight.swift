import Foundation

/// Launch-time check for the temporary workspace wrapper's prerequisites.
/// Version-control executables remain project-specific and are resolved by the
/// manager, so launch must not claim either jj or git is universally required.
enum ToolPreflight {
    enum MissingPrerequisite: Equatable {
        case bb
        case workstreamManager
    }

    struct Result: Equatable {
        let managerRoot: String
        let missing: [MissingPrerequisite]
    }

    /// Resolves and checks launch prerequisites. Inputs are injected to keep
    /// the result pure and hermetic in unit tests.
    static func check(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        isRegularFile: (String) -> Bool = {
            (try? URL(fileURLWithPath: $0)
                .resourceValues(forKeys: [.isRegularFileKey])
                .isRegularFile) == true
        }
    ) -> Result {
        let managerRoot = resolveManagerRoot(environment: environment, homeDirectory: homeDirectory)
        let managerEntryPoint = (managerRoot as NSString).appendingPathComponent("src/wsm/cli.clj")
        var missing: [MissingPrerequisite] = []
        if !bbFound(environment: environment, isExecutable: isExecutable) {
            missing.append(.bb)
        }
        if !isRegularFile(managerEntryPoint) {
            missing.append(.workstreamManager)
        }
        return Result(managerRoot: managerRoot, missing: missing)
    }

    // Mirrors WorkspaceEngineCLI.resolveBBPath(): AGENTS_BB first, then the
    // two common Homebrew locations.
    private static func bbFound(
        environment: [String: String],
        isExecutable: (String) -> Bool
    ) -> Bool {
        if let envPath = environment["AGENTS_BB"], !envPath.isEmpty, isExecutable(envPath) {
            return true
        }
        return ["/opt/homebrew/bin/bb", "/usr/local/bin/bb"].contains(where: isExecutable)
    }

    private static func resolveManagerRoot(
        environment: [String: String],
        homeDirectory: String
    ) -> String {
        let override = environment["WORKSTREAM_MANAGER_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty {
            return override
        }
        return (homeDirectory as NSString).appendingPathComponent("code/projects/workstream-manager")
    }

    static func guidance(for result: Result) -> String? {
        var sections: [String] = []
        if result.missing.contains(.bb) {
            sections.append("""
            bb not found — workspace features won't work until it is installed.

            Install it with: brew install borkdude/brew/babashka
            Or point AGENTS_BB at an existing install.
            """)
        }
        if result.missing.contains(.workstreamManager) {
            let entryPoint = (result.managerRoot as NSString).appendingPathComponent("src/wsm/cli.clj")
            sections.append("""
            workstream-manager entry point not found: \(entryPoint)

            Clone https://github.com/kirahowe/workstream-manager into:
            \(result.managerRoot)

            The default checkout is $HOME/code/projects/workstream-manager.
            Set WORKSTREAM_MANAGER_ROOT to use a different checkout.
            """)
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }
}
