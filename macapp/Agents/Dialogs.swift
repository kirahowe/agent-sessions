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
        // KeyboardPopUpButton rather than NSPopUpButton so the picker is in
        // the Tab loop and steppable with the arrow keys without Full
        // Keyboard Access — see that class for why a stock pop-up isn't.
        let projectPicker = KeyboardPopUpButton(frame: .zero, pullsDown: false)
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
