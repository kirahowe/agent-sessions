import SwiftUI

/// A triage queue of only the sessions that need you: a "Blocked on you"
/// section, then a "Waiting for you" section, each headed by the same
/// indicator glyph the sidebar uses plus a count. Quiet sessions — no
/// attention signal at all — are hidden from the queue entirely, not shown
/// at the bottom; the footer still counts every open session so you can
/// tell how many are hidden.
///
/// Built on `ScrollView` + `LazyVStack` rather than `List`, on purpose. The
/// earlier `List`-inside-a-`VStack` layout sized its rows at the platform's
/// 24pt default while each row held three lines of text, so the first row's
/// top line was clipped under the summary; and the `.inset` style's own
/// opaque background drew a visible seam against the inspector's material.
/// Owning the layout sidesteps both and keeps the urgency tint, hover, and
/// selection styling in one place.
struct AgentDashboardView: View {
    @ObservedObject var store: AppStore

    private var entries: [AgentDashboardEntry] {
        AgentDashboard.entries(sessions: store.sessions, attention: store.attention)
    }

    var body: some View {
        Group {
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
                queue
            }
        }
        .frame(minWidth: 300, idealWidth: 320, maxWidth: 340)
    }

    /// The footer sits outside the scroll view, the same way the sidebar's
    /// "Add Project" control does, so it stays put while the queue scrolls.
    private var queue: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    section(.blocked)
                    section(.yourTurn)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
            footer
        }
    }

    /// One urgency section — heading plus a card per session — or nothing
    /// at all when no session is in that state, so an empty "Blocked on
    /// you" heading never sits above the waiting list.
    @ViewBuilder
    private func section(_ activity: SessionActivity) -> some View {
        let rows = entries.filter { $0.activity == activity }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    // Fixed width so the two headings' text aligns despite
                    // the glyphs being different sizes (7pt dot, 11pt mark).
                    SessionActivityIndicator(activity: activity)
                        .frame(width: 12)
                    Text(activity.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(rows.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(activity.title), \(rows.count)")
                .accessibilityAddTraits(.isHeader)

                ForEach(rows) { entry in
                    AttentionCard(store: store, entry: entry)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(footerText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Counts every open session, not just the listed ones, so the reader
    /// can tell how many the queue is hiding.
    private var footerText: String {
        let total = store.sessions.count
        let quiet = total - entries.count
        let sessions = "\(total) session\(total == 1 ? "" : "s")"
        return quiet == 0 ? "\(sessions) · none quiet" : "\(sessions) · \(quiet) quiet"
    }

    /// Wording for the all-quiet state, matching the README: no signal means
    /// the agent may be working or idle, never a claim that it's running.
    private var quietDescription: String {
        let total = store.sessions.count
        return "\(total) session\(total == 1 ? "" : "s") \(total == 1 ? "is" : "are") working or idle"
    }
}

/// One session in the queue: its name, project and workspace, and how long
/// it has been waiting, on a card tinted with its urgency colour. Selection
/// is shown with the accent border rather than a tinted fill so it can never
/// be confused with the red/gold urgency tint the fill already carries.
private struct AttentionCard: View {
    @ObservedObject var store: AppStore
    let entry: AgentDashboardEntry

    @State private var isHovered = false

    private var session: SessionRow { entry.session }
    private var isSelected: Bool { store.selection == session.id }
    private var tint: Color { entry.activity.tint }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    var body: some View {
        // Re-evaluated on the minute so the age keeps up without any store
        // change; the card is cheap enough that re-rendering all of it is
        // simpler than isolating the one label (and keeps the accessibility
        // label's spoken age current too).
        TimelineView(.everyMinute) { context in
            let elapsed = entry.since.map { AgentDashboard.elapsed(since: $0, now: context.date) }
            Button {
                store.selection = session.id
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.displayName)
                            .lineLimit(1)
                        Text(contextText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let elapsed {
                        Text(elapsed.short)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shape.fill(tint.opacity(isHovered ? 0.16 : 0.09)))
                .overlay(
                    shape.strokeBorder(
                        isSelected ? Color.accentColor : tint.opacity(0.28),
                        lineWidth: isSelected ? 1.5 : 1
                    )
                )
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .help(session.displayName)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(elapsed: elapsed))
            // `.ignore` above collapses the card into one element but drops
            // the Button's own role with it, so the role is restored here.
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        }
        .onHover { isHovered = $0 }
    }

    private func accessibilityLabel(elapsed: AgentDashboard.Elapsed?) -> String {
        var parts = [session.displayName, contextText]
        parts.append(elapsed.map { "\(entry.activity.title), \($0.spoken)" } ?? entry.activity.title)
        if isSelected { parts.append("selected") }
        return parts.joined(separator: ", ")
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
}
