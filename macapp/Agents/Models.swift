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
    var projects: [String]        // absolute paths
    var sessions: [SessionRow]
    var selection: String?        // session id
}
