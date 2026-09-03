import Foundation

struct Project: Identifiable, Hashable {
    var id: String { path }   // absolute directory path is identity
    let path: String
    var name: String { (path as NSString).lastPathComponent }
}

/// A session's terminal attaches to a target: either a project's root
/// directory or one of its isolated workspaces. `id` is stable persistence
/// and terminal-view identity, so it must never change shape.
enum TargetRef: Hashable, Codable {
    case root(projectPath: String)
    case workspace(projectPath: String, name: String)

    var projectPath: String {
        switch self {
        case .root(let projectPath): return projectPath
        case .workspace(let projectPath, _): return projectPath
        }
    }

    var id: String {
        switch self {
        case .root(let projectPath): return "root|\(projectPath)"
        case .workspace(let projectPath, let name): return "ws|\(projectPath)|\(name)"
        }
    }
}

/// An isolated workspace of a project. `name`/`path` are immutable identity
/// set by the engine; `label` is a purely cosmetic display alias.
struct WorkspaceRow: Identifiable, Codable, Hashable {
    var projectPath: String
    var name: String
    var path: String
    var label: String?

    // Deliberately the same "ws|<path>|<name>" shape as TargetRef.workspace's
    // id — the two are meant to key identically.
    var id: String { "ws|\(projectPath)|\(name)" }
    var displayName: String { label ?? name }
}

struct SessionRow: Identifiable, Codable, Hashable {
    let id: String        // UUID string
    var target: TargetRef
    // The auto-assigned "Session 1", "Session 2", … label. Kept purely as
    // the counter seed (seedSessionCounters parses it) and the last-resort
    // fallback name; it is NOT what the sidebar shows once an agent title or
    // a manual rename exists — see `displayName`.
    var name: String
    // A name the user typed via Rename…. Highest-priority display name: once
    // set it is sticky and is never overwritten by an incoming agent title —
    // an explicit rename is a firm decision the agent must not stomp.
    var customName: String? = nil
    // The most recent non-empty OSC terminal title the agent (e.g. Claude
    // Code) set for this session. Persisted so the name stays stable across
    // relaunches instead of flashing back to "Session N" until the agent
    // re-announces. Updated only on a non-empty title (see
    // AppStore.setSessionTitle): a shell quietly clearing its title must not
    // wipe the remembered one.
    var agentTitle: String? = nil
    // Resume information for this row's most recent agent session,
    // announced either natively (OMP speaking Warp's CLI-agent protocol) or
    // via the app's own hook (hooks/agents-status.sh, for Claude Code and
    // Codex). Optional for backward-compatible decoding of existing v2
    // state files. See the SessionRow init(from:) extension below for the
    // legacy `ompResume` decode compatibility this field requires.
    var resume: SessionResumeMetadata? = nil

    var projectPath: String { target.projectPath }

    /// What the sidebar row and window title show. A manual rename wins;
    /// otherwise the agent-set terminal title; otherwise the auto "Session N".
    var displayName: String { customName ?? agentTitle ?? name }

    /// The window subtitle: the agent-set terminal title, but only when it
    /// isn't already exactly what `displayName` shows — there's no point
    /// repeating the name verbatim on the line directly beneath it. So the
    /// agent title surfaces here only once a manual rename has taken over the
    /// name; with no manual name the title IS the name and this is nil.
    var subtitle: String? {
        guard let agentTitle, agentTitle != displayName else { return nil }
        return agentTitle
    }
}

extension SessionRow {
    private enum CodingKeys: String, CodingKey {
        case id, target, name, customName, agentTitle, resume
    }

