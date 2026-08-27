import Foundation

/// Launch-time check for babashka, which runs the bundled workspace engine.
/// Which version-control executable a project needs is resolved contextually
/// by that engine, so launch must not claim either jj or git is universally
/// required.
enum ToolPreflight {
    /// Returns `["bb"]` when babashka cannot be resolved, otherwise `[]`.
    /// Parameters are injected to keep the check hermetic in unit tests.
    static func missingTools(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [String] {
        bbFound(environment: environment, isExecutable: isExecutable) ? [] : ["bb"]
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

    static func guidance(for missing: [String]) -> String {
        guard missing.contains("bb") else { return "" }
        return """
        bb not found — some workspace features won't work until installed.

        bb: brew install borkdude/brew/babashka (or point AGENTS_BB at an existing install)
        """
    }
}
