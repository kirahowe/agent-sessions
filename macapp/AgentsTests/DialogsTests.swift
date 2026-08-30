import AppKit
import XCTest
@testable import Agents

@MainActor
final class DialogsTests: XCTestCase {
    func testPromptNewWorkspaceReturnsSelectedDuplicateNamedProjectAndUntrimmedLabel() {
        let projects = [
            Project(path: "/tmp/first/shared"),
            Project(path: "/tmp/second/shared"),
        ]
        let inspectionFinished = expectation(description: "Inspected and completed the New Workspace alert")

        DispatchQueue.main.async {
            // Every exit from this block must end the nested modal loop. In
            // particular, a failed guard must not strand the test in
            // promptNewWorkspace's synchronous runModal call.
            defer {
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
                inspectionFinished.fulfill()
            }

            guard let modalWindow = NSApp.modalWindow,
                  let contentView = modalWindow.contentView
            else {
                XCTFail("Expected the New Workspace alert to be the active modal window")
                return
            }

            let grids = self.descendants(of: NSGridView.self, in: contentView)
            guard let accessory = grids.reversed().first(where: {
                !self.descendants(of: NSPopUpButton.self, in: $0).isEmpty
            }) else {
                XCTFail("Expected the New Workspace alert's grid accessory")
                return
            }

            let textFields = self.descendants(of: NSTextField.self, in: accessory)
            let visibleCaptions = Set(
                textFields
                    .filter { !$0.isEditable && !$0.isHidden }
                    .map(\.stringValue)
            )
            XCTAssertTrue(visibleCaptions.contains("Project"))
            XCTAssertTrue(visibleCaptions.contains("Label"))

            guard let picker = self.descendants(of: NSPopUpButton.self, in: accessory).first else {
                XCTFail("Expected a project picker in the New Workspace accessory")
                return
            }
            XCTAssertFalse(picker.isHidden)
            XCTAssertEqual(picker.itemTitles, projects.map(\.path))
            XCTAssertEqual(picker.indexOfSelectedItem, 0)
            picker.selectItem(at: 1)
            guard let labelField = textFields.first(where: \.isEditable) else {
                XCTFail("Expected an editable optional-label field in the New Workspace accessory")
                return
            }
            XCTAssertEqual(labelField.placeholderString, "Optional")
            labelField.stringValue = "  Review queue  "
        }

        let result = Dialogs.promptNewWorkspace(
            projects: projects,
            defaultProject: projects[0]
        )

        wait(for: [inspectionFinished], timeout: 0)
        XCTAssertEqual(
            result,
            NewWorkspacePromptResult(
                projectPath: projects[1].path,
                label: "  Review queue  "
            )
        )
    }

    /// Drives the real modal alert to prove the project picker takes part
    /// in the window's automatic key view (Tab) loop and steps through its
    /// items with the arrow keys, clamping rather than wrapping — and that
    /// what arrowing selects is exactly what the dialog returns.
    func testPromptNewWorkspaceIsKeyboardNavigable() {
        let projects = [
            Project(path: "/tmp/alpha"),
            Project(path: "/tmp/beta"),
            Project(path: "/tmp/gamma"),
        ]
        let inspectionFinished = expectation(description: "Drove the New Workspace alert's keyboard navigation")

        DispatchQueue.main.async {
            // Every exit from this block must end the nested modal loop. In
            // particular, a failed guard must not strand the test in
            // promptNewWorkspace's synchronous runModal call.
            defer {
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
                inspectionFinished.fulfill()
            }

            guard let modalWindow = NSApp.modalWindow,
                  let contentView = modalWindow.contentView
            else {
                XCTFail("Expected the New Workspace alert to be the active modal window")
                return
            }

            let grids = self.descendants(of: NSGridView.self, in: contentView)
            guard let accessory = grids.reversed().first(where: {
                !self.descendants(of: NSPopUpButton.self, in: $0).isEmpty
            }) else {
                XCTFail("Expected the New Workspace alert's grid accessory")
                return
            }

            guard let picker = self.descendants(of: NSPopUpButton.self, in: accessory).first else {
                XCTFail("Expected a project picker in the New Workspace accessory")
                return
            }
            guard let labelField = self.descendants(of: NSTextField.self, in: accessory).first(where: \.isEditable) else {
                XCTFail("Expected an editable optional-label field in the New Workspace accessory")
                return
            }

            func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
                NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: modifiers,
                    timestamp: 0,
                    windowNumber: modalWindow.windowNumber,
                    context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false,
                    keyCode: keyCode
                )!
            }
            let tab = key("\t", keyCode: 48)
            let shiftTab = key("\u{19}", keyCode: 48, modifiers: [.shift])
            let downArrow = key("\u{F701}", keyCode: 125)
            let upArrow = key("\u{F700}", keyCode: 126)

