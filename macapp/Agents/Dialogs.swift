import AppKit

/// AppKit-facing dialogs (open panel / alerts) used by the view layer.
/// Kept separate from `AppStore` so the store stays pure state + persistence
/// and can be unit tested without a running AppKit event loop.
@MainActor
enum Dialogs {
    /// Runs an NSOpenPanel for choosing a project directory. Returns the
    /// chosen absolute path, or nil if the user cancelled.
    static func chooseProjectDirectory() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    /// Confirms removal of a project. Returns true iff the user picked the
    /// destructive "Remove" option.
    static func confirmRemove(_ project: Project) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Remove \u{201C}\(project.name)\u{201D}?"
        alert.informativeText =
            "This removes the project and its sessions from Agents. The directory on disk is not affected."
        alert.alertStyle = .warning
        let removeButton = alert.addButton(withTitle: "Remove")
        removeButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Prompts for a new name, pre-filled with `currentName`. Returns the
    /// (untrimmed) field value iff the primary button was clicked, else
    /// nil. `title` lets callers reuse this for renaming things other than
    /// a session (e.g. a workspace) with the right dialog heading.
    static func promptRename(currentName: String, title: String = "Rename Session") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = currentName
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return textField.stringValue
    }

    /// Confirms deleting a jj workspace. Returns true iff the user picked
    /// the destructive "Delete" option.
    static func confirmDeleteWorkspace(_ ws: WorkspaceRow) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete Workspace \u{201C}\(ws.displayName)\u{201D}?"
        alert.informativeText =
            "This moves the workspace directory to the Bin and tells jj to forget the workspace. Commits and bookmarks remain in the repo."
        alert.alertStyle = .warning
        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Caps how many commits `landReviewText` will list one-per-line before
    /// collapsing the rest into a trailing "…and N more" — a workspace with
    /// an unusually long commit chain must not be able to produce an
    /// effectively unbounded NSAlert.
    private static let maxRenderedLandCommits = 10

    /// Renders one `LandCommit` per line, bullet-prefixed, for
    /// `landReviewText` below — shared by the "will land" and "will
    /// conflict" sections since both show the same shape of list. An empty
    /// `subject` (an undescribed commit) renders as an explicit
    /// "(no description)" rather than a blank bullet, which would read as a
    /// rendering bug rather than a truthful description of the commit.
    private static func renderedCommitList(_ commits: [LandCommit]) -> [String] {
        let shown = commits.prefix(maxRenderedLandCommits)
        var lines = shown.map { commit -> String in
            let subject = commit.subject.isEmpty ? "(no description)" : commit.subject
            return "  \u{2022} \(subject)"
        }
        let remaining = commits.count - shown.count
        if remaining > 0 {
            lines.append("  \u{2026}and \(remaining) more")
        }
        return lines
    }

    /// Builds `confirmLand`'s informative text: what will land, whether it
    /// conflicts, and whether the default workspace will fork — the actual
    /// substance of "review before landing" that replaced the old free-text
    /// prompt. Built as explicit lines (not one auto-wrapped paragraph)
    /// because the whole point is that each of these facts must be legible
    /// on its own, not blur together.
    private static func landReviewText(preview: LandPreview) -> String {
        var lines: [String] = []

        let commitWord = preview.commits.count == 1 ? "commit" : "commits"
        lines.append("\(preview.commits.count) \(commitWord) will land on \(preview.bookmark) (\(preview.bookmarkCommit)):")
        lines.append("")
        lines.append(contentsOf: renderedCommitList(preview.commits))
        lines.append("")

        // This is a REPORT, not the enforcement point: agents-cli's own
        // workspace-land independently refuses a conflicting land with its
        // own land-conflict error regardless of what the user picks here.
        // Swapping which button is destructive/default below is the actual
        // safeguard against a reflexive Return confirming a known-bad land;
        // this text is just telling the user why.
        if preview.conflicts.isEmpty {
            lines.append("\u{2713} No conflicts with \(preview.bookmark)")
        } else {
            let conflictWord = preview.conflicts.count == 1 ? "commit" : "commits"
            lines.append("\u{26A0} \(preview.conflicts.count) \(conflictWord) will conflict with \(preview.bookmark):")
            lines.append(contentsOf: renderedCommitList(preview.conflicts))
        }

        if !preview.diverging.isEmpty {
            let divergingWord = preview.diverging.count == 1 ? "commit" : "commits"
            lines.append("\u{26A0} Your main workspace has \(preview.diverging.count) \(divergingWord) not on \(preview.bookmark);")
            lines.append("  they will fork. You can rebase after landing.")
        }

        if preview.needsMessage {
            lines.append("")
            lines.append("This session left uncommitted changes with no description of their own — describe them below.")
        }

        return lines.joined(separator: "\n")
    }

    /// Presents the "review before landing" confirmation that replaces the
    /// old `promptLandMessage` free-text prompt (see `LandDecision`'s doc
    /// comment in DialogPresenting.swift for the bug that motivated the
    /// replacement, and `AppStore.reviewAndLandWorkspace` for the
    /// preview→dialog→land→optional-rebase flow this is one step of). The
    /// free-text field is added ONLY when `preview.needsMessage` is true —
    /// the CLI only ever reads it back in that one case, so showing it
    /// unconditionally (as the old prompt did) was asking for input that
    /// was almost always thrown away.
    ///
    /// When `preview.conflicts` is non-empty, Cancel (not Keep Changes)
    /// becomes the default/first button and Keep Changes is marked
    /// destructive — so a reflexive Return keypress cannot confirm a land
    /// the app already knows will conflict. This is advance warning only:
    /// agents-cli's own workspace-land independently refuses a conflicting
    /// land with `land-conflict` regardless, so nothing here is the actual
    /// enforcement point.
    static func confirmLand(workspace: WorkspaceRow, preview: LandPreview) -> LandDecision {
        let alert = NSAlert()
        // "Keep changes from …", not the Title-Case "Keep Changes in …"
        // the old promptLandMessage used above — this exact wording and
        // layout was specified by the user for this dialog; don't
        // "correct" the casing to match its sibling dialogs.
        alert.messageText = "Keep changes from \u{201C}\(workspace.displayName)\u{201D}?"
        alert.informativeText = landReviewText(preview: preview)

        let hasConflicts = !preview.conflicts.isEmpty
        if hasConflicts {
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Cancel")
            let keepButton = alert.addButton(withTitle: "Keep Changes")
            keepButton.hasDestructiveAction = true
        } else {
            alert.addButton(withTitle: "Keep Changes")
            alert.addButton(withTitle: "Cancel")
        }

        var textField: NSTextField?
        if preview.needsMessage {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = "Describe any uncommitted changes…"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            textField = field
        }

        let response = alert.runModal()
        // Button order (and therefore which response value means "confirm")
        // flips with hasConflicts above, so which comparison is correct
        // flips right along with it.
        let confirmed = hasConflicts ? response == .alertSecondButtonReturn : response == .alertFirstButtonReturn
        guard confirmed else { return .cancel }

        guard let textField else { return .land(message: nil) }
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return .land(message: trimmed.isEmpty ? nil : trimmed)
    }

    /// Offered once, immediately after a successful land, only when that
    /// land's preview reported non-empty `diverging` commits — i.e. trunk's
    /// move just left the user's own default-workspace commits behind on a
    /// fork. Declining is a complete, legitimate answer (not "cancel
    /// something"): the fork is harmless until the user next works in the
    /// default workspace, so "Not Now" just means "I'll deal with it
    /// myself later." See `AppStore.reviewAndLandWorkspace`.
    static func confirmRebaseOntoTrunk(count: Int, bookmark: String) -> Bool {
        let alert = NSAlert()
        let commitWord = count == 1 ? "commit" : "commits"
        alert.messageText = "Rebase onto \u{201C}\(bookmark)\u{201D}?"
        alert.informativeText =
            "Your main workspace has \(count) \(commitWord) that forked off when \(bookmark) moved. Rebase them onto \(bookmark) now?"
        alert.addButton(withTitle: "Rebase")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Prompts for the project that will contain a new workspace and its
    /// optional sidebar label. The label is returned untrimmed, including
    /// when blank; nil means the user cancelled.
    static func promptNewWorkspace(
        projects: [Project],
        defaultProject: Project?
    ) -> NewWorkspacePromptResult? {
        precondition(!projects.isEmpty)

        let alert = NSAlert()
        alert.messageText = "New Workspace"
        alert.informativeText =
            "Choose a project and optionally set a sidebar label. The workspace keeps its generated name on disk."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let duplicateNameCounts = Dictionary(grouping: projects, by: \.name).mapValues(\.count)
        let projectPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        projectPicker.addItems(withTitles: projects.map { project in
            duplicateNameCounts[project.name, default: 0] > 1 ? project.path : project.name
        })
        let selectedIndex = defaultProject.flatMap { defaultProject in
            projects.firstIndex { $0.path == defaultProject.path }
        } ?? 0
        projectPicker.selectItem(at: selectedIndex)

        let labelField = NSTextField(frame: .zero)
        labelField.placeholderString = "Optional"

        let projectCaption = NSTextField(labelWithString: "Project")
        let labelCaption = NSTextField(labelWithString: "Label")
        projectCaption.alignment = .right
        labelCaption.alignment = .right

        let accessory = NSGridView(views: [
            [projectCaption, projectPicker],
            [labelCaption, labelField],
        ])
        accessory.columnSpacing = 8
        accessory.rowSpacing = 8
        projectPicker.widthAnchor.constraint(equalToConstant: 320).isActive = true
        labelField.widthAnchor.constraint(equalTo: projectPicker.widthAnchor).isActive = true
        accessory.frame = NSRect(origin: .zero, size: accessory.fittingSize)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = labelField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return NewWorkspacePromptResult(
            projectPath: projects[projectPicker.indexOfSelectedItem].path,
            label: labelField.stringValue
        )
    }

    /// Prompts for a workspace's sidebar label, pre-filled with
    /// `currentLabel`. Returns the (untrimmed) field value iff the user
    /// confirmed, else nil on Cancel. Clearing the field and saving reverts
    /// the sidebar to the workspace's generated name — that's what
    /// `AppStore.setWorkspaceLabel` already does with blank input.
    static func promptWorkspaceLabel(currentLabel: String?) -> String? {
        let alert = NSAlert()
        alert.messageText = "Workspace Label"
        alert.informativeText =
            "This sets a sidebar label only — it doesn't rename the workspace itself. Clear the field to revert the sidebar to the workspace's generated name."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = currentLabel ?? ""
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return textField.stringValue
    }
}
