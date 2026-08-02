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

    /// Prompts for a new session name, pre-filled with `currentName`. Returns
    /// the (untrimmed) field value iff "Rename" was clicked, else nil.
    static func promptRename(currentName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = currentName
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return textField.stringValue
    }
}
