import Foundation

struct Project: Identifiable, Hashable {
    var id: String { path }   // absolute directory path is identity
    let path: String
    var name: String { (path as NSString).lastPathComponent }
}

struct SessionRow: Identifiable, Codable, Hashable {
    let id: String        // UUID string
    var projectPath: String
    var name: String      // "Session 1", "Session 2", ... renameable
}

struct PersistedState: Codable {
    var version: Int
    var projects: [String]        // absolute paths
    var sessions: [SessionRow]
    var selection: String?        // session id

    init(version: Int, projects: [String], sessions: [SessionRow], selection: String?) {
        self.version = version
        self.projects = projects
        self.sessions = sessions
        self.selection = selection
    }

    private enum CodingKeys: String, CodingKey {
        case version, projects, sessions, selection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        projects = try container.decode([String].self, forKey: .projects)
        sessions = try container.decode([SessionRow].self, forKey: .sessions)
        selection = try container.decodeIfPresent(String.self, forKey: .selection)
    }
}
