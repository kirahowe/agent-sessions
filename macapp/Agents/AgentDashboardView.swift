import SwiftUI

/// A compact, live overview of all active sessions, ordered by attention.
struct AgentDashboardView: View {
    @ObservedObject var store: AppStore

    private var orderedSessions: [SessionRow] {
        store.sessions.enumerated().sorted { lhs, rhs in
            let left = attentionRank(for: lhs.element)
            let right = attentionRank(for: rhs.element)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    private var blockedCount: Int {
        store.sessions.filter { store.attention[$0.id]?.activity == .blocked }.count
    }

    private var yourTurnCount: Int {
        store.sessions.filter { store.attention[$0.id]?.activity == .yourTurn }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Agent Dashboard")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top)
                .accessibilityAddTraits(.isHeader)

            Text(summaryText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 4)

            if orderedSessions.isEmpty {
                ContentUnavailableView("No active sessions", systemImage: "rectangle.stack")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(orderedSessions) { session in
                    Button {
                        store.selection = session.id
                    } label: {
                        SessionDashboardRow(store: store, session: session)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 300, idealWidth: 320, maxWidth: 340)
    }

    private var summaryText: String {
        let total = store.sessions.count
        guard total > 0 else { return "No active sessions" }
        let needingAttention = blockedCount + yourTurnCount
        return "\(total) active session\(total == 1 ? "" : "s") · \(needingAttention) needing attention"
    }

    private func attentionRank(for session: SessionRow) -> Int {
        switch store.attention[session.id]?.activity {
        case .blocked: return 0
        case .yourTurn: return 1
        case nil: return 2
        }
    }
}

private struct SessionDashboardRow: View {
    @ObservedObject var store: AppStore
    let session: SessionRow

    private var activity: SessionActivity? {
        store.attention[session.id]?.activity
    }

    private var statusText: String {
        switch activity {
        case .blocked: return "Blocked on you"
        case .yourTurn: return "Waiting for you"
        case nil: return "No attention needed"
        }
    }

    private var contextText: String {
        guard let project = store.projects.first(where: { $0.path == session.projectPath }) else {
            return projectFallback
        }
        switch session.target {
        case .root:
            return project.name
        case .workspace(_, let name):
            guard let workspace = store.workspaces.first(where: {
                $0.projectPath == project.path && $0.name == name
            }) else {
                return "\(project.name) · \(name) (workspace unavailable)"
            }
            return "\(project.name) · \(workspace.displayName)"
        }
    }

    private var projectFallback: String {
        let path = session.projectPath
        let projectName = (path as NSString).lastPathComponent
        let label = projectName.isEmpty ? path : projectName
        switch session.target {
        case .root: return "Project unavailable · \(label)"
        case .workspace(_, let name): return "Project unavailable · \(label) · \(name) (workspace unavailable)"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .lineLimit(1)
                Text(contextText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let activity {
                        SessionActivityIndicator(activity: activity)
                    }
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if store.selection == session.id {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background {
            if store.selection == session.id {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.displayName), \(contextText), \(statusText)\(store.selection == session.id ? ", selected" : "")")
    }
}
