import SwiftUI

/// The ⌘? keyboard-shortcuts help sheet. Content is entirely GENERATED from
/// `Keymap.standard` plus `AppAction.helpTitle`/`helpGroup` — never a
/// hand-maintained list, so a shortcut added to `Keymap.standard` without a
/// `helpTitle` is caught by `KeymapTests` rather than silently missing here.
/// Dismisses via Esc (SwiftUI's default sheet behavior) or ⌘? again (which
/// toggles `UIState.showShortcutHelp` back off through the normal
/// AppActions/ShortcutRouter path — no special-casing needed here).
struct ShortcutHelpView: View {
    /// Section order for the sheet. Every `AppAction.helpGroup` value must
    /// appear here or its rows would silently vanish from the sheet.
    private static let groupOrder = ["Sessions", "Workspaces", "Projects", "Window", "Help"]

    private struct Row: Identifiable {
        let id: String
        let title: String
        let shortcut: String
    }

    /// Builds this group's display rows from `AppAction.allCases`,
    /// collapsing entries that share a `helpTitle` (this is how the nine
    /// `.selectSession(0..<9)` cases become the single "⌘1–9 — Jump to
    /// session" row) into one, in `allCases` order.
    private func rows(in group: String) -> [Row] {
        var seenTitles = Set<String>()
        var rows: [Row] = []
        for action in AppAction.allCases where action.helpGroup == group {
            guard seenTitles.insert(action.helpTitle).inserted else { continue }

            let shortcutDisplay: String
            if case .selectSession = action {
                shortcutDisplay = "⌘1–9"
            } else if let shortcut = Keymap.standard[action] {
                shortcutDisplay = shortcut.displayString
            } else {
                // Menu-only action (e.g. removeProject, deleteWorkspace):
                // no physical shortcut exists.
                shortcutDisplay = "—"
            }
            rows.append(Row(id: action.helpTitle, title: action.helpTitle, shortcut: shortcutDisplay))
        }
        return rows
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Keyboard Shortcuts")
                    .font(.title2)
                    .fontWeight(.semibold)

                ForEach(Self.groupOrder, id: \.self) { group in
                    let groupRows = rows(in: group)
                    if !groupRows.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(groupRows) { row in
                                    HStack {
                                        Text(row.title)
                                        Spacer(minLength: 32)
                                        Text(row.shortcut)
                                            .foregroundStyle(.secondary)
                                            .monospaced()
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(32)
        }
        .frame(minWidth: 440, minHeight: 380)
    }
}