            // The hops asserted unconditionally are the ones that hold
            // regardless of the user's Full Keyboard Access setting. With
            // it on, the alert's own Cancel and Create buttons also join the
            // loop, between the label and the picker — so "next from the
            // label" is the picker only when the setting is off, whereas
            // "previous from the label" and "next from the picker" are the
            // picker and the label either way.
            XCTAssertTrue(labelField.previousKeyView === picker, "the picker must precede the label in the key view loop")
            XCTAssertTrue(picker.nextKeyView === labelField, "the picker must lead to the label in the key view loop")

            XCTAssertTrue(modalWindow.makeFirstResponder(labelField))
            XCTAssertNotNil(labelField.currentEditor(), "the label's first responder should be its field editor")
            XCTAssertTrue(modalWindow.firstResponder === labelField.currentEditor())

            modalWindow.sendEvent(shiftTab)
            XCTAssertTrue(modalWindow.firstResponder === picker, "Shift-Tab from the label must move focus to the picker")

            modalWindow.sendEvent(downArrow)
            XCTAssertEqual(picker.indexOfSelectedItem, 1)
            modalWindow.sendEvent(downArrow)
            XCTAssertEqual(picker.indexOfSelectedItem, 2)
            modalWindow.sendEvent(downArrow)
            XCTAssertEqual(picker.indexOfSelectedItem, 2, "selection must clamp at the last item, not wrap")
            modalWindow.sendEvent(upArrow)
            XCTAssertEqual(picker.indexOfSelectedItem, 1)
            modalWindow.sendEvent(upArrow)
            XCTAssertEqual(picker.indexOfSelectedItem, 0)
            modalWindow.sendEvent(upArrow)
            XCTAssertEqual(picker.indexOfSelectedItem, 0, "selection must clamp at the first item, not wrap")
            modalWindow.sendEvent(downArrow)
            XCTAssertEqual(picker.indexOfSelectedItem, 1)

            modalWindow.sendEvent(tab)
            XCTAssertTrue(
                modalWindow.firstResponder === labelField.currentEditor(),
                "Tab from the picker must move focus to the label"
            )

            labelField.stringValue = "keyboard"
            modalWindow.sendEvent(shiftTab)
            XCTAssertTrue(modalWindow.firstResponder === picker, "Shift-Tab from the label must move focus to the picker")
            XCTAssertEqual(labelField.stringValue, "keyboard", "moving focus away must not disturb the label's text")

            // With Full Keyboard Access off — the macOS default — these two
            // controls are the whole loop, so Tab from the label wraps
            // straight round to the picker. With it on, the buttons sit in
            // between; that ordering is the system's, not the dialog's.
            if !NSApp.isFullKeyboardAccessEnabled {
                XCTAssertTrue(labelField.nextKeyView === picker, "with two key views, the label must wrap round to the picker")
                modalWindow.sendEvent(tab)
                XCTAssertTrue(
                    modalWindow.firstResponder === labelField.currentEditor(),
                    "Tab from the picker must move focus to the label"
                )
                modalWindow.sendEvent(tab)
                XCTAssertTrue(modalWindow.firstResponder === picker, "Tab from the label must wrap round to the picker")
            }
        }

        let result = Dialogs.promptNewWorkspace(
            projects: projects,
            defaultProject: projects[0]
        )

        wait(for: [inspectionFinished], timeout: 0)
        XCTAssertEqual(
            result,
            NewWorkspacePromptResult(
                projectPath: projects[1].path,
                label: "keyboard"
            )
        )
    }

    private func descendants<View: NSView>(of type: View.Type, in root: NSView) -> [View] {
        var matches: [View] = []
        if let match = root as? View {
            matches.append(match)
        }
        for subview in root.subviews {
            matches.append(contentsOf: descendants(of: type, in: subview))
        }
        return matches
    }
}
