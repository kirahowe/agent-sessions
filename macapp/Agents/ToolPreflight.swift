import Foundation

/// Launch-time check for the external tools workspace operations shell out
/// to (`bb`/babashka, which in turn runs `agents-cli`, which shells out to
/// `jj`). Terminals work with neither installed — only workspace operations
/// need them — so this is purely informational: it exists to give the user
/// a one-time, readable signal at launch ("go install these") instead of
/// letting them discover the gap later as a low-level subprocess failure
/// from deep inside a workspace create/land/delete call.
///
/// The resolution logic here MUST mirror, condition-for-condition and in
/// the same order, the two real resolvers it stands in for:
///   - bb: `WorkspaceEngineCLI.resolveBBPath()` in WorkspaceEngine.swift
///   - jj: `resolve-jj` in cli/agents-cli
/// If this drifted from either one, the preflight could tell a user a tool
/// is missing when the real code would happily find it (or vice versa) —
/// worse than not checking at all. Whenever either original changes, update
/// this file to match, and vice versa.
enum ToolPreflight {
    /// Returns the subset of `["bb", "jj"]` (bb first) that cannot be
    /// resolved, `[]` if both are found. Pure function of its two
    /// parameters — no direct `ProcessInfo`/`FileManager` access inside the
    /// resolution logic itself, only as parameter defaults — so it's fully
    /// unit-testable without touching the real environment or filesystem.
    static func missingTools(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [String] {
        var missing: [String] = []
        if !bbFound(environment: environment, isExecutable: isExecutable) {
            missing.append("bb")
        }
        if !jjFound(environment: environment, isExecutable: isExecutable) {
            missing.append("jj")
        }
        return missing
    }

    // Mirrors WorkspaceEngineCLI.resolveBBPath() in WorkspaceEngine.swift
    // exactly: AGENTS_BB override (must be non-empty and executable), else
    // the two Homebrew candidate paths in order. Keep these two in sync.
    private static func bbFound(
        environment: [String: String],
        isExecutable: (String) -> Bool
    ) -> Bool {
        if let envPath = environment["AGENTS_BB"], !envPath.isEmpty, isExecutable(envPath) {
            return true
        }
        for candidate in ["/opt/homebrew/bin/bb", "/usr/local/bin/bb"] {
            if isExecutable(candidate) {
                return true
            }
        }
        return false
    }

    // Mirrors resolve-jj in cli/agents-cli exactly: AGENTS_JJ override (must
    // be non-blank per Clojure's str/blank? — nil, empty, or whitespace-only
    // all count as invalid — and executable), else a PATH scan, else the two
    // Homebrew candidate paths in order. Keep these two in sync.
    //
    // The PATH scan matters because it's the same PATH the bb/agents-cli
    // subprocess would inherit at runtime — checking it here (rather than
    // skipping straight to the Homebrew fallbacks) is what keeps this
    // preflight truthful. An app launched from Finder/Dock gets launchd's
    // minimal PATH (no /opt/homebrew/bin), which is exactly why agents-cli
    // resolves jj to an absolute path itself instead of trusting PATH; we
    // scan whatever PATH the app process actually has at the moment of the
    // check, so this can never claim jj is reachable via PATH when the real
    // subprocess would fail to find it there.
    private static func jjFound(
        environment: [String: String],
        isExecutable: (String) -> Bool
    ) -> Bool {
        if let envPath = environment["AGENTS_JJ"],
           !envPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           isExecutable(envPath)
        {
            return true
        }
        if let path = environment["PATH"] {
            for component in path.split(separator: ":", omittingEmptySubsequences: true) {
                if isExecutable("\(component)/jj") {
                    return true
                }
            }
        }
        for candidate in ["/opt/homebrew/bin/jj", "/usr/local/bin/jj"] {
            if isExecutable(candidate) {
                return true
            }
        }
        return false
    }

    /// Builds the user-facing message for the launch-time alert. `missing`
    /// is expected non-empty (callers only invoke this when `missingTools`
    /// returned something) and in the same bb-then-jj order it returns.
    static func guidance(for missing: [String]) -> String {
        let installCommands: [String: String] = [
            "bb": "brew install borkdude/brew/babashka",
            "jj": "brew install jj",
        ]
        let envVars: [String: String] = [
            "bb": "AGENTS_BB",
            "jj": "AGENTS_JJ",
        ]

        let names = missing.joined(separator: " and ")
        var lines = ["\(names) not found — some workspace features won't work until installed."]
        lines.append("")
        for tool in missing {
            if let command = installCommands[tool], let envVar = envVars[tool] {
                lines.append("\(tool): \(command) (or point \(envVar) at an existing install)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
