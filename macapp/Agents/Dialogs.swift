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

    /// Prompts for the landing message when keeping (landing) a
    /// workspace's changes. The session's own commits land with their own
    /// messages (merge model — see agents-cli's workspace-land); this
    /// message only ever describes trailing uncommitted work, and even then
    /// only when the agent didn't describe it itself. It's still required:
    /// whether it will be needed isn't knowable before landing. Returns the
    /// trimmed message iff the user confirmed with non-blank input; nil on
    /// Cancel OR on blank input (a blank message is treated the same as
    /// cancelling — never risks landing an undescribed commit).
    static func promptLandMessage(workspace: WorkspaceRow) -> String? {
        let alert = NSAlert()
        alert.messageText = "Keep Changes in \u{201C}\(workspace.displayName)\u{201D}?"
        alert.informativeText =
            "Lands the session's commits on main as they are, then removes the workspace and moves its directory to the Bin. The message below is only used to describe changes the session left uncommitted."
        alert.addButton(withTitle: "Keep Changes")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.placeholderString = "Describe any uncommitted changes…"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Prompts for a new workspace's sidebar label. Returns nil iff the user
    /// cancelled — in that case no workspace should be created at all.
    /// Otherwise returns the (untrimmed) field value as-is, including when
    /// it's blank: unlike `promptLandMessage` above, blank input here is NOT
    /// collapsed to nil, because blank is a meaningful "no label, use the
    /// generated name" answer, distinct from cancelling. It's on the caller
    /// (`AppStore.createWorkspace`) to trim and decide what blank means.
    static func promptNewWorkspaceLabel() -> String? {
        let alert = NSAlert()
        alert.messageText = "New Workspace"
        alert.informativeText =
            "This sets a sidebar label only — the workspace keeps its own generated name on disk. Leave blank to use that generated name."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.placeholderString = "Sidebar label (optional)"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return textField.stringValue
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
