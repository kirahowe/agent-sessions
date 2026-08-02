import Combine
import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published var projects: [Project] = []
    @Published var sessions: [SessionRow] = []
    @Published var selection: String?

    let terminals: any SessionTerminating

    /// Per-project session-number counters, in-memory only. Seeded from
    /// restored session names on launch; on relaunch max+1 is fine, no need
    /// to persist the counter itself.
    private var sessionCounters: [String: Int] = [:]

    private let stateURL: URL

    /// The app's real persisted-state location: ~/Library/Application
    /// Support/Agents/state.json.
    static let defaultStateURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return appSupport
            .appendingPathComponent("Agents", isDirectory: true)
            .appendingPathComponent("state.json")
    }()

    init(terminals: any SessionTerminating, stateURL: URL) {
        self.terminals = terminals
        self.stateURL = stateURL
        terminals.onProcessExit = { [weak self] id in
            self?.closeSession(id)
        }
        load()
        seedSessionCounters()
    }

    // MARK: - Project management

    func addProject(path: String) {
        let project: Project
        if let existing = projects.first(where: { $0.path == path }) {
            project = existing
        } else {
            project = Project(path: path)
            projects.append(project)
        }

        newSession(in: project)
        save()
    }

    func removeProject(_ project: Project) {
        let removedIDs = sessions.filter { $0.projectPath == project.path }.map(\.id)
        for id in removedIDs {
            terminals.closeSession(id)
        }
        sessions.removeAll { $0.projectPath == project.path }
        projects.removeAll { $0.path == project.path }
        if let selection, removedIDs.contains(selection) {
            self.selection = nil
        }
        save()
    }

    // MARK: - Session management

    func newSession(in project: Project?) {
        let target: Project?
        if let project {
            target = project
        } else if let selection,
                  let owningRow = sessions.first(where: { $0.id == selection })
        {
            target = projects.first(where: { $0.path == owningRow.projectPath })
        } else {
            target = projects.first
        }
        guard let target else { return }

        let number = sessionCounters[target.path, default: 1]
        sessionCounters[target.path] = number + 1

        let row = SessionRow(id: UUID().uuidString, projectPath: target.path, name: "Session \(number)")
        sessions.append(row)
        selection = row.id
        save()
    }

    func closeSession(_ id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let row = sessions[index]
        let wasSelected = selection == id

        terminals.closeSession(id)
        sessions.remove(at: index)

        if wasSelected {
            let siblings = sessions.enumerated().filter { $0.element.projectPath == row.projectPath }
            if siblings.isEmpty {
                selection = nil
            } else if let next = siblings.first(where: { $0.offset >= index }) {
                selection = next.element.id
            } else {
                selection = siblings.last?.element.id
            }
        }
        save()
    }

    func renameSession(_ id: String, to name: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessions[index].name = trimmed
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }

        projects = state.projects.map { Project(path: $0) }
        sessions = state.sessions
        selection = state.selection
    }

    private func save() {
        let state = PersistedState(
            version: 1,
            projects: projects.map(\.path),
            sessions: sessions,
            selection: selection
        )
        do {
            let directory = stateURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            NSLog("Agents: failed to save state: \(error)")
        }
    }

    private func seedSessionCounters() {
        for project in projects {
            let maxNumber = sessions
                .filter { $0.projectPath == project.path }
                .compactMap { row -> Int? in
                    guard row.name.hasPrefix("Session ") else { return nil }
                    return Int(row.name.dropFirst("Session ".count))
                }
                .max() ?? 0
            sessionCounters[project.path] = maxNumber + 1
        }
    }
}
