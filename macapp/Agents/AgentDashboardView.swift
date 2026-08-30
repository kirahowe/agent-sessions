import SwiftUI

/// A compact, live view of only the sessions that need you: blocked
/// sessions first, then sessions waiting for you. Quiet sessions — no
/// attention signal at all — are hidden from this list entirely, not shown
/// at the bottom; the summary line above still counts every open session so
/// you can tell how many are hidden.
struct AgentDashboardView: View {
    @ObservedObject var store: AppStore

    private var entries: [AgentDashboardEntry] {
        AgentDashboard.entries(sessions: store.sessions, attention: store.attention)
    }

    private var blockedCount: Int {
        entries.filter { $0.activity == .blocked }.count
    }

    private var yourTurnCount: Int {
        entries.filter { $0.activity == .yourTurn }.count
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

            if store.sessions.isEmpty {
                ContentUnavailableView("No active sessions", systemImage: "rectangle.stack")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView(
                    "Nothing needs your attention",
                    systemImage: "checkmark.circle",
                    description: Text(quietDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    Button {
                        store.selection = entry.session.id
                    } label: {
                        SessionDashboardRow(store: store, entry: entry)
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

    /// Wording for the all-quiet state, matching the README: no signal means
    /// the agent may be working or idle, never a claim that it's running.
    private var quietDescription: String {
        let total = store.sessions.count
        return "\(total) session\(total == 1 ? "" : "s") \(total == 1 ? "is" : "are") working or idle"
    }
}

private struct SessionDashboardRow: View {
    @ObservedObject var store: AppStore
    let entry: AgentDashboardEntry

    private var session: SessionRow { entry.session }

    private var statusText: String {
        switch entry.activity {
        case .blocked: return "Blocked on you"
        case .yourTurn: return "Waiting for you"
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
                    SessionActivityIndicator(activity: entry.activity)
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