    /// Pre-refactor state.json files persisted this row's session-resume
    /// metadata under the key `ompResume`, shaped like today's `resume` but
    /// without an `agent` field — every entry from that era was necessarily
    /// OMP's, the only harness that spoke the protocol at the time. Decoding
    /// must keep reading that key, as `agent == "omp"`, so existing users
    /// don't lose a row's resume metadata on first launch after the update.
    /// Every new save writes `resume` (with `agent`) and never `ompResume`
    /// again — this custom `init(from:)` lives in an extension, rather than
    /// the struct body, specifically so the compiler still synthesizes
    /// `encode(to:)` (which only ever writes `resume`) and still generates
    /// `SessionRow`'s memberwise initializer, which `PersistedState`'s v1
    /// migration and `AppStore` both rely on.
    private enum LegacyCodingKeys: String, CodingKey {
        case ompResume
    }

    private struct LegacyResumeMetadata: Decodable {
        let sessionID: String
        let title: String?
        let prompt: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        target = try container.decode(TargetRef.self, forKey: .target)
        name = try container.decode(String.self, forKey: .name)
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
        agentTitle = try container.decodeIfPresent(String.self, forKey: .agentTitle)

        if let resume = try container.decodeIfPresent(SessionResumeMetadata.self, forKey: .resume) {
            self.resume = resume
        } else {
            let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
            if let legacy = try legacyContainer.decodeIfPresent(LegacyResumeMetadata.self, forKey: .ompResume) {
                self.resume = SessionResumeMetadata(
                    agent: "omp",
                    sessionID: legacy.sessionID,
                    title: legacy.title,
                    prompt: legacy.prompt
                )
            } else {
                self.resume = nil
            }
        }
    }
}

/// A project parked out of the sidebar by `AppStore.archiveProject`, with
/// its rows kept whole so a restore reinstates the sidebar exactly as it
/// was: session ids (and with them terminal-view identity and resume
/// metadata), names, agent titles, and workspace rows all survive.
/// `archivedAt` is recorded so a future automatic "archive after N idle
/// days" needs no migration; nothing reads it yet.
struct ArchivedProject: Identifiable, Codable, Hashable {
    let path: String
    var archivedAt: Date
    var sessions: [SessionRow]
    var workspaces: [WorkspaceRow]

    var id: String { path }   // same identity rule as Project
    var name: String { (path as NSString).lastPathComponent }
    var project: Project { Project(path: path) }
}

struct PersistedState: Codable {
    var version: Int
    var projects: [String]        // absolute paths
    var sessions: [SessionRow]
    var workspaces: [WorkspaceRow]
    var selection: String?        // session id
    var archivedProjects: [ArchivedProject]

    init(
        version: Int,
        projects: [String],
        sessions: [SessionRow],
        workspaces: [WorkspaceRow],
        selection: String?,
        archivedProjects: [ArchivedProject] = []
    ) {
        self.version = version
        self.projects = projects
        self.sessions = sessions
        self.workspaces = workspaces
        self.selection = selection
        self.archivedProjects = archivedProjects
    }

    private enum CodingKeys: String, CodingKey {
        case version, projects, sessions, workspaces, selection, archivedProjects
    }

    /// The pre-v2 on-disk shape: sessions carried a flat `projectPath`
    /// instead of a `TargetRef`, and there was no `workspaces` array.
    private struct LegacySessionV1: Codable {
        let id: String
        let projectPath: String
        let name: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        projects = try container.decode([String].self, forKey: .projects)
        selection = try container.decodeIfPresent(String.self, forKey: .selection)
        // Absent from every file written before archiving existed; an
        // optional key (not a version bump) keeps those loading unchanged.
        archivedProjects = try container.decodeIfPresent([ArchivedProject].self, forKey: .archivedProjects) ?? []

        if version >= 2 {
            sessions = try container.decode([SessionRow].self, forKey: .sessions)
            workspaces = try container.decodeIfPresent([WorkspaceRow].self, forKey: .workspaces) ?? []
        } else {
            let legacy = try container.decode([LegacySessionV1].self, forKey: .sessions)
            sessions = legacy.map { SessionRow(id: $0.id, target: .root(projectPath: $0.projectPath), name: $0.name) }
            workspaces = []
        }
    }
}
