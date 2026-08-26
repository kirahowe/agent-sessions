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
